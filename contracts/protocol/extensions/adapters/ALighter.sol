// SPDX-License-Identifier: Apache-2.0-or-later
// solhint-disable-next-line
pragma solidity 0.8.37;

import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";
import {ReentrancyGuardTransient} from "../../libraries/ReentrancyGuardTransient.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {ApplicationsLib, ApplicationsSlot} from "../../libraries/ApplicationsLib.sol";
import {StorageLib} from "../../libraries/StorageLib.sol";
import {LighterLib} from "../../libraries/LighterLib.sol";
import {Applications} from "../../types/Applications.sol";
import {LighterConstants} from "../../types/LighterConstants.sol";
import {ILighterInteropManager, LighterRouteType} from "./interfaces/lighter/ILighterInteropManager.sol";
import {ILighterCoreEntrypoint} from "./interfaces/lighter/ILighterCoreEntrypoint.sol";
import {IALighter} from "./interfaces/IALighter.sol";
import {IMinimumVersion} from "./interfaces/IMinimumVersion.sol";

/// @title ALighter - Facilitates smart pool interaction with LighterCore perps.
/// @notice Perps-only, USDC-only: deposits go straight to the Core perps route (no spot step).
///  Positions are valued on-chain by EAppsLighter from READ_CORE mark prices over pool-tracked
///  markets (see docs/lighter/INTEGRATION.md): the adapter owns writes, the extension owns NAV.
/// @custom:security-contact security@rigoblock.com
contract ALighter is IALighter, IMinimumVersion, ReentrancyGuardTransient {
    using SafeTransferLib for address;
    using ApplicationsLib for ApplicationsSlot;

    string private constant _REQUIRED_VERSION = "4.5.2";

    address private immutable _adapter;

    constructor() {
        require(block.chainid == LighterConstants.LIGHTEREVM_CHAIN_ID, NotLighterEVM());
        _adapter = address(this);
    }

    modifier onlyDelegateCall() {
        require(address(this) != _adapter, DirectCallNotAllowed());
        _;
    }

    /// @inheritdoc IMinimumVersion
    function requiredVersion() external pure override returns (string memory) {
        return _REQUIRED_VERSION;
    }

    /// @inheritdoc ILighterInteropManager
    /// @notice Deposits pool USDC into the pool's LighterCore perps margin.
    /// @dev The pool must be the recipient (`to`) and the perps route is forced; USDC approval to the
    ///  interop manager follows the per-call approve/reset-to-1 pattern.
    function sendToCore(
        uint32 assetIndex,
        address to,
        bool isL1Account,
        uint256 amount,
        LighterRouteType routeType
    ) external payable override nonReentrant onlyDelegateCall returns (uint64 reqId) {
        // ETH is not a supported collateral: the deposit is USDC-only.
        require(msg.value == 0, InvalidAmount());
        require(assetIndex == LighterConstants.USDC_ASSET_INDEX, InvalidAsset());
        require(to == address(this) && !isL1Account, InvalidRecipient());
        require(routeType == LighterRouteType.Perps, InvalidRoute());
        require(amount > 0, InvalidAmount());

        address usdc = LighterConstants.USDC;
        address manager = LighterConstants.EVM_INTEROP_MANAGER;
        usdc.safeApprove(manager, amount);
        reqId = ILighterInteropManager(manager).sendToCore(assetIndex, to, isL1Account, amount, routeType);
        if (IERC20(usdc).allowance(address(this), manager) > 1) {
            usdc.safeApprove(manager, 1);
        }

        StorageLib.activeApplications().storeApplication(uint256(Applications.LIGHTER_PERPS));
        LighterLib.recordAction(int256(amount), reqId);
        emit Deposited(amount);
    }

    /// @inheritdoc ILighterInteropManager
    /// @notice Withdraws USDC from the pool's LighterCore perps margin back to the pool.
    /// @dev The pool is forced as the EVM recipient, making the withdrawal NAV-neutral on arrival.
    function sendToEvm(
        uint48 accountIndex,
        uint32 assetIndex,
        address evmRecipient,
        LighterRouteType routeType,
        uint64 baseAmount
    ) external override nonReentrant onlyDelegateCall returns (uint64 reqId) {
        require(assetIndex == LighterConstants.USDC_ASSET_INDEX, InvalidAsset());
        require(evmRecipient == address(this), InvalidRecipient());
        require(routeType == LighterRouteType.Perps, InvalidRoute());
        require(baseAmount > 0, InvalidAmount());

        reqId = ILighterInteropManager(LighterConstants.EVM_INTEROP_MANAGER).sendToEvm(
            _requireAccountIndex(),
            assetIndex,
            evmRecipient,
            routeType,
            baseAmount
        );

        // USDC's Core tickSize is 1: base units are already 6-decimal USDC.
        LighterLib.recordAction(-int256(uint256(baseAmount)), reqId);
        emit Withdrawn(baseAmount);
    }

    /// @inheritdoc ILighterCoreEntrypoint
    /// @notice Creates a perp order on LighterCore; the market is tracked automatically on first
    ///  trade so it is always valued in NAV. Core rejects unsupported order types (e.g. TWAP,
    ///  orderType 6) asynchronously with an error code on the reqId status.
    function createOrder(
        uint48 accountIndex,
        uint16 marketIndex,
        uint48 clientOrderIndex,
        uint8 orderType,
        uint8 timeInForce,
        uint64 orderExpiry,
        uint48 amount,
        uint32 price,
        bool isAsk,
        bool reduceOnly,
        uint32 triggerPrice
    ) external override nonReentrant onlyDelegateCall returns (uint64 reqId) {
        require(marketIndex < LighterConstants.FIRST_SPOT_MARKET_ID, InvalidMarket());
        LighterLib.trackMarket(marketIndex);

        reqId = ILighterCoreEntrypoint(LighterConstants.CORE_ENTRYPOINT).createOrder(
            _requireAccountIndex(),
            marketIndex,
            clientOrderIndex,
            orderType,
            timeInForce,
            orderExpiry,
            amount,
            price,
            isAsk,
            reduceOnly,
            triggerPrice
        );
        emit OrderSent(reqId);
    }

    /// @inheritdoc ILighterCoreEntrypoint
    function cancelOrder(
        uint48 accountIndex,
        uint64 orderIndex
    ) external override nonReentrant onlyDelegateCall returns (uint64 reqId) {
        reqId = ILighterCoreEntrypoint(LighterConstants.CORE_ENTRYPOINT).cancelOrder(
            _requireAccountIndex(),
            orderIndex
        );
        emit OrderSent(reqId);
    }

    /// @inheritdoc ILighterCoreEntrypoint
    function cancelAllOrders(
        uint48 accountIndex
    ) external override nonReentrant onlyDelegateCall returns (uint64 reqId) {
        reqId = ILighterCoreEntrypoint(LighterConstants.CORE_ENTRYPOINT).cancelAllOrders(_requireAccountIndex());
        emit OrderSent(reqId);
    }

    /// @notice Emitted when the operator abandons a transfer whose async EVM-side leg never landed.
    event InFlightLegAbandoned();

    /// @notice Emitted when the operator confirms that the outstanding async EVM-side leg of the
    ///  recorded transfer has landed, clearing the record and lifting the mint/burn lock.
    event TransferLegConfirmed(uint64 indexed reqId);

    /// @notice Confirms that the outstanding async EVM-side leg of the recorded transfer has
    ///  landed — the only automatic-safe alternative to carrying the leg forever, since landing
    ///  cannot be detected on-chain (a direct ERC-20 transfer is indistinguishable from the
    ///  delivery). Write access is owner-gated by MixinFallback.
    /// @dev Confirm only after verifying the delivery receipt off-chain (per Lighter's docs, via
    ///  the Core transaction's event_info). Requires the request confirmed on Core and the wallet
    ///  grown by at least the outstanding amount, so a smaller unrelated inflow cannot be
    ///  mistaken for the landing. Fully-accepted deposits need no confirmation: they self-clear.
    function confirmTransferLanded() external nonReentrant onlyDelegateCall {
        uint64 reqId = StorageLib.lighterSlot().data.lastReqId;
        LighterLib.confirmLegLanded();
        emit TransferLegConfirmed(reqId);
    }

    /// @notice Releases a stuck transfer record whose async EVM-side leg never landed — the
    ///  recovery for the documented never-landing-leg case (a reverted delivery is never retried
    ///  and the funds are lost per Lighter's docs). Write access is owner-gated by MixinFallback.
    /// @dev Only abandon after verifying off-chain — per Lighter's docs, the delivery receipt via
    ///  the Core transaction's event_info — that the leg will not land: abandoning a live leg
    ///  drops its carry from NAV, so a late landing mints against an understated NAV.
    function abandonInFlightLeg() external nonReentrant onlyDelegateCall {
        LighterLib.abandonAction();
        emit InFlightLegAbandoned();
    }

    /// @dev Resolves the pool's own Core account index; reverts if the pool has no Core account yet
    ///  (created automatically by the first deposit).
    function _requireAccountIndex() private view returns (uint48) {
        require(LighterLib.coreAccountExists(address(this)), AccountNotActivated());
        return LighterLib.readEvmAccountIndex(address(this));
    }
}
