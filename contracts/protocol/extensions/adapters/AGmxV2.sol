// SPDX-License-Identifier: Apache-2.0-or-later
// solhint-disable-next-line
pragma solidity 0.8.28;

import {EnumerableSet, AddressSet, Bytes32Set} from "../../libraries/EnumerableSet.sol";
import {ApplicationsLib, ApplicationsSlot} from "../../libraries/ApplicationsLib.sol";
import {ReentrancyGuardTransient} from "../../libraries/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";
import {StorageLib} from "../../libraries/StorageLib.sol";
import {Applications} from "../../types/Applications.sol";
import {IWETH9} from "../../interfaces/IWETH9.sol";
import {IEOracle} from "./interfaces/IEOracle.sol";
import {IAGmxV2} from "./interfaces/IAGmxV2.sol";
import {IEGmxCallback} from "./interfaces/IEGmxCallback.sol";
import {IMinimumVersion} from "./interfaces/IMinimumVersion.sol";
import {Order} from "gmx-synthetics/order/Order.sol";
import {IBaseOrderUtils} from "gmx-synthetics/order/IBaseOrderUtils.sol";
import {IGmxOrderHandler} from "../../../utils/exchanges/gmx/IGmxSynthetics.sol";
import {GmxCallbackLib} from "../../libraries/GmxCallbackLib.sol";
import {GmxLib} from "../../libraries/GmxLib.sol";

