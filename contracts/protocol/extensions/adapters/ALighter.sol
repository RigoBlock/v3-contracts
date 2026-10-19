// SPDX-License-Identifier: Apache-2.0-or-later
// solhint-disable-next-line
pragma solidity 0.8.37;

import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";
import {ReentrancyGuardTransient} from "../../libraries/ReentrancyGuardTransient.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {ApplicationsLib, ApplicationsSlot} from "../../libraries/ApplicationsLib.sol";
import {StorageLib} from "../../libraries/StorageLib.sol";
import {LighterLib} from "../../libraries/LighterLib.sol";
import {Applications, LighterViewData} from "../../types/Applications.sol";
import {AppTokenBalance} from "../../types/ExternalApp.sol";
import {LighterConstants} from "../../types/LighterConstants.sol";
import {IEApps} from "../adapters/interfaces/IEApps.sol";
import {ILighterInteropManager, LighterRouteType} from "./interfaces/lighter/ILighterInteropManager.sol";
import {ILighterCoreEntrypoint} from "./interfaces/lighter/ILighterCoreEntrypoint.sol";
import {IALighter} from "./interfaces/IALighter.sol";
import {IMinimumVersion} from "./interfaces/IMinimumVersion.sol";

/// @title ALighter - Facilitates smart pool interaction with LighterCore perps.
/// @notice Perps-only, USDC-only: deposits go straight to the Core perps route (no spot step),
///  positions are valued on-chain from READ_CORE mark prices over operator-tracked markets.
/// @custom:security-contact security@rigoblock.com
contract ALighter is IALighter, IMinimumVersion, ReentrancyGuardTransient {
    using SafeTransferLib for address;
    using ApplicationsLib for ApplicationsSlot;

    string private constant _REQUIRED_VERSION = "4.5.0";

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
    /// @notice Creates a perp order on LighterCore. The market must have been tracked first:
    ///  every market the pool can trade is valued in NAV (see docs/lighter/API_KEYS.md).
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
        require(LighterLib.isTrackedMarket(marketIndex), LighterLib.MarketNotTracked());

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

    /// @inheritdoc IALighter
    /// @dev Callable only by the pool owner (enforced by MixinFallback's delegatecall routing).
    function trackMarket(uint16 marketId, uint8 sizeDecimals, uint8 priceDecimals) external override onlyDelegateCall {
        LighterLib.trackMarket(marketId, sizeDecimals, priceDecimals);
        emit MarketTracked(marketId);
    }

    /// @inheritdoc IALighter
    /// @dev Callable only by the pool owner (enforced by MixinFallback's delegatecall routing).
    function untrackMarket(uint16 marketId) external override onlyDelegateCall {
        require(LighterLib.positionSize(address(this), marketId) == 0, PositionNotClosed());
        LighterLib.untrackMarket(marketId);
        emit MarketUntracked(marketId);
    }

    /// @notice Returns the given pool's Lighter balances valued in USDC (6 decimals).
    /// @dev Executed under staticcall via the pool fallback (see IALighter.getLighterBalances):
    ///  reads its tracked markets and in-flight accounting from EApps, then computes the NAV
    ///  from READ_CORE so LighterLib compiles only into this adapter.
    function getLighterBalances(address pool) external view override returns (AppTokenBalance[] memory) {
        LighterViewData memory viewData = IEApps(pool).getLighterTrackedMarkets();
        return LighterLib.getLighterBalances(pool, viewData);
    }

    /// @dev Resolves the pool's own Core account index; reverts if the pool has no Core account yet
    ///  (created automatically by the first deposit).
    function _requireAccountIndex() private view returns (uint48) {
        require(LighterLib.coreAccountExists(address(this)), AccountNotActivated());
        return LighterLib.readEvmAccountIndex(address(this));
    }
}
