// SPDX-License-Identifier: Apache-2.0-or-later
// solhint-disable-next-line
pragma solidity 0.8.28;

import {EnumerableSet, AddressSet} from "../../libraries/EnumerableSet.sol";
import {ApplicationsLib, ApplicationsSlot} from "../../libraries/ApplicationsLib.sol";
import {ReentrancyGuardTransient} from "../../libraries/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";
import {StorageLib} from "../../libraries/StorageLib.sol";
import {Applications} from "../../types/Applications.sol";
import {IWETH9} from "../../interfaces/IWETH9.sol";
import {IEOracle} from "./interfaces/IEOracle.sol";
import {IAGmxV2} from "./interfaces/IAGmxV2.sol";
import {IMinimumVersion} from "./interfaces/IMinimumVersion.sol";
import {Order} from "gmx-synthetics/order/Order.sol";
import {IBaseOrderUtils} from "gmx-synthetics/order/IBaseOrderUtils.sol";
import {IGmxOrderHandler} from "../../../utils/exchanges/gmx/IGmxSynthetics.sol";
import {GmxLib} from "../../libraries/GmxLib.sol";

/// @title AGmxV2 - Facilitates smart pool interaction with the GMX v2 DEX.
/// @custom:security-contact security@rigoblock.com
contract AGmxV2 is IAGmxV2, IMinimumVersion, ReentrancyGuardTransient {
    using EnumerableSet for AddressSet;
    using SafeTransferLib for address;
    using ApplicationsLib for ApplicationsSlot;

    string private constant _REQUIRED_VERSION = "4.1.2";
    uint256 private constant _MAX_EXECUTION_FEE = 0.05 ether;

    // =========================================================================
    // Immutables
    // =========================================================================

    /// @dev Address of this deployed adapter instance. Used to detect direct (non-delegatecall) calls.
    address private immutable _adapter;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @dev No constructor parameters: all canonical GMX and WETH addresses are
    ///  hardcoded constants in GmxLib and referenced here via GmxLib.GMX_EXCHANGE_ROUTER
    ///  and GmxLib.WRAPPED_NATIVE.  If GMX upgrades a contract, a new adapter must be
    ///  deployed regardless (encoding changes), so immutables add no value.
    ///  Execution fees are computed on-chain from the GMX DataStore at order-creation time via
    ///  GmxLib.computeExecutionFee (adjustedGasLimit × tx.gasprice).  In eth_call simulations
    ///  tx.gasprice is 0, so the simulated WETH consumption is understated; actual execution is correct.
    constructor() {
        require(block.chainid == GmxLib.ARBITRUM_CHAIN_ID, NotArbitrum());
        _adapter = address(this);
    }

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyDelegateCall() {
        require(address(this) != _adapter, DirectCallNotAllowed());
        _;
    }

    // =========================================================================
    // IMinimumVersion
    // =========================================================================

    /// @inheritdoc IMinimumVersion
    function requiredVersion() external pure override returns (string memory) {
        return _REQUIRED_VERSION;
    }

    // =========================================================================
    // IAGmxV2 — order management
    // =========================================================================

    /// @inheritdoc IAGmxV2
    function createIncreaseOrder(
        IBaseOrderUtils.CreateOrderParams calldata params
    ) external override nonReentrant onlyDelegateCall returns (bytes32 orderKey) {
        // Enforce the per-pool position cap before creating a new position.
        GmxLib.assertPositionLimitNotReached(address(this));

        // Compute execution fee on-chain: fee = adjustedGasLimit × tx.gasprice (same formula
        // GMX uses in validateExecutionFee).  Guard against extreme gas prices with the cap.
        uint256 executionFee = GmxLib.computeExecutionFee(true);
        require(executionFee <= _MAX_EXECUTION_FEE, ExecutionFeeExceedsMax());

        _trackToken(params.addresses.initialCollateralToken);

        address orderVault = GmxLib.GMX_ROUTER.orderHandler().orderVault();

        bool collateralIsWrappedNative = params.addresses.initialCollateralToken == GmxLib.WRAPPED_NATIVE;

        if (collateralIsWrappedNative) {
            // WETH collateral: GMX deducts fee from vault WNT, so send collateral + fee in one transfer.
            uint256 total = params.numbers.initialCollateralDeltaAmount + executionFee;
            _ensureWeth(total);
            GmxLib.WRAPPED_NATIVE.safeTransfer(orderVault, total);
        } else {
            // ERC-20 collateral: send collateral token and WETH fee as separate transfers.
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
                // Keep everything in wrapped form so the pool's ERC-20 accounting stays consistent.
                shouldUnwrapNativeToken: false,
                autoCancel: false,
                referralCode: bytes32(0),
                dataList: new bytes32[](0)
            })
        );

        // Mark GMX positions as an active application in pool storage so that
        // getAppTokenBalances() is called during NAV computation.
        StorageLib.activeApplications().storeApplication(uint256(Applications.GMX_V2_POSITIONS));
    }

    /// @inheritdoc IAGmxV2
    function createDecreaseOrder(
        IBaseOrderUtils.CreateOrderParams calldata params
    ) external override nonReentrant onlyDelegateCall returns (bytes32 orderKey) {
        // Compute execution fee on-chain and guard against extreme gas prices.
        uint256 executionFee = GmxLib.computeExecutionFee(false);
        require(executionFee <= _MAX_EXECUTION_FEE, ExecutionFeeExceedsMax());

        // Decrease orders only require the execution fee (in wrapped native); no collateral transfer.
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
                    callbackContract: address(0),
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
                    callbackGasLimit: 0,
                    minOutputAmount: params.numbers.minOutputAmount,
                    validFromTime: params.numbers.validFromTime
                }),
                orderType: params.orderType,
                // Force NoSwap so the output token is always the collateral token (tracked at
                // increase time).  Allowing SwapCollateralTokenToPnlToken would return the
                // market's index token (e.g. WETH on ETH/USD), which is not in the pool's
                // active-tokens set and would therefore be invisible to NAV computation.
                decreasePositionSwapType: Order.DecreasePositionSwapType.NoSwap,
                isLong: params.isLong,
                shouldUnwrapNativeToken: false,
                autoCancel: params.autoCancel,
                referralCode: bytes32(0),
                dataList: new bytes32[](0)
            })
        );
    }

    /// @inheritdoc IAGmxV2
    function updateOrder(UpdateOrderParams calldata params) external override nonReentrant onlyDelegateCall {
        // Top up the execution fee to current gas price.  Use the increase-order gas limit
        // (the larger of the two order types) as a conservative upper bound; excess is refunded
        // by GMX to cancellationReceiver (the pool).  Guarded by the same _MAX_EXECUTION_FEE cap.
        uint256 feeTopUp = GmxLib.computeExecutionFee(true);
        require(feeTopUp <= _MAX_EXECUTION_FEE, ExecutionFeeExceedsMax());
        if (feeTopUp > 0) {
            address orderVault = GmxLib.GMX_ROUTER.orderHandler().orderVault();
            _ensureWeth(feeTopUp);
            GmxLib.WRAPPED_NATIVE.safeTransfer(orderVault, feeTopUp);
        }

        GmxLib.GMX_ROUTER.updateOrder(
            params.key,
            params.sizeDeltaUsd,
            params.acceptablePrice,
            params.triggerPrice,
            params.minOutputAmount,
            params.validFromTime,
            params.autoCancel
        );
    }

    /// @inheritdoc IAGmxV2
    function cancelOrder(bytes32 key) external override nonReentrant onlyDelegateCall {
        // GMX refunds collateral and the leftover execution fee to the cancellationReceiver
        // (set to address(this) on creation), so tokens return to the pool automatically.
        GmxLib.GMX_ROUTER.cancelOrder(key);
    }

    // =========================================================================
    // IAGmxV2 — fee & collateral claims
    // =========================================================================

    /// @inheritdoc IAGmxV2
    function claimFundingFees(
        address[] calldata markets,
        address[] calldata tokens
    ) external override nonReentrant onlyDelegateCall {
        // Register claimed tokens so the pool NAV includes them.
        for (uint256 i; i < tokens.length; ++i) {
            _trackToken(tokens[i]);
        }

        GmxLib.GMX_ROUTER.claimFundingFees(markets, tokens, address(this));
    }

    /// @inheritdoc IAGmxV2
    function claimCollateral(
        address[] calldata markets,
        address[] calldata tokens,
        uint256[] calldata timeKeys
    ) external override nonReentrant onlyDelegateCall {
        // Register claimed tokens so the pool NAV includes them.
        for (uint256 i; i < tokens.length; ++i) {
            _trackToken(tokens[i]);
        }

        GmxLib.GMX_ROUTER.claimCollateral(markets, tokens, timeKeys, address(this));
    }

    // =========================================================================
    // Private helpers
    // =========================================================================

    /// @dev Registers `token` in the pool's active-tokens set if it has a valid price feed
    ///  and is not the base token.  Must be called at order-create time (not close time) because
    ///  keeper execution returns collateral to the pool wallet without calling back into this adapter.
    function _trackToken(address token) private {
        if (token == address(0) || token == GmxLib.WRAPPED_NATIVE) {
            return;
        }

        AddressSet storage activeTokens = StorageLib.activeTokensSet();
        activeTokens.addUnique(IEOracle(address(this)), token, StorageLib.pool().baseToken);
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
