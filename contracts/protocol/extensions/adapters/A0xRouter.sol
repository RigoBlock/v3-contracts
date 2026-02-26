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

import {ISettlerActions} from "0x-settler/src/ISettlerActions.sol";
import {IAllowanceHolder} from "0x-settler/src/allowanceholder/IAllowanceHolder.sol";
import {ISettlerTakerSubmitted} from "0x-settler/src/interfaces/ISettlerTakerSubmitted.sol";
import {IDeployer} from "0x-settler/src/deployer/IDeployer.sol";
import {Feature} from "0x-settler/src/deployer/Feature.sol";

/// @title A0xRouter - Allows smart pool swaps via the 0x swap aggregator.
/// @author Gabriele Rigo - <gab@rigoblock.com>
/// @dev See docs/0x/ACTION_ALLOWLIST.md for security rationale and blocked action details.
contract A0xRouter is IA0xRouter, IMinimumVersion, ReentrancyGuardTransient {
    using EnumerableSet for AddressSet;
    using SafeTransferLib for address;

    string private constant _REQUIRED_VERSION = "4.0.0";

    /// @dev Sentinel address defined in 0x SettlerAbstract.ETH_ADDRESS for native currency.
    address private constant _ETH_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    address private immutable _adapter;
    IAllowanceHolder private immutable _allowanceHolder;
    IDeployer private immutable _deployer;

    /// @dev Feature 2 = Taker Submitted (same-chain swaps). Not importable from settler.
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
        _requireGenuineSettler(target);
        _validateSettlerCalldata(data);

        bool isNativeETH = token.isAddressZero() || token == _ETH_SENTINEL;
        uint256 value = isNativeETH ? amount : 0;

        // Approve max before call — ERC20 skips allowance deduction at type(uint256).max.
        if (!isNativeETH) {
            token.safeApprove(address(_allowanceHolder), type(uint256).max);
        }

        try _allowanceHolder.exec{value: value}(operator, token, amount, target, data) returns (bytes memory result) {
            // Reset to 1 after success — no hanging approvals, slot stays warm.
            if (!isNativeETH) {
                token.safeApprove(address(_allowanceHolder), 1);
            }
            return result;
        } catch Error(string memory reason) {
            revert(reason);
        } catch (bytes memory returnData) {
            if (value > address(this).balance) {
                revert InsufficientNativeBalance();
            }
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }

    /// @dev Reverts if the action selector is not in the allowlist.
    ///  BASIC is allowed because the 0x API uses it for ETH wrapping/unwrapping and intermediate
    ///  protocol interactions. The settler's _isRestrictedTarget() prevents BASIC from calling
    ///  Permit2, AllowanceHolder, or the settler itself. The settler's slippage check
    ///  (_checkSlippageAndTransfer) ensures minimum output, preventing fund loss.
    function _assertIsAllowedAction(bytes4 s) private pure {
        require(
            s == ISettlerActions.TRANSFER_FROM.selector ||
                s == ISettlerActions.NATIVE_CHECK.selector ||
                s == ISettlerActions.POSITIVE_SLIPPAGE.selector ||
                s == ISettlerActions.BASIC.selector ||
                s == ISettlerActions.UNISWAPV2.selector ||
                s == ISettlerActions.UNISWAPV3.selector ||
                s == ISettlerActions.UNISWAPV3_VIP.selector ||
                s == ISettlerActions.UNISWAPV4.selector ||
                s == ISettlerActions.UNISWAPV4_VIP.selector ||
                s == ISettlerActions.BALANCERV3.selector ||
                s == ISettlerActions.BALANCERV3_VIP.selector ||
                s == ISettlerActions.PANCAKE_INFINITY.selector ||
                s == ISettlerActions.PANCAKE_INFINITY_VIP.selector ||
                s == ISettlerActions.CURVE_TRICRYPTO_VIP.selector ||
                s == ISettlerActions.MAVERICKV2.selector ||
                s == ISettlerActions.MAVERICKV2_VIP.selector ||
                s == ISettlerActions.DODOV1.selector ||
                s == ISettlerActions.DODOV2.selector ||
                s == ISettlerActions.VELODROME.selector ||
                s == ISettlerActions.MAKERPSM.selector ||
                s == ISettlerActions.BEBOP.selector ||
                s == ISettlerActions.EKUBO.selector ||
                s == ISettlerActions.EKUBOV3.selector ||
                s == ISettlerActions.EKUBO_VIP.selector ||
                s == ISettlerActions.EKUBOV3_VIP.selector ||
                s == ISettlerActions.EULERSWAP.selector ||
                s == ISettlerActions.LFJTM.selector ||
                s == ISettlerActions.HANJI.selector,
            ActionNotAllowed(s)
        );
    }

    /// @dev Adds buyToken to active tokens if it has a valid price feed.
    ///  Maps the 0x ETH sentinel (0xEeee...) to address(0) because the EOracle recognizes
    ///  address(0) and wrappedNative as having price feeds, but not the sentinel.
    function _assertTokenOutHasPriceFeed(address buyToken) private {
        if (buyToken == _ETH_SENTINEL) {
            buyToken = address(0);
        }
        AddressSet storage values = StorageLib.activeTokensSet();
        values.addUnique(IEOracle(address(this)), buyToken, StorageLib.pool().baseToken);
    }

    /// @dev Iterates settler actions and validates each selector against the allowlist.
    function _checkActionsAllowed(bytes calldata data) private pure {
        // ABI layout: data[100:132] = offset to actions[] (4th word after selector).
        uint256 actionsOffset = abi.decode(data[100:132], (uint256));
        uint256 arrStart = 4 + actionsOffset;
        uint256 numActions = abi.decode(data[arrStart:arrStart + 32], (uint256));

        for (uint256 i; i < numActions; ++i) {
            uint256 elPos = arrStart + 32 + i * 32;
            uint256 elOffset = abi.decode(data[elPos:elPos + 32], (uint256));
            uint256 selectorPos = arrStart + elOffset + 64;
            bytes4 actionSelector = bytes4(data[selectorPos:selectorPos + 4]);
            _assertIsAllowedAction(actionSelector);
        }
    }

    /// @dev Verifies target is current or previous Feature 2 settler via the Deployer registry.
    function _requireGenuineSettler(address target) private view {
        require(
            _deployer.ownerOf(Feature.unwrap(_TAKER_SUBMITTED_FEATURE)) == target ||
                _deployer.prev(_TAKER_SUBMITTED_FEATURE) == target,
            CounterfeitSettler(target)
        );
    }

    /// @dev Validates settler calldata: correct selector, recipient, price feed, and action allowlist.
    function _validateSettlerCalldata(bytes calldata data) private {
        require(data.length >= 164, InvalidSettlerCalldata());

        require(bytes4(data[:4]) == ISettlerTakerSubmitted.execute.selector, UnsupportedSettlerFunction());

        (address recipient, address buyToken) = abi.decode(data[4:68], (address, address));
        require(recipient == address(this), RecipientNotSmartPool());

        _assertTokenOutHasPriceFeed(buyToken);
        _checkActionsAllowed(data);
    }
}
