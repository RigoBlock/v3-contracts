// SPDX-License-Identifier: Apache-2.0-or-later
// solhint-disable-next-line
pragma solidity 0.8.28;

import {EnumerableSet, AddressSet} from "../../libraries/EnumerableSet.sol";
import {ReentrancyGuardTransient} from "../../libraries/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";
import {StorageLib} from "../../libraries/StorageLib.sol";
import {IEOracle} from "./interfaces/IEOracle.sol";
import {IMinimumVersion} from "./interfaces/IMinimumVersion.sol";
import {IA0xRouter} from "./interfaces/IA0xRouter.sol";

/// @notice Minimal interface for the 0x AllowanceHolder contract.
interface IAllowanceHolder {
    function exec(
        address operator,
        address token,
        uint256 amount,
        address payable target,
        bytes calldata data
    ) external payable returns (bytes memory result);
}

/// @notice Minimal interface for the 0x Deployer/Registry (ERC721-compatible).
interface I0xDeployer {
    /// @notice Returns the current Settler address for a given feature.
    /// @dev Reverts if feature is paused.
    function ownerOf(uint256 tokenId) external view returns (address);

    /// @notice Returns the previous Settler address for a given feature.
    /// @dev Used during API dwell time when the current instance differs from what the API returns.
    function prev(uint128 featureId) external view returns (address);
}