/// @title AGmxV2 - Facilitates smart pool interaction with the GMX v2 DEX.
/// @custom:security-contact security@rigoblock.com
contract AGmxV2 is IAGmxV2, IMinimumVersion, ReentrancyGuardTransient {
    using EnumerableSet for AddressSet;
    using EnumerableSet for Bytes32Set;
    using SafeTransferLib for address;
    using ApplicationsLib for ApplicationsSlot;

    string private constant _REQUIRED_VERSION = "4.3.2";
    uint256 private constant _MAX_EXECUTION_FEE = 0.05 ether;
    // Gas reserved for the decrease-order callback; benchmarked worst case ~349k.
    uint256 private constant _CALLBACK_GAS_LIMIT = 500_000;

    address private immutable _adapter;

    constructor() {
        require(block.chainid == GmxLib.ARBITRUM_CHAIN_ID, NotArbitrum());
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

    /// @inheritdoc IAGmxV2
    function createIncreaseOrder(
        IBaseOrderUtils.CreateOrderParams calldata params
    ) external override nonReentrant onlyDelegateCall returns (bytes32 orderKey) {
        // Cap concurrent positions (new positions only; increasing an existing slot is allowed).
        GmxLib.assertPositionLimitNotReached(
            address(this),
            params.addresses.market,
            params.addresses.initialCollateralToken,
            params.isLong
        );

        // Increase orders have no per-order callback; factor=0 excludes callback gas from the fee.
        uint256 executionFee = GmxLib.computeExecutionFee(true, 0);
        require(executionFee <= _MAX_EXECUTION_FEE, ExecutionFeeExceedsMax());

        require(params.orderType == Order.OrderType.MarketIncrease, InvalidIncreaseOrderType());
        _trackToken(params.addresses.initialCollateralToken);

        // Track the PnL token so keeper-driven closes/liquidations remain visible to NAV.
        address pnlToken = GmxLib.getPnlToken(params.addresses.market, params.isLong);
        if (pnlToken != params.addresses.initialCollateralToken) {
            _trackToken(pnlToken);
        }

        // Reject markets whose indexToken cannot be priced through the GMX provider or a hardcoded fallback.
        address indexToken = GmxLib.getMarketIndexToken(params.addresses.market);
        require(GmxLib.isIndexTokenPriced(indexToken), UnpricedIndexToken(indexToken));

        address orderVault = GmxLib.GMX_ROUTER.orderHandler().orderVault();

        bool collateralIsWrappedNative = params.addresses.initialCollateralToken == GmxLib.WRAPPED_NATIVE;

        if (collateralIsWrappedNative) {
            // WETH collateral: GMX deducts fee from vault WNT, so send collateral + fee together.
            uint256 total = params.numbers.initialCollateralDeltaAmount + executionFee;
            _ensureWeth(total);
            GmxLib.WRAPPED_NATIVE.safeTransfer(orderVault, total);
        } else {
            _ensureWeth(executionFee);
            params.addresses.initialCollateralToken.safeTransfer(
                orderVault,
                params.numbers.initialCollateralDeltaAmount
            );
            GmxLib.WRAPPED_NATIVE.safeTransfer(orderVault, executionFee);
        }

        orderKey = GmxLib.GMX_ROUTER.createOrder(
            IBaseOrderUtils.CreateOrderParams({
                addresses: IBaseOrderUtils.CreateOrderParamsAddresses({
                    receiver: address(this),
                    cancellationReceiver: address(this),
                    callbackContract: address(0),
                    uiFeeReceiver: address(this),
                    market: params.addresses.market,
                    initialCollateralToken: params.addresses.initialCollateralToken,
                    swapPath: new address[](0)
                }),
                numbers: IBaseOrderUtils.CreateOrderParamsNumbers({
                    sizeDeltaUsd: params.numbers.sizeDeltaUsd,
                    initialCollateralDeltaAmount: params.numbers.initialCollateralDeltaAmount,
                    triggerPrice: 0,
                    acceptablePrice: params.numbers.acceptablePrice,
                    executionFee: executionFee,
                    callbackGasLimit: 0,
                    minOutputAmount: 0,
                    validFromTime: 0
                }),
                orderType: Order.OrderType.MarketIncrease,
                decreasePositionSwapType: Order.DecreasePositionSwapType.NoSwap,
                isLong: params.isLong,
                shouldUnwrapNativeToken: false,
                autoCancel: false,
                referralCode: bytes32(0),
                dataList: new bytes32[](0)
            })
        );

        // Register pool as the saved callback so liquidations/ADLs reach the extension.
        GmxLib.GMX_ROUTER.setSavedCallbackContract(params.addresses.market, address(this));

        // Track the market now (not only in the decrease callback) so funding fees are still
        // queryable even if a future callback fails.
        _trackMarket(params.addresses.market);

        StorageLib.activeApplications().storeApplication(uint256(Applications.GMX_V2_POSITIONS));
    }

    /// @inheritdoc IAGmxV2
    function createDecreaseOrder(
        IBaseOrderUtils.CreateOrderParams calldata params
    ) external override nonReentrant onlyDelegateCall returns (bytes32 orderKey) {
        // Decrease orders reserve callback gas so afterOrderExecution can record claimable rebates.
        uint256 executionFee = GmxLib.computeExecutionFee(false, _CALLBACK_GAS_LIMIT);
        require(executionFee <= _MAX_EXECUTION_FEE, ExecutionFeeExceedsMax());

        address orderVault = GmxLib.GMX_ROUTER.orderHandler().orderVault();
        require(
            params.orderType == Order.OrderType.MarketDecrease ||
                params.orderType == Order.OrderType.LimitDecrease ||
                params.orderType == Order.OrderType.StopLossDecrease,
            InvalidDecreaseOrderType()
        );
        _ensureWeth(executionFee);
        GmxLib.WRAPPED_NATIVE.safeTransfer(orderVault, executionFee);

        orderKey = GmxLib.GMX_ROUTER.createOrder(
            IBaseOrderUtils.CreateOrderParams({
                addresses: IBaseOrderUtils.CreateOrderParamsAddresses({
                    receiver: address(this),
                    cancellationReceiver: address(this),
                    callbackContract: address(this),
                    uiFeeReceiver: address(this),
                    market: params.addresses.market,
                    initialCollateralToken: params.addresses.initialCollateralToken,
                    swapPath: new address[](0)
                }),
                numbers: IBaseOrderUtils.CreateOrderParamsNumbers({
                    sizeDeltaUsd: params.numbers.sizeDeltaUsd,
                    initialCollateralDeltaAmount: params.numbers.initialCollateralDeltaAmount,
                    triggerPrice: params.numbers.triggerPrice,
                    acceptablePrice: params.numbers.acceptablePrice,
                    executionFee: executionFee,
                    callbackGasLimit: _CALLBACK_GAS_LIMIT,
                    minOutputAmount: params.numbers.minOutputAmount,
                    validFromTime: params.numbers.validFromTime
                }),
                orderType: params.orderType,
                // NoSwap keeps output in the tracked collateral token; other modes could return
                // the untracked index token and break NAV accounting.
                decreasePositionSwapType: Order.DecreasePositionSwapType.NoSwap,
                isLong: params.isLong,
                shouldUnwrapNativeToken: false,
                autoCancel: params.autoCancel,
                referralCode: bytes32(0),
                dataList: new bytes32[](0)
            })
        );

        // Re-register saved callback in case this market was opened through a prior adapter.
        GmxLib.GMX_ROUTER.setSavedCallbackContract(params.addresses.market, address(this));
    }

    /// @inheritdoc IAGmxV2
    function updateOrder(
        bytes32 key,
        uint256 sizeDeltaUsd,
        uint256 acceptablePrice,
        uint256 triggerPrice,
        uint256 minOutputAmount,
        uint256 validFromTime,
        bool autoCancel
    ) external override nonReentrant onlyDelegateCall {
        // Top up fee at current gas price; use decrease-order limit because updated orders may
        // still trigger the rebate callback.
        uint256 feeTopUp = GmxLib.computeExecutionFee(false, _CALLBACK_GAS_LIMIT);
        require(feeTopUp <= _MAX_EXECUTION_FEE, ExecutionFeeExceedsMax());
        if (feeTopUp > 0) {
            address orderVault = GmxLib.GMX_ROUTER.orderHandler().orderVault();
            _ensureWeth(feeTopUp);
            GmxLib.WRAPPED_NATIVE.safeTransfer(orderVault, feeTopUp);
        }

        GmxLib.GMX_ROUTER.updateOrder(
            key,
            sizeDeltaUsd,
            acceptablePrice,
            triggerPrice,
            minOutputAmount,
            validFromTime,
            autoCancel
        );
    }

    /// @inheritdoc IAGmxV2
    function cancelOrder(bytes32 key) external override nonReentrant onlyDelegateCall {
        // GMX refunds to cancellationReceiver (the pool).
        GmxLib.GMX_ROUTER.cancelOrder(key);
    }

    /// @inheritdoc IAGmxV2
    function claimFundingFees(
        address[] calldata markets,
        address[] calldata tokens,
        address // receiver — overridden to address(this) to ensure funds stay in the pool
    ) external override nonReentrant onlyDelegateCall {
        for (uint256 i; i < tokens.length; ++i) {
            _trackToken(tokens[i]);
        }
        GmxLib.GMX_ROUTER.claimFundingFees(markets, tokens, address(this));

        // Prune tracked markets that no longer have open positions or outstanding
        // claimable funding fees. Keeps the NAV iteration set minimal.
        for (uint256 i; i < markets.length; ++i) {
            if (
                GmxCallbackLib.containsTrackedMarket(markets[i]) &&
                !GmxLib.isMarketActive(address(this), markets[i]) &&
                !GmxLib.hasClaimableFundingFees(address(this), markets[i])
            ) {
                GmxCallbackLib.removeTrackedMarket(markets[i]);
                emit IEGmxCallback.TrackedMarketRemoved(markets[i]);
            }
        }
    }

    /// @inheritdoc IAGmxV2
    function claimCollateral(
        address[] calldata markets,
        address[] calldata tokens,
        uint256[] calldata timeKeys,
        address // receiver — overridden to address(this) to ensure funds stay in the pool
    ) external override nonReentrant onlyDelegateCall {
        for (uint256 i; i < tokens.length; ++i) {
            _trackToken(tokens[i]);
        }
        GmxLib.GMX_ROUTER.claimCollateral(markets, tokens, timeKeys, address(this));

        // Discard fully-claimed collateral keys so the NAV loop stops reading them.
        GmxCallbackLib.GmxCallbackSlot storage callbackData = GmxCallbackLib.gmxCallbackData();
        for (uint256 i; i < markets.length; ++i) {
            bytes32 amountKey = keccak256(
                abi.encode(
                    GmxCallbackLib.CLAIMABLE_COLLATERAL_AMOUNT_KEY,
                    markets[i],
                    tokens[i],
                    timeKeys[i],
                    address(this)
                )
            );
            if (
                callbackData.claimableCollateralKeys.contains(amountKey) &&
                GmxLib.claimableCollateralAmount(amountKey, address(this)) == 0
            ) {
                GmxCallbackLib.removeClaimableCollateralKey(amountKey);
                emit IEGmxCallback.ClaimableCollateralRemoved(amountKey);
            }
        }
    }

    /// @dev Adds `token` to the pool's active-tokens set for NAV visibility. Called at order-create
    ///  time because keeper settlement does not invoke the adapter. Guard address(0) because GMX
    ///  always uses WETH, not the native sentinel.
    function _trackToken(address token) private {
        if (token == address(0)) {
            return;
        }

        StorageLib.activeTokensSet().addUnique(IEOracle(address(this)), token, StorageLib.pool().baseToken);
    }

    /// @dev Records `market` in callback storage so NAV can query post-close funding fees.
    function _trackMarket(address market) private {
        if (!GmxCallbackLib.containsTrackedMarket(market)) {
            GmxCallbackLib.addTrackedMarket(market);
            emit IEGmxCallback.TrackedMarketAdded(market);
        }
    }

    /// @dev Ensures the pool holds at least `amount` WETH, wrapping from native ETH if needed.
    function _ensureWeth(uint256 amount) private {
        uint256 wethBal = IWETH9(GmxLib.WRAPPED_NATIVE).balanceOf(address(this));
        if (wethBal < amount) {
            uint256 deficit = amount - wethBal;
            require(address(this).balance >= deficit, InsufficientNativeBalance());
            IWETH9(GmxLib.WRAPPED_NATIVE).deposit{value: deficit}();
        }
    }
}
