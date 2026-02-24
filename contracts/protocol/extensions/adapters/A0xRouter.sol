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

// Imported from 0x-settler submodule — action selectors used for RFQ exclusion.
// UPGRADE RISK: If 0x upgrades their settler contracts or changes action selectors,
// the adapter must be redeployed with updated imports. The adapter follows the deployer-
// returned settler instances, so a new settler deployment with changed action signatures
// would cause the forbidden action check to scan for stale selectors. Monitor 0x-settler
// releases for breaking changes.
import {ISettlerActions} from "0x-settler/src/ISettlerActions.sol";
import {IAllowanceHolder} from "0x-settler/src/allowanceholder/IAllowanceHolder.sol";
import {ISettlerTakerSubmitted} from "0x-settler/src/interfaces/ISettlerTakerSubmitted.sol";
import {IDeployer} from "0x-settler/src/deployer/IDeployer.sol";
import {Feature} from "0x-settler/src/deployer/Feature.sol";

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
    IDeployer private immutable _deployer;

    /// @dev Feature ID 2 = Taker Submitted Settler (standard user-submitted swap flow).
    ///  The deployer uses ERC721 tokenIds to identify features. Feature 2 = same-chain swap settler.
    ///  This is NOT importable from 0x-settler — it's a magic number assigned in each settler variant's
    ///  _tokenId() override (e.g., Settler.sol returns 2, BridgeSettler.sol returns 5).
    ///  See: require(Feature.unwrap(takerSubmittedFeature) == 2) in 0x-settler/script/DeploySafes.s.sol
    Feature private constant _TAKER_SUBMITTED_FEATURE = Feature.wrap(2);

    /// @param allowanceHolder The 0x AllowanceHolder contract address (chain-specific, immutable).
    /// @param deployer The 0x Deployer/Registry contract address (same on all chains).
    constructor(address allowanceHolder, address deployer) {
        _adapter = address(this);
        _allowanceHolder = IAllowanceHolder(allowanceHolder);
        _deployer = IDeployer(deployer);
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
        try _allowanceHolder.exec{value: value}(operator, token, amount, target, data) returns (bytes memory result) {
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
        if (_deployer.ownerOf(Feature.unwrap(_TAKER_SUBMITTED_FEATURE)) == target) {
            return;
        }

        // Fallback: check previous instance (handles 0x API dwell time between deployments).
        if (_deployer.prev(_TAKER_SUBMITTED_FEATURE) == target) {
            return;
        }

        revert CounterfeitSettler(target);
    }

    /// @dev Decodes and validates the Settler.execute calldata embedded in the AllowanceHolder `data` parameter.
    ///  Ensures: (1) correct function selector, (2) recipient is the pool, (3) buyToken has a price feed.
    function _validateSettlerCalldata(bytes calldata data) private {
        // Minimum length: 4 (selector) + 32×3 (static tuple) + 32 (bytes[] offset) + 32 (bytes32) = 164 bytes
        require(data.length >= 164, InvalidSettlerCalldata());

        // data layout for execute((address,address,uint256),bytes[],bytes32):
        //   [0:4]   selector (packed, not ABI-padded)
        //   [4:36]  slippage.recipient
        //   [36:68] slippage.buyToken
        //   [68:100] slippage.minAmountOut
        bytes4 selector = bytes4(data[:4]);

        // Only allow Settler.execute — not executeWithPermit or executeMetaTxn.
        require(selector == ISettlerTakerSubmitted.execute.selector, UnsupportedSettlerFunction());

        // Decode AllowedSlippage tuple fields using type-safe abi.decode.
        (address recipient, address buyToken, ) = abi.decode(data[4:100], (address, address, uint256));

        // Recipient must be this contract (the pool, in delegatecall context).
        require(recipient == address(this), RecipientNotSmartPool());

        // Assert buyToken has a registered price feed in the oracle.
        _assertTokenOutHasPriceFeed(buyToken);

        // Scan the actions array for forbidden action selectors (RFQ).
        _checkNoForbiddenActions(data);
    }

    /// @dev Verifies the buyToken has a price feed and adds it to the active tokens set if new.
    function _assertTokenOutHasPriceFeed(address buyToken) private {
        AddressSet storage values = StorageLib.activeTokensSet();
        values.addUnique(IEOracle(address(this)), buyToken, StorageLib.pool().baseToken);
    }

    /// @dev Scans the settler's actions array and reverts if any action uses RFQ.
    ///  RFQ allows arbitrary counterparty at arbitrary price — unlike DEX swaps (which execute
    ///  at on-chain market price), RFQ has no on-chain price reference. A rogue maker can sign
    ///  a quote at any price, and a phished pool owner or malicious agent would submit it.
    ///  Our recipient/buyToken/priceFeed checks do NOT protect against this because minAmountOut
    ///  is controlled by the same (potentially compromised) submitter.
    ///  The actions array is ABI-encoded as bytes[] inside the Settler.execute calldata.
    function _checkNoForbiddenActions(bytes calldata data) private pure {
        // data[100:132] = offset to bytes[] actions, relative to params start at data[4:]
        uint256 actionsOffset = abi.decode(data[100:132], (uint256));
        uint256 arrStart = 4 + actionsOffset;
        uint256 numActions = abi.decode(data[arrStart:arrStart + 32], (uint256));

        for (uint256 i; i < numActions; ++i) {
            // Element offset is at arrStart + 32 + i*32 (relative to arrStart + 32 per ABI spec)
            uint256 elPos = arrStart + 32 + i * 32;
            uint256 elOffset = abi.decode(data[elPos:elPos + 32], (uint256));
            // Element data: arrStart + 32 (content start) + elOffset + 32 (skip length word)
            uint256 selectorPos = arrStart + elOffset + 64;
            bytes4 actionSelector = bytes4(data[selectorPos:selectorPos + 4]);

            if (actionSelector == ISettlerActions.RFQ.selector || actionSelector == ISettlerActions.RFQ_VIP.selector) {
                revert ForbiddenAction(actionSelector);
            }
        }
    }
}
