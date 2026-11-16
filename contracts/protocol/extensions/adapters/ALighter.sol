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

    string private constant _REQUIRED_VERSION = "4.5.3";

    address private immutable _adapter;

    /// @notice Core order type 6 (TWAP): rejected by Core with code 6514 (devnet 1.2.0); the
    ///  adapter fails the write synchronously instead.
    uint8 private constant _ORDER_TYPE_TWAP = 6;

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
    /// @notice Creates a perp order on LighterCore. The market is tracked automatically on first
    ///  trade so it is always valued in NAV (see docs/lighter/API_KEYS.md for the API-key caveat).
    /// @dev TWAP orders (orderType 6) are rejected synchronously: Core rejects them with code
    ///  6514 asynchronously, so failing early saves a guaranteed-to-fail write.
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
        require(orderType != _ORDER_TYPE_TWAP, InvalidOrderType());
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

    /// @notice Clears the settled transfer record, unlocking mint/burn after the async EVM-side leg
    ///  (refund/delivery) has been verified off-chain to have landed (see docs/lighter/INTEGRATION.md,
    ///  "In-flight accounting": the landing is not observable on-chain, so attestation is
    ///  owner-gated — this method is only reachable by the pool owner via MixinFallback).
    /// @dev Reverts PendingRequest-style semantics do not apply: while a request is still pending
    ///  (status 0) there is nothing to sync — NAV is already exact and unlocked.
    function syncTransfer() external nonReentrant onlyDelegateCall {
        uint64 lastReqId = StorageLib.lighterSlot().data.lastReqId;
        require(lastReqId != 0, NothingToSync());
        // A pending request must not be synced: it is valued exactly by the in-flight amount and
        //  unlocking early would drop that amount from NAV.
        require(LighterLib.readTxStatus(lastReqId) != 0, LighterLib.PendingRequest());
        LighterLib.clearAction();
        emit TransferSynced();
    }

    /// @dev Resolves the pool's own Core account index; reverts if the pool has no Core account yet
    ///  (created automatically by the first deposit).
    function _requireAccountIndex() private view returns (uint48) {
        require(LighterLib.coreAccountExists(address(this)), AccountNotActivated());
        return LighterLib.readEvmAccountIndex(address(this));
    }
}