/// @title A0xRouter - Allows smart pool swaps via the 0x swap aggregator.
/// @notice This adapter validates and forwards swap calls from the 0x API through AllowanceHolder to Settler.
/// @dev The pool owner sends the 0x API response's transaction.data directly to the pool contract.
///  The pool's fallback routes to this adapter, which validates the call and forwards to AllowanceHolder.
///  Bridge/cross-chain exclusion: only Feature 2 (Taker Submitted) settlers are accepted. Feature 5
///  (Bridge) settlers are rejected by _requireGenuineSettler. Cross-chain actions embedded in a Feature 2
///  settler would fail at the settler's own _checkSlippageAndTransfer because bridged tokens do not arrive
///  on the same chain in the same transaction. Virtual supply is therefore not affected.
/// @author Gabriele Rigo - <gab@rigoblock.com>
contract A0xRouter is IA0xRouter, IMinimumVersion, ReentrancyGuardTransient {
    using EnumerableSet for AddressSet;
    using SafeTransferLib for address;

    string private constant _REQUIRED_VERSION = "4.0.0";

    address private immutable _adapter;
    IAllowanceHolder private immutable _allowanceHolder;
    I0xDeployer private immutable _deployer;

    /// @dev Feature ID 2 = Taker Submitted Settler (standard user-submitted swap flow).
    uint128 private constant _SETTLER_TAKER_FEATURE = 2;

    /// @dev Selector for Settler.execute((address,address,uint256),bytes[],bytes32).
    bytes4 private constant _SETTLER_EXECUTE_SELECTOR = 0x1fff991f;

    /// @param allowanceHolder The 0x AllowanceHolder contract address (chain-specific, immutable).
    /// @param deployer The 0x Deployer/Registry contract address (same on all chains).
    constructor(address allowanceHolder, address deployer) {
        _adapter = address(this);
        _allowanceHolder = IAllowanceHolder(allowanceHolder);
        _deployer = I0xDeployer(deployer);
    }

    modifier onlyDelegateCall() {
        require(address(this) != _adapter, DirectCallNotAllowed());
        _;
    }

    /// @inheritdoc IMinimumVersion
    function requiredVersion() external pure override returns (string memory) {
        return _REQUIRED_VERSION;
    }

    /// @inheritdoc IA0xRouter
    function exec(
        address operator,
        address token,
        uint256 amount,
        address payable target,
        bytes calldata data
    ) external payable override nonReentrant onlyDelegateCall returns (bytes memory) {
        // 1. Verify target is a genuine 0x Settler instance via the Deployer registry.
        //    Uses ownerOf (current) + prev (dwell time fallback), per 0x team recommendation.
        _requireGenuineSettler(target);

        // 2. Decode the Settler calldata to extract and validate AllowedSlippage parameters.
        _validateSettlerCalldata(data);

        // 3. Derive the ETH value to forward from the pool's own balance.
        //    When selling native ETH (token == address(0)), the pool sends `amount` of its own ETH.
        //    When selling ERC20, no ETH is needed. Never use msg.value — the pool is the vault,
        //    the caller only triggers the operation, same pattern as AUniswapRouter.
        uint256 value = token.isAddressZero() ? amount : 0;

        // 4. Approve exact sellToken amount to AllowanceHolder for this call only.
        //    AllowanceHolder does NOT use Permit2 — it consumes standard ERC20 allowance via
        //    token.transferFrom(pool, settler, amount) inside exec(). Since there is no second
        //    scoping layer (unlike Permit2), we approve per-call and reset after success.
        //    safeApprove handles USDT-style tokens (force reset then approve).
        if (!token.isAddressZero()) {
            token.safeApprove(address(_allowanceHolder), amount);
        }

        // 5. Forward the call to AllowanceHolder using pool's own balance.
        try _allowanceHolder.exec{value: value}(operator, token, amount, target, data) returns (
            bytes memory result
        ) {
            // 6. Reset approval to 1 after successful exec (gas optimization).
            //    AllowanceHolder.transferFrom consumes the ERC20 allowance, so it should already
            //    be 0 or near-0 after a full fill. Reset to 1 (not 0) keeps the storage slot warm:
            //    next swap pays 5000 gas (non-zero → non-zero) instead of 20000 (zero → non-zero).
            if (!token.isAddressZero()) {
                token.safeApprove(address(_allowanceHolder), 1);
            }
            return result;
        } catch Error(string memory reason) {
            revert(reason);
        } catch (bytes memory returnData) {
            // Check if the revert was caused by insufficient ETH in the pool.
            if (value > address(this).balance) {
                revert InsufficientNativeBalance();
            }
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }

    /// @dev Verifies the target is the current or previous Settler instance for Feature 2 (Taker Submitted).
    ///  Only same-chain swap settlers are accepted. Feature 5 (Bridge) settlers are implicitly rejected
    ///  because they have different addresses in the Deployer registry.
    ///  Reverts if the feature is paused (ownerOf reverts) or if target doesn't match current or previous.
    function _requireGenuineSettler(address target) private view {
        // ownerOf reverts if the feature is paused, which is the desired behavior.
        if (_deployer.ownerOf(_SETTLER_TAKER_FEATURE) == target) {
            return;
        }

        // Fallback: check previous instance (handles 0x API dwell time between deployments).
        if (_deployer.prev(_SETTLER_TAKER_FEATURE) == target) {
            return;
        }

        revert CounterfeitSettler(target);
    }

    /// @dev Decodes and validates the Settler.execute calldata embedded in the AllowanceHolder `data` parameter.
    ///  Ensures: (1) correct function selector, (2) recipient is the pool, (3) buyToken has a price feed.
    function _validateSettlerCalldata(bytes calldata data) private {
        // Minimum length: 4 (selector) + 32 (recipient) + 32 (buyToken) + 32 (minAmountOut) = 100 bytes
        require(data.length >= 100, InvalidSettlerCalldata());

        bytes4 selector;
        address recipient;
        address buyToken;

        // data layout for execute((address,address,uint256),bytes[],bytes32):
        //   [0:4]   selector
        //   [4:36]  slippage.recipient (static tuple member 1)
        //   [36:68] slippage.buyToken  (static tuple member 2)
        //   [68:100] slippage.minAmountOut (static tuple member 3)
        assembly ("memory-safe") {
            selector := calldataload(data.offset)
            recipient := calldataload(add(data.offset, 4))
            buyToken := calldataload(add(data.offset, 36))
        }

        // Only allow Settler.execute — not executeWithPermit or executeMetaTxn.
        require(selector == _SETTLER_EXECUTE_SELECTOR, UnsupportedSettlerFunction());

        // Recipient must be this contract (the pool, in delegatecall context).
        require(recipient == address(this), RecipientNotSmartPool());

        // Assert buyToken has a registered price feed in the oracle.
        _assertTokenOutHasPriceFeed(buyToken);
    }

    /// @dev Verifies the buyToken has a price feed and adds it to the active tokens set if new.
    function _assertTokenOutHasPriceFeed(address buyToken) private {
        AddressSet storage values = StorageLib.activeTokensSet();
        values.addUnique(IEOracle(address(this)), buyToken, StorageLib.pool().baseToken);
    }
}
