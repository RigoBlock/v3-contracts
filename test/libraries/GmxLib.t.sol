// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Price} from "gmx-synthetics/price/Price.sol";
import {Market} from "gmx-synthetics/market/Market.sol";
import {Position} from "gmx-synthetics/position/Position.sol";
import {Order} from "gmx-synthetics/order/Order.sol";
import {IGmxReader, IGmxDataStore, IGmxChainlinkPriceFeedProvider, GmxValidatedPrice, GmxPositionInfo, GmxPositionFees, GmxPositionFundingFees, GmxExecutionPriceResult, GmxMarketPrices, GmxOrderInfo} from "../../contracts/utils/exchanges/gmx/IGmxSynthetics.sol";
import {GmxCallbackLib} from "../../contracts/protocol/libraries/GmxCallbackLib.sol";
import {GmxLib} from "../../contracts/protocol/libraries/GmxLib.sol";
import {AppTokenBalance} from "../../contracts/protocol/types/ExternalApp.sol";

/// @dev Thin harness so GmxLib internal functions can be called via external
///      calls, enabling vm.expectRevert for functions that may revert.
contract GmxLibHarness {
    function assertPositionLimitNotReached(
        address account,
        address market,
        address collateralToken,
        bool isLong
    ) external view {
        GmxLib.assertPositionLimitNotReached(account, market, collateralToken, isLong);
    }

    function isMarketActive(address account, address market) external view returns (bool) {
        return GmxLib.isMarketActive(account, market);
    }

    function hasClaimableFundingFees(address account, address market) external view returns (bool) {
        return GmxLib.hasClaimableFundingFees(account, market);
    }
}

/// @title GmxLibTest
/// @notice Non-fork unit tests for GmxLib internal functions.
/// @dev Uses vm.mockCall on the hardcoded GMX address constants to avoid
///      the forge-coverage + vm.createSelectFork incompatibility that prevents
///      fork tests from recording coverage hits.
contract GmxLibTest is Test {
    GmxLibHarness internal gmxHarness;

    function setUp() public {
        gmxHarness = new GmxLibHarness();
    }

    // =========================================================================
    // GMX hardcoded addresses (private in GmxLib; reproduced here for mocking)
    // =========================================================================
    address internal constant GMX_READER = 0x470fbC46bcC0f16532691Df360A07d8Bf5ee0789;
    address internal constant GMX_DATA_STORE = 0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8;
    address internal constant GMX_CHAINLINK_PRICE_FEED = 0x38B8dB61b724b51e42A88Cb8eC564CD685a0f53B;
    address internal constant WRAPPED_NATIVE = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    // Key hashes from GmxLib (reproduced for mock calldata construction)
    bytes32 internal constant KEY_FEE_BASE = keccak256(abi.encode("ESTIMATED_GAS_FEE_BASE_AMOUNT_V2_1"));
    bytes32 internal constant KEY_FEE_PER_ORACLE = keccak256(abi.encode("ESTIMATED_GAS_FEE_PER_ORACLE_PRICE"));
    bytes32 internal constant KEY_FEE_MULTIPLIER = keccak256(abi.encode("ESTIMATED_GAS_FEE_MULTIPLIER_FACTOR"));
    bytes32 internal constant KEY_INCREASE_ORDER_GAS = keccak256(abi.encode("INCREASE_ORDER_GAS_LIMIT"));
    bytes32 internal constant KEY_DECREASE_ORDER_GAS = keccak256(abi.encode("DECREASE_ORDER_GAS_LIMIT"));
    // Matches GmxLib._POSITION_SIZE_IN_USD_KEY
    bytes32 internal constant POSITION_SIZE_IN_USD_KEY = keccak256(abi.encode("SIZE_IN_USD"));

    // 1e30 — GmxLib._FLOAT_PRECISION
    uint256 internal constant FLOAT_PRECISION = 1e30;

    // Reused test addresses
    address internal constant POOL = address(0x1000);
    address internal constant MARKET = address(0x2000);
    address internal constant COL_TOKEN = address(0x3000);
    address internal constant INDEX_TOKEN = address(0x4000);
    address internal constant LONG_TOKEN = address(0x5000);
    address internal constant SHORT_TOKEN = address(0x6000);

    // =========================================================================
    // computeExecutionFee
    // =========================================================================

    /// @notice Increase order fee: base + 3×perOracle + adjusted order gas.
    function test_ComputeExecutionFee_Increase() public {
        uint256 orderGas = 2_000_000;
        uint256 feeBase = 100_000;
        uint256 feePerOracle = 50_000; // 3 oracle prices → 150_000
        uint256 multiplierFactor = 1_100_000_000_000_000_000_000_000_000_000; // 1.1 × 1e30

        vm.mockCall(
            GMX_DATA_STORE,
            abi.encodeWithSelector(IGmxDataStore.getUint.selector, KEY_INCREASE_ORDER_GAS),
            abi.encode(orderGas)
        );
        vm.mockCall(
            GMX_DATA_STORE,
            abi.encodeWithSelector(IGmxDataStore.getUint.selector, KEY_FEE_BASE),
            abi.encode(feeBase)
        );
        vm.mockCall(
            GMX_DATA_STORE,
            abi.encodeWithSelector(IGmxDataStore.getUint.selector, KEY_FEE_PER_ORACLE),
            abi.encode(feePerOracle)
        );
        vm.mockCall(
            GMX_DATA_STORE,
            abi.encodeWithSelector(IGmxDataStore.getUint.selector, KEY_FEE_MULTIPLIER),
            abi.encode(multiplierFactor)
        );

        vm.txGasPrice(1 gwei);
        uint256 fee = GmxLib.computeExecutionFee(true, 0);

        // baseGasLimit = 100_000 + 3×50_000 = 250_000
        // adjustedGasLimit = 250_000 + (2_000_000 × 1.1) = 250_000 + 2_200_000 = 2_450_000
        uint256 baseGasLimit = feeBase + 3 * feePerOracle;
        uint256 adjustedGasLimit = baseGasLimit + (orderGas * multiplierFactor) / FLOAT_PRECISION;
        assertEq(fee, adjustedGasLimit * 1 gwei);
    }

    /// @notice Decrease order fee uses KEY_DECREASE_ORDER_GAS.
    function test_ComputeExecutionFee_Decrease() public {
        uint256 orderGas = 1_500_000;
        uint256 feeBase = 80_000;
        uint256 feePerOracle = 40_000;
        uint256 multiplierFactor = 1e30; // 1.0× — no adjustment

        vm.mockCall(
            GMX_DATA_STORE,
            abi.encodeWithSelector(IGmxDataStore.getUint.selector, KEY_DECREASE_ORDER_GAS),
            abi.encode(orderGas)
        );
        vm.mockCall(
            GMX_DATA_STORE,
            abi.encodeWithSelector(IGmxDataStore.getUint.selector, KEY_FEE_BASE),
            abi.encode(feeBase)
        );
        vm.mockCall(
            GMX_DATA_STORE,
            abi.encodeWithSelector(IGmxDataStore.getUint.selector, KEY_FEE_PER_ORACLE),
            abi.encode(feePerOracle)
        );
        vm.mockCall(
            GMX_DATA_STORE,
            abi.encodeWithSelector(IGmxDataStore.getUint.selector, KEY_FEE_MULTIPLIER),
            abi.encode(multiplierFactor)
        );

        vm.txGasPrice(2 gwei);
        uint256 fee = GmxLib.computeExecutionFee(false, 0);

        uint256 baseGasLimit = feeBase + 3 * feePerOracle;
        uint256 adjustedGasLimit = baseGasLimit + (orderGas * multiplierFactor) / FLOAT_PRECISION;
        assertEq(fee, adjustedGasLimit * 2 gwei);
    }

    // =========================================================================
    // assertPositionLimitNotReached
    // =========================================================================

    /// @notice Fast path: DataStore returns sizeInUsd > 0 → position exists → return early.
    function test_AssertPositionLimitNotReached_FastPath_ExistingPosition() public {
        bool isLong = true;
        bytes32 positionKey = keccak256(abi.encode(POOL, MARKET, COL_TOKEN, isLong));
        bytes32 storageKey = keccak256(abi.encode(positionKey, POSITION_SIZE_IN_USD_KEY));

        vm.mockCall(
            GMX_DATA_STORE,
            abi.encodeWithSelector(IGmxDataStore.getUint.selector, storageKey),
            abi.encode(uint256(1e30)) // position has size → exists
        );

        // Should not revert. Reader should NOT be called.
        GmxLib.assertPositionLimitNotReached(POOL, MARKET, COL_TOKEN, isLong);
    }

    /// @notice Slow path: new position, count < 32 → succeeds.
    function test_AssertPositionLimitNotReached_SlowPath_BelowCap() public {
        bool isLong = true;
        bytes32 positionKey = keccak256(abi.encode(POOL, MARKET, COL_TOKEN, isLong));
        bytes32 storageKey = keccak256(abi.encode(positionKey, POSITION_SIZE_IN_USD_KEY));

        // New position — no existing size.
        vm.mockCall(
            GMX_DATA_STORE,
            abi.encodeWithSelector(IGmxDataStore.getUint.selector, storageKey),
            abi.encode(uint256(0))
        );

        // Reader returns 5 positions (< 32 → no revert).
        Position.Props[] memory positions = new Position.Props[](5);
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountPositions.selector), abi.encode(positions));

        GmxLib.assertPositionLimitNotReached(POOL, MARKET, COL_TOKEN, isLong);
    }

    /// @notice Slow path: new position, count == 32 → MaxGmxPositionsReached.
    ///         Uses harness to make an external call so vm.expectRevert works correctly.
    function test_AssertPositionLimitNotReached_SlowPath_AtCap_Reverts() public {
        bool isLong = false;
        bytes32 positionKey = keccak256(abi.encode(POOL, MARKET, COL_TOKEN, isLong));
        bytes32 storageKey = keccak256(abi.encode(positionKey, POSITION_SIZE_IN_USD_KEY));

        vm.mockCall(
            GMX_DATA_STORE,
            abi.encodeWithSelector(IGmxDataStore.getUint.selector, storageKey),
            abi.encode(uint256(0))
        );

        Position.Props[] memory positions = new Position.Props[](32);
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountPositions.selector), abi.encode(positions));

        vm.expectRevert(GmxLib.MaxGmxPositionsReached.selector);
        gmxHarness.assertPositionLimitNotReached(POOL, MARKET, COL_TOKEN, isLong);
    }

    // =========================================================================
    // getGmxPositionBalances — no positions, no orders
    // =========================================================================

    function test_GetGmxPositionBalances_Empty() public {
        _mockEmptyPositionsAndOrders();
        AppTokenBalance[] memory balances = GmxLib.getGmxPositionBalances(POOL);
        assertEq(balances.length, 0);
    }

    // =========================================================================
    // getGmxPositionBalances — pending increase orders
    // =========================================================================

    /// @notice MarketIncrease order with execution fee → 2 entries.
    function test_GetGmxPositionBalances_OnePendingMarketIncreaseOrder() public {
        Position.Props[] memory emptyPos = new Position.Props[](0);
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountPositions.selector), abi.encode(emptyPos));

        GmxOrderInfo[] memory orders = new GmxOrderInfo[](1);
        orders[0].order.numbers.orderType = Order.OrderType.MarketIncrease;
        orders[0].order.addresses.initialCollateralToken = COL_TOKEN;
        orders[0].order.numbers.initialCollateralDeltaAmount = 500e6;
        orders[0].order.numbers.executionFee = 0.001 ether;
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountOrders.selector), abi.encode(orders));

        AppTokenBalance[] memory balances = GmxLib.getGmxPositionBalances(POOL);
        assertEq(balances.length, 2);
        assertEq(balances[0].token, COL_TOKEN);
        assertEq(balances[0].amount, int256(500e6));
        assertEq(balances[1].token, WRAPPED_NATIVE);
        assertEq(balances[1].amount, int256(0.001 ether));
    }

    /// @notice LimitIncrease collateral is counted; MarketDecrease collateral is NOT
    ///  counted (it stays in the open position), but its execution fee IS counted.
    function test_GetGmxPositionBalances_LimitIncrease_And_Decrease_FeeCounted() public {
        Position.Props[] memory emptyPos = new Position.Props[](0);
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountPositions.selector), abi.encode(emptyPos));

        GmxOrderInfo[] memory orders = new GmxOrderInfo[](2);
        orders[0].order.numbers.orderType = Order.OrderType.LimitIncrease;
        orders[0].order.addresses.initialCollateralToken = COL_TOKEN;
        orders[0].order.numbers.initialCollateralDeltaAmount = 200e6;
        orders[0].order.numbers.executionFee = 0; // no fee entry

        orders[1].order.numbers.orderType = Order.OrderType.MarketDecrease;
        orders[1].order.addresses.initialCollateralToken = COL_TOKEN;
        orders[1].order.numbers.initialCollateralDeltaAmount = 999e6; // must be skipped
        orders[1].order.numbers.executionFee = 0.002 ether;

        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountOrders.selector), abi.encode(orders));

        AppTokenBalance[] memory balances = GmxLib.getGmxPositionBalances(POOL);
        // LimitIncrease collateral + MarketDecrease execution fee → 2 entries
        assertEq(balances.length, 2);
        assertEq(balances[0].token, COL_TOKEN);
        assertEq(balances[0].amount, int256(200e6));
        assertEq(balances[1].token, WRAPPED_NATIVE);
        assertEq(balances[1].amount, int256(0.002 ether));
    }

    /// @notice A pending decrease order contributes only its execution fee.
    function test_GetGmxPositionBalances_DecreaseOrder_FeeCounted() public {
        Position.Props[] memory emptyPos = new Position.Props[](0);
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountPositions.selector), abi.encode(emptyPos));

        GmxOrderInfo[] memory orders = new GmxOrderInfo[](1);
        orders[0].order.numbers.orderType = Order.OrderType.MarketDecrease;
        orders[0].order.addresses.initialCollateralToken = COL_TOKEN;
        orders[0].order.numbers.initialCollateralDeltaAmount = 500e6; // must be ignored
        orders[0].order.numbers.executionFee = 0.003 ether;

        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountOrders.selector), abi.encode(orders));

        AppTokenBalance[] memory balances = GmxLib.getGmxPositionBalances(POOL);
        assertEq(balances.length, 1);
        assertEq(balances[0].token, WRAPPED_NATIVE);
        assertEq(balances[0].amount, int256(0.003 ether));
    }

    /// @notice An increase order with zero collateral but non-zero execution fee still
    ///   contributes the fee to NAV (size-only leverage increase on existing collateral).
    function test_GetGmxPositionBalances_ZeroCollateral_FeeStillCounted() public {
        Position.Props[] memory emptyPos = new Position.Props[](0);
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountPositions.selector), abi.encode(emptyPos));

        GmxOrderInfo[] memory orders = new GmxOrderInfo[](1);
        orders[0].order.numbers.orderType = Order.OrderType.MarketIncrease;
        orders[0].order.addresses.initialCollateralToken = COL_TOKEN;
        orders[0].order.numbers.initialCollateralDeltaAmount = 0; // size-only increase
        orders[0].order.numbers.executionFee = 0.001 ether;
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountOrders.selector), abi.encode(orders));

        AppTokenBalance[] memory balances = GmxLib.getGmxPositionBalances(POOL);
        // Must return 1 entry for the execution fee only (no collateral entry).
        assertEq(balances.length, 1);
        assertEq(balances[0].token, WRAPPED_NATIVE);
        assertEq(balances[0].amount, int256(0.001 ether));
    }

    /// @notice getAccountOrders reverts → _getPendingOrderBalances returns empty.
    function test_GetGmxPositionBalances_OrdersRevert_ReturnsEmpty() public {
        Position.Props[] memory emptyPos = new Position.Props[](0);
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountPositions.selector), abi.encode(emptyPos));
        vm.mockCallRevert(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountOrders.selector),
            abi.encode("order error")
        );

        AppTokenBalance[] memory balances = GmxLib.getGmxPositionBalances(POOL);
        assertEq(balances.length, 0);
    }

    // =========================================================================
    // getGmxPositionBalances — executed positions: full PnL accounting
    // =========================================================================

    /// @notice Positive PnL → net collateral > collateral.
    function test_GetGmxPositionBalances_OnePosition_PositivePnl() public {
        _mockOnePosition(
            COL_TOKEN,
            1000e6, // collateralAmount
            100e30, // basePnlUsd +$100 in 1e30
            int256(0), // totalImpactUsd
            Price.Props({min: 1e24, max: 1e24}), // col price $1 per unit
            10e6, // totalCostAmount
            0, // claimableLong
            0 // claimableShort
        );

        GmxOrderInfo[] memory emptyOrders = new GmxOrderInfo[](0);
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountOrders.selector), abi.encode(emptyOrders));

        AppTokenBalance[] memory balances = GmxLib.getGmxPositionBalances(POOL);
        // net = 1000e6 + 100e30/1e24 + 0 - 10e6 = 1000e6 + 100e6 - 10e6 = 1090e6
        assertEq(balances.length, 1);
        assertEq(balances[0].token, COL_TOKEN);
        assertEq(balances[0].amount, int256(1090e6));
    }

    /// @notice Negative PnL capped so net is still positive.
    function test_GetGmxPositionBalances_OnePosition_NegativePnl_NetPositive() public {
        _mockOnePosition(
            COL_TOKEN,
            1000e6,
            -50e30, // -$50 PnL (50e6 USDC loss « collateral)
            int256(0),
            Price.Props({min: 1e24, max: 1e24}),
            10e6,
            0,
            0
        );

        GmxOrderInfo[] memory emptyOrders = new GmxOrderInfo[](0);
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountOrders.selector), abi.encode(emptyOrders));

        AppTokenBalance[] memory balances = GmxLib.getGmxPositionBalances(POOL);
        // net = 1000e6 - ceil(50e30/1e24) - 10e6 = 1000e6 - 50e6 - 10e6 = 940e6
        assertEq(balances.length, 1);
        assertEq(balances[0].amount, int256(940e6));
    }

    /// @notice Net collateral ≤ 0 → floored → no entry for that position.
    function test_GetGmxPositionBalances_OnePosition_NegativeNet_Floored() public {
        _mockOnePosition(
            COL_TOKEN,
            100e6,
            -200e30, // -$200 loss > collateral → net negative → floored
            int256(0),
            Price.Props({min: 1e24, max: 1e24}),
            50e6,
            0,
            0
        );

        GmxOrderInfo[] memory emptyOrders = new GmxOrderInfo[](0);
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountOrders.selector), abi.encode(emptyOrders));

        AppTokenBalance[] memory balances = GmxLib.getGmxPositionBalances(POOL);
        // net = 100e6 - 200e6 - 50e6 = -150e6 → floored → no entry
        assertEq(balances.length, 0);
    }

    /// @notice Claimable funding fees appear as separate entries.
    function test_GetGmxPositionBalances_FundingFees() public {
        _mockOnePosition(
            COL_TOKEN,
            1000e6,
            int256(0), // no PnL
            int256(0),
            Price.Props({min: 1e24, max: 1e24}),
            5e6,
            50e18, // 50 LONG_TOKEN claimable
            100e6 // 100 SHORT_TOKEN claimable
        );

        GmxOrderInfo[] memory emptyOrders = new GmxOrderInfo[](0);
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountOrders.selector), abi.encode(emptyOrders));

        AppTokenBalance[] memory balances = GmxLib.getGmxPositionBalances(POOL);
        // 3 entries: net collateral + long funding fee + short funding fee
        assertEq(balances.length, 3);
        assertEq(balances[0].token, COL_TOKEN);
        assertEq(balances[0].amount, int256(995e6)); // 1000e6 - 5e6
        assertEq(balances[1].token, LONG_TOKEN);
        assertEq(balances[1].amount, int256(50e18));
        assertEq(balances[2].token, SHORT_TOKEN);
        assertEq(balances[2].amount, int256(100e6));
    }

    /// @notice Positive price impact increases net collateral.
    function test_GetGmxPositionBalances_PositivePriceImpact() public {
        _mockOnePosition(
            COL_TOKEN,
            1000e6,
            int256(0),
            int256(50e30), // +$50 impact → +50e6 net
            Price.Props({min: 1e24, max: 1e24}),
            0,
            0,
            0
        );

        GmxOrderInfo[] memory emptyOrders = new GmxOrderInfo[](0);
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountOrders.selector), abi.encode(emptyOrders));

        AppTokenBalance[] memory balances = GmxLib.getGmxPositionBalances(POOL);
        assertEq(balances.length, 1);
        assertEq(balances[0].amount, int256(1050e6));
    }

    /// @notice Negative price impact decreases net collateral (ceiling division).
    function test_GetGmxPositionBalances_NegativePriceImpact() public {
        _mockOnePosition(
            COL_TOKEN,
            1000e6,
            int256(0),
            -int256(30e30), // -$30 impact → -30e6 net (1e24 price → 1:1)
            Price.Props({min: 1e24, max: 1e24}),
            0,
            0,
            0
        );

        GmxOrderInfo[] memory emptyOrders = new GmxOrderInfo[](0);
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountOrders.selector), abi.encode(emptyOrders));

        AppTokenBalance[] memory balances = GmxLib.getGmxPositionBalances(POOL);
        assertEq(balances.length, 1);
        assertEq(balances[0].amount, int256(970e6));
    }

    /// @notice If the Reader returns a zero collateralTokenPrice, _computeGmxNetCollateral
    ///   falls back to raw collateralAmount (no PnL/impact applied) to avoid division by zero.
    function test_GetGmxPositionBalances_ZeroCollateralPrice_FallsBackToRawCollateral() public {
        _mockOnePosition(
            COL_TOKEN,
            500e6,
            int256(200e30), // would be +200e6 at 1e24, but price is zero
            int256(50e30), // would be +50e6 at 1e24, but price is zero
            Price.Props({min: 0, max: 0}), // zeroed price — guard must fire
            0,
            0,
            0
        );

        GmxOrderInfo[] memory emptyOrders = new GmxOrderInfo[](0);
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountOrders.selector), abi.encode(emptyOrders));

        // With the zero-price guard: result = raw collateralAmount, no PnL/impact added.
        AppTokenBalance[] memory balances = GmxLib.getGmxPositionBalances(POOL);
        assertEq(balances.length, 1);
        assertEq(balances[0].amount, int256(500e6));
    }

    /// @notice _fetchPositionInfos try/catch fallback: Reader reverts → collateral-only.
    function test_GetGmxPositionBalances_PositionInfoListReverts_FallsBackToCollateralOnly() public {
        // One position in the raw list
        Position.Props[] memory positions = new Position.Props[](1);
        positions[0].addresses.collateralToken = COL_TOKEN;
        positions[0].addresses.market = MARKET;
        positions[0].numbers.collateralAmount = 777e6;
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountPositions.selector), abi.encode(positions));

        Market.Props memory mktData = _buildMarket();
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getMarket.selector), abi.encode(mktData));

        GmxValidatedPrice memory price = _defaultPrice();
        vm.mockCall(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeWithSelector(IGmxChainlinkPriceFeedProvider.getOraclePrice.selector),
            abi.encode(price)
        );

        // getAccountPositionInfoList reverts → collateral-only fallback
        vm.mockCallRevert(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountPositionInfoList.selector),
            abi.encode("oracle timeout")
        );

        GmxOrderInfo[] memory emptyOrders = new GmxOrderInfo[](0);
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountOrders.selector), abi.encode(emptyOrders));

        AppTokenBalance[] memory balances = GmxLib.getGmxPositionBalances(POOL);
        assertEq(balances.length, 1);
        assertEq(balances[0].token, COL_TOKEN);
        assertEq(balances[0].amount, int256(777e6));
    }

    /// @notice _safeGetGmxPrice catch branch: Chainlink reverts → zero price →
    ///         prices passed to getAccountPositionInfoList are zero →
    ///         that call also reverts → collateral-only fallback.
    function test_GetGmxPositionBalances_ChainlinkReverts_ZeroPrice_FallsBackToCollateralOnly() public {
        Position.Props[] memory positions = new Position.Props[](1);
        positions[0].addresses.collateralToken = COL_TOKEN;
        positions[0].addresses.market = MARKET;
        positions[0].numbers.collateralAmount = 500e6;
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountPositions.selector), abi.encode(positions));

        Market.Props memory mktData = _buildMarket();
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getMarket.selector), abi.encode(mktData));

        // Chainlink reverts → _safeGetGmxPrice returns zero Price.Props
        vm.mockCallRevert(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeWithSelector(IGmxChainlinkPriceFeedProvider.getOraclePrice.selector),
            abi.encode("chainlink down")
        );

        // With zero prices, getAccountPositionInfoList will revert
        vm.mockCallRevert(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountPositionInfoList.selector),
            abi.encode("revert with zero prices")
        );

        GmxOrderInfo[] memory emptyOrders = new GmxOrderInfo[](0);
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountOrders.selector), abi.encode(emptyOrders));

        AppTokenBalance[] memory balances = GmxLib.getGmxPositionBalances(POOL);
        assertEq(balances.length, 1);
        assertEq(balances[0].token, COL_TOKEN);
        assertEq(balances[0].amount, int256(500e6));
    }

    /// @notice _ceilDiv edge case: a == 0 → returns 0.
    ///         Covered indirectly via zero-PnL position (floor(0/price) = 0).
    function test_GetGmxPositionBalances_ZeroPnl_CeilDivZeroNumerator() public {
        _mockOnePosition(COL_TOKEN, 1000e6, int256(0), int256(0), Price.Props({min: 1e24, max: 1e24}), 0, 0, 0);

        GmxOrderInfo[] memory emptyOrders = new GmxOrderInfo[](0);
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountOrders.selector), abi.encode(emptyOrders));

        AppTokenBalance[] memory balances = GmxLib.getGmxPositionBalances(POOL);
        // net = 1000e6 + 0 + 0 - 0 = 1000e6
        assertEq(balances.length, 1);
        assertEq(balances[0].amount, int256(1000e6));
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Mocks both getAccountPositions and getAccountOrders to return empty arrays.
    function _mockEmptyPositionsAndOrders() internal {
        Position.Props[] memory emptyPos = new Position.Props[](0);
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountPositions.selector), abi.encode(emptyPos));
        GmxOrderInfo[] memory emptyOrders = new GmxOrderInfo[](0);
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountOrders.selector), abi.encode(emptyOrders));
    }

    /// @dev Mocks the full executed-position call chain for a single position.
    function _mockOnePosition(
        address colToken,
        uint256 collateralAmount,
        int256 basePnlUsd,
        int256 totalImpactUsd,
        Price.Props memory colPrice,
        uint256 totalCostAmount,
        uint256 claimableLong,
        uint256 claimableShort
    ) internal {
        // 1 – getAccountPositions
        Position.Props[] memory positions = new Position.Props[](1);
        positions[0].addresses.collateralToken = colToken;
        positions[0].addresses.market = MARKET;
        positions[0].numbers.collateralAmount = collateralAmount;
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountPositions.selector), abi.encode(positions));

        // 2 – getMarket
        Market.Props memory mktData = _buildMarket();
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getMarket.selector), abi.encode(mktData));

        // 3 – Chainlink prices (same for all tokens in this helper)
        GmxValidatedPrice memory price = _defaultPrice();
        vm.mockCall(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeWithSelector(IGmxChainlinkPriceFeedProvider.getOraclePrice.selector),
            abi.encode(price)
        );

        // 4 – getAccountPositionInfoList
        GmxPositionInfo[] memory posInfos = new GmxPositionInfo[](1);
        posInfos[0].position.addresses.collateralToken = colToken;
        posInfos[0].position.numbers.collateralAmount = collateralAmount;
        posInfos[0].basePnlUsd = basePnlUsd;
        posInfos[0].fees.collateralTokenPrice = colPrice;
        posInfos[0].fees.totalCostAmount = totalCostAmount;
        posInfos[0].executionPriceResult.totalImpactUsd = totalImpactUsd;
        posInfos[0].fees.funding.claimableLongTokenAmount = claimableLong;
        posInfos[0].fees.funding.claimableShortTokenAmount = claimableShort;
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountPositionInfoList.selector),
            abi.encode(posInfos)
        );
    }

    function _buildMarket() internal pure returns (Market.Props memory mkt) {
        mkt.marketToken = MARKET;
        mkt.indexToken = INDEX_TOKEN;
        mkt.longToken = LONG_TOKEN;
        mkt.shortToken = SHORT_TOKEN;
    }

    function _defaultPrice() internal pure returns (GmxValidatedPrice memory price) {
        price.min = 1e24;
        price.max = 1e24;
    }

    // =========================================================================
    // Deduplication of market/price reads
    // =========================================================================

    /// @notice When multiple positions share the same market, GmxLib must query
    ///  `getMarket` only once and fetch each unique token price only once.
    function test_GetGmxPositionBalances_DeduplicatesMarketAndPriceReads() public {
        // 3 positions in the same market.
        Position.Props[] memory positions = new Position.Props[](3);
        for (uint256 i; i < 3; ++i) {
            positions[i].addresses.collateralToken = COL_TOKEN;
            positions[i].addresses.market = MARKET;
        }
        positions[0].numbers.collateralAmount = 100e6;
        positions[1].numbers.collateralAmount = 200e6;
        positions[2].numbers.collateralAmount = 300e6;
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountPositions.selector), abi.encode(positions));

        Market.Props memory mktData = _buildMarket();
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getMarket.selector, GMX_DATA_STORE, MARKET),
            abi.encode(mktData)
        );

        // Mock prices per unique token.
        GmxValidatedPrice memory price = _defaultPrice();
        vm.mockCall(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeWithSelector(IGmxChainlinkPriceFeedProvider.getOraclePrice.selector, INDEX_TOKEN, ""),
            abi.encode(price)
        );
        vm.mockCall(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeWithSelector(IGmxChainlinkPriceFeedProvider.getOraclePrice.selector, LONG_TOKEN, ""),
            abi.encode(price)
        );
        vm.mockCall(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeWithSelector(IGmxChainlinkPriceFeedProvider.getOraclePrice.selector, SHORT_TOKEN, ""),
            abi.encode(price)
        );

        // Assert exactly one getMarket call and one price call per unique token.
        vm.expectCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getMarket.selector, GMX_DATA_STORE, MARKET), 1);
        vm.expectCall(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeWithSelector(IGmxChainlinkPriceFeedProvider.getOraclePrice.selector, INDEX_TOKEN, ""),
            1
        );
        vm.expectCall(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeWithSelector(IGmxChainlinkPriceFeedProvider.getOraclePrice.selector, LONG_TOKEN, ""),
            1
        );
        vm.expectCall(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeWithSelector(IGmxChainlinkPriceFeedProvider.getOraclePrice.selector, SHORT_TOKEN, ""),
            1
        );

        // Return 3 fake position infos.
        GmxPositionInfo[] memory posInfos = new GmxPositionInfo[](3);
        for (uint256 i; i < 3; ++i) {
            posInfos[i].position = positions[i];
            posInfos[i].fees.collateralTokenPrice = Price.Props({min: 1e24, max: 1e24});
        }
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountPositionInfoList.selector),
            abi.encode(posInfos)
        );

        GmxOrderInfo[] memory emptyOrders = new GmxOrderInfo[](0);
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountOrders.selector), abi.encode(emptyOrders));

        AppTokenBalance[] memory balances = GmxLib.getGmxPositionBalances(POOL);
        assertEq(balances.length, 3);
        assertEq(balances[0].amount, int256(100e6));
        assertEq(balances[1].amount, int256(200e6));
        assertEq(balances[2].amount, int256(300e6));
    }

    /// @notice When two positions are in different markets that share a token,
    ///  the shared token price is fetched only once.
    function test_GetGmxPositionBalances_DeduplicatesTokenPriceAcrossMarkets() public {
        address marketA = MARKET;
        address marketB = address(0x2100);
        address indexTokenB = address(0x7000);
        address longTokenB = address(0x8000);

        Position.Props[] memory positions = new Position.Props[](2);
        positions[0].addresses.collateralToken = COL_TOKEN;
        positions[0].addresses.market = marketA;
        positions[0].numbers.collateralAmount = 100e6;
        positions[1].addresses.collateralToken = COL_TOKEN;
        positions[1].addresses.market = marketB;
        positions[1].numbers.collateralAmount = 200e6;
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountPositions.selector), abi.encode(positions));

        Market.Props memory mktDataA = _buildMarket();
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getMarket.selector, GMX_DATA_STORE, marketA),
            abi.encode(mktDataA)
        );

        Market.Props memory mktDataB = Market.Props({
            marketToken: marketB,
            indexToken: indexTokenB,
            longToken: longTokenB,
            shortToken: SHORT_TOKEN
        });
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getMarket.selector, GMX_DATA_STORE, marketB),
            abi.encode(mktDataB)
        );

        // Mock prices for all unique tokens (SHORT_TOKEN is shared).
        GmxValidatedPrice memory price = _defaultPrice();
        vm.mockCall(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeWithSelector(IGmxChainlinkPriceFeedProvider.getOraclePrice.selector, INDEX_TOKEN, ""),
            abi.encode(price)
        );
        vm.mockCall(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeWithSelector(IGmxChainlinkPriceFeedProvider.getOraclePrice.selector, LONG_TOKEN, ""),
            abi.encode(price)
        );
        vm.mockCall(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeWithSelector(IGmxChainlinkPriceFeedProvider.getOraclePrice.selector, SHORT_TOKEN, ""),
            abi.encode(price)
        );
        vm.mockCall(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeWithSelector(IGmxChainlinkPriceFeedProvider.getOraclePrice.selector, indexTokenB, ""),
            abi.encode(price)
        );
        vm.mockCall(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeWithSelector(IGmxChainlinkPriceFeedProvider.getOraclePrice.selector, longTokenB, ""),
            abi.encode(price)
        );

        // Assert exactly one getMarket call per market and one price call per unique token.
        vm.expectCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getMarket.selector, GMX_DATA_STORE, marketA), 1);
        vm.expectCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getMarket.selector, GMX_DATA_STORE, marketB), 1);
        vm.expectCall(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeWithSelector(IGmxChainlinkPriceFeedProvider.getOraclePrice.selector, INDEX_TOKEN, ""),
            1
        );
        vm.expectCall(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeWithSelector(IGmxChainlinkPriceFeedProvider.getOraclePrice.selector, LONG_TOKEN, ""),
            1
        );
        vm.expectCall(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeWithSelector(IGmxChainlinkPriceFeedProvider.getOraclePrice.selector, SHORT_TOKEN, ""),
            1
        );
        vm.expectCall(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeWithSelector(IGmxChainlinkPriceFeedProvider.getOraclePrice.selector, indexTokenB, ""),
            1
        );
        vm.expectCall(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeWithSelector(IGmxChainlinkPriceFeedProvider.getOraclePrice.selector, longTokenB, ""),
            1
        );

        GmxPositionInfo[] memory posInfos = new GmxPositionInfo[](2);
        posInfos[0].position = positions[0];
        posInfos[0].fees.collateralTokenPrice = Price.Props({min: 1e24, max: 1e24});
        posInfos[1].position = positions[1];
        posInfos[1].fees.collateralTokenPrice = Price.Props({min: 1e24, max: 1e24});
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountPositionInfoList.selector),
            abi.encode(posInfos)
        );

        GmxOrderInfo[] memory emptyOrders = new GmxOrderInfo[](0);
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountOrders.selector), abi.encode(emptyOrders));

        AppTokenBalance[] memory balances = GmxLib.getGmxPositionBalances(POOL);
        assertEq(balances.length, 2);
        assertEq(balances[0].amount, int256(100e6));
        assertEq(balances[1].amount, int256(200e6));
    }

    // =========================================================================
    // getPnlToken
    // =========================================================================

    /// @notice Long positions settle PnL in the market's longToken.
    function test_GetPnlToken_Long_ReturnsLongToken() public {
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getMarket.selector, GMX_DATA_STORE, MARKET),
            abi.encode(_buildMarket())
        );

        assertEq(GmxLib.getPnlToken(MARKET, true), LONG_TOKEN, "long PnL token must be longToken");
    }

    /// @notice Short positions settle PnL in the market's shortToken.
    function test_GetPnlToken_Short_ReturnsShortToken() public {
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getMarket.selector, GMX_DATA_STORE, MARKET),
            abi.encode(_buildMarket())
        );

        assertEq(GmxLib.getPnlToken(MARKET, false), SHORT_TOKEN, "short PnL token must be shortToken");
    }

    /// @notice Verifies that claimable funding fees and collateral rebates recorded by
    ///  the GMX callback extension are included in the returned balances.
    function test_GetGmxPositionBalances_CallbackBalances() public {
        address market = MARKET;
        address token = COL_TOKEN;
        uint256 timeKey = 123;
        uint256 fundingAmount = 0.1 ether;
        uint256 collateralAmount = 0.2 ether;

        bytes32 collateralAmountKey = keccak256(
            abi.encode(GmxCallbackLib.CLAIMABLE_COLLATERAL_AMOUNT_KEY, market, token, timeKey, address(this))
        );
        bytes32 fundingKey = keccak256(
            abi.encode(GmxCallbackLib.CLAIMABLE_FUNDING_AMOUNT_KEY, market, token, address(this))
        );

        // Populate the callback storage in this test contract.
        GmxCallbackLib.GmxCallbackSlot storage cb = GmxCallbackLib.gmxCallbackData();
        bytes32 marketKey = bytes32(uint256(uint160(market)));
        cb.trackedMarkets.values.push(marketKey);
        cb.trackedMarkets.positions[marketKey] = 1;
        cb.claimableCollateralKeys.values.push(collateralAmountKey);
        cb.claimableCollateralKeys.positions[collateralAmountKey] = 1;
        cb.claimableCollateralInfo[collateralAmountKey] = GmxCallbackLib.ClaimableCollateralInfo({
            token: token,
            market: market,
            timeKey: timeKey
        });

        // Mock the GMX Reader/DataStore calls used by the callback-balance branch.
        // Default all DataStore reads to 0; specific keys are overridden below.
        vm.mockCall(GMX_DATA_STORE, abi.encodeWithSelector(IGmxDataStore.getUint.selector), abi.encode(uint256(0)));

        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getMarket.selector, GMX_DATA_STORE, market),
            abi.encode(Market.Props({marketToken: market, indexToken: token, longToken: token, shortToken: token}))
        );
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountPositions.selector),
            abi.encode(new Position.Props[](0))
        );
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountOrders.selector),
            abi.encode(new GmxOrderInfo[](0))
        );

        vm.mockCall(
            GMX_DATA_STORE,
            abi.encodeWithSelector(IGmxDataStore.getUint.selector, fundingKey),
            abi.encode(fundingAmount)
        );
        vm.mockCall(
            GMX_DATA_STORE,
            abi.encodeWithSelector(IGmxDataStore.getUint.selector, collateralAmountKey),
            abi.encode(collateralAmount)
        );

        AppTokenBalance[] memory balances = GmxLib.getGmxPositionBalances(address(this));
        assertEq(balances.length, 2);
        assertEq(balances[0].token, token);
        assertEq(balances[0].amount, int256(fundingAmount));
        assertEq(balances[1].token, token);
        assertEq(balances[1].amount, int256(collateralAmount));
    }

    /// @notice Open-position funding fees (from PositionInfo) and post-update claimable funding
    ///  (from DataStore) are independent values and must both be returned without double-counting.
    function test_GetGmxPositionBalances_OpenPositionAndCallbackFunding_NotDoubleCounted() public {
        uint256 positionFunding = 0.05 ether;
        uint256 dataStoreFunding = 0.07 ether;

        // Open position still accruing funding since its last update.
        _mockOnePosition(COL_TOKEN, 0, 0, 0, Price.Props({min: 1e24, max: 1e24}), 0, positionFunding, 0);

        // Same market was previously touched by a decrease/liquidation callback, so it is
        // tracked and has a separate claimable funding balance already credited in DataStore.
        GmxCallbackLib.GmxCallbackSlot storage cb = GmxCallbackLib.gmxCallbackData();
        bytes32 marketKey = bytes32(uint256(uint160(MARKET)));
        cb.trackedMarkets.values.push(marketKey);
        cb.trackedMarkets.positions[marketKey] = 1;

        bytes32 fundingKey = keccak256(
            abi.encode(GmxCallbackLib.CLAIMABLE_FUNDING_AMOUNT_KEY, MARKET, LONG_TOKEN, address(this))
        );
        vm.mockCall(
            GMX_DATA_STORE,
            abi.encodeWithSelector(IGmxDataStore.getUint.selector, fundingKey),
            abi.encode(dataStoreFunding)
        );
        vm.mockCall(GMX_DATA_STORE, abi.encodeWithSelector(IGmxDataStore.getUint.selector), abi.encode(uint256(0)));

        GmxOrderInfo[] memory emptyOrders = new GmxOrderInfo[](0);
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountOrders.selector), abi.encode(emptyOrders));

        AppTokenBalance[] memory balances = GmxLib.getGmxPositionBalances(address(this));

        assertEq(balances.length, 2);
        assertEq(balances[0].token, LONG_TOKEN);
        assertEq(balances[0].amount, int256(positionFunding));
        assertEq(balances[1].token, LONG_TOKEN);
        assertEq(balances[1].amount, int256(dataStoreFunding));
    }

    // =========================================================================
    // New view helpers: isMarketActive / hasClaimableFundingFees /
    // claimableCollateralAmount
    // =========================================================================

    function test_IsMarketActive_True() public {
        Position.Props[] memory positions = new Position.Props[](1);
        positions[0].addresses.market = MARKET;
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountPositions.selector), abi.encode(positions));

        assertTrue(gmxHarness.isMarketActive(POOL, MARKET));
    }

    function test_IsMarketActive_False() public {
        Position.Props[] memory positions = new Position.Props[](0);
        vm.mockCall(GMX_READER, abi.encodeWithSelector(IGmxReader.getAccountPositions.selector), abi.encode(positions));

        assertFalse(gmxHarness.isMarketActive(POOL, MARKET));
    }

    function test_HasClaimableFundingFees_LongToken() public {
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getMarket.selector, GMX_DATA_STORE, MARKET),
            abi.encode(_buildMarket())
        );

        bytes32 fundingKey = keccak256(
            abi.encode(GmxCallbackLib.CLAIMABLE_FUNDING_AMOUNT_KEY, MARKET, LONG_TOKEN, POOL)
        );
        vm.mockCall(GMX_DATA_STORE, abi.encodeWithSelector(IGmxDataStore.getUint.selector), abi.encode(uint256(0)));
        vm.mockCall(
            GMX_DATA_STORE,
            abi.encodeWithSelector(IGmxDataStore.getUint.selector, fundingKey),
            abi.encode(uint256(1))
        );

        assertTrue(gmxHarness.hasClaimableFundingFees(POOL, MARKET));
    }

    function test_HasClaimableFundingFees_ShortToken() public {
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getMarket.selector, GMX_DATA_STORE, MARKET),
            abi.encode(_buildMarket())
        );

        bytes32 fundingKey = keccak256(
            abi.encode(GmxCallbackLib.CLAIMABLE_FUNDING_AMOUNT_KEY, MARKET, SHORT_TOKEN, POOL)
        );
        vm.mockCall(GMX_DATA_STORE, abi.encodeWithSelector(IGmxDataStore.getUint.selector), abi.encode(uint256(0)));
        vm.mockCall(
            GMX_DATA_STORE,
            abi.encodeWithSelector(IGmxDataStore.getUint.selector, fundingKey),
            abi.encode(uint256(1))
        );

        assertTrue(gmxHarness.hasClaimableFundingFees(POOL, MARKET));
    }

    function test_HasClaimableFundingFees_None() public {
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getMarket.selector, GMX_DATA_STORE, MARKET),
            abi.encode(_buildMarket())
        );
        vm.mockCall(GMX_DATA_STORE, abi.encodeWithSelector(IGmxDataStore.getUint.selector), abi.encode(uint256(0)));

        assertFalse(gmxHarness.hasClaimableFundingFees(POOL, MARKET));
    }

    function test_ClaimableCollateralAmount_NoInfo_ReturnsZero() public view {
        bytes32 amountKey = keccak256(abi.encode("amountKey", MARKET, COL_TOKEN, uint256(1), POOL));
        assertEq(GmxLib.claimableCollateralAmount(amountKey, POOL), 0);
    }

    function test_ClaimableCollateralAmount_WithInfo_NoDelay() public {
        address market = MARKET;
        address token = COL_TOKEN;
        uint256 timeKey = 1;
        uint256 amount = 0.5 ether;

        bytes32 amountKey = keccak256(
            abi.encode(GmxCallbackLib.CLAIMABLE_COLLATERAL_AMOUNT_KEY, market, token, timeKey, address(this))
        );

        // Store metadata in this test contract.
        GmxCallbackLib.GmxCallbackSlot storage cb = GmxCallbackLib.gmxCallbackData();
        cb.claimableCollateralInfo[amountKey] = GmxCallbackLib.ClaimableCollateralInfo({
            token: token,
            market: market,
            timeKey: timeKey
        });

        // Default everything to 0, then override the specific reads needed.
        vm.mockCall(GMX_DATA_STORE, abi.encodeWithSelector(IGmxDataStore.getUint.selector), abi.encode(uint256(0)));
        vm.mockCall(
            GMX_DATA_STORE,
            abi.encodeWithSelector(IGmxDataStore.getUint.selector, amountKey),
            abi.encode(amount)
        );

        assertEq(GmxLib.claimableCollateralAmount(amountKey, address(this)), amount);
    }

    /// @notice When factor <= reduction, the final factor is clamped to 0.
    function test_ClaimableCollateralAmount_FactorNotGreaterThanReduction() public {
        address market = MARKET;
        address token = COL_TOKEN;
        uint256 timeKey = 1;
        uint256 amount = 0.5 ether;

        bytes32 amountKey = keccak256(
            abi.encode(GmxCallbackLib.CLAIMABLE_COLLATERAL_AMOUNT_KEY, market, token, timeKey, address(this))
        );
        bytes32 factorKey = keccak256(
            abi.encode(GmxCallbackLib.CLAIMABLE_COLLATERAL_FACTOR_KEY, market, token, timeKey, address(this))
        );
        bytes32 reductionKey = keccak256(
            abi.encode(GmxCallbackLib.CLAIMABLE_COLLATERAL_REDUCTION_FACTOR_KEY, market, token, timeKey, address(this))
        );

        GmxCallbackLib.GmxCallbackSlot storage cb = GmxCallbackLib.gmxCallbackData();
        cb.claimableCollateralInfo[amountKey] = GmxCallbackLib.ClaimableCollateralInfo({
            token: token,
            market: market,
            timeKey: timeKey
        });

        // factor (10) <= reduction (20) -> clamped to 0 -> claimable = 0.
        vm.mockCall(GMX_DATA_STORE, abi.encodeWithSelector(IGmxDataStore.getUint.selector), abi.encode(uint256(0)));
        vm.mockCall(
            GMX_DATA_STORE,
            abi.encodeWithSelector(IGmxDataStore.getUint.selector, amountKey),
            abi.encode(amount)
        );
        vm.mockCall(
            GMX_DATA_STORE,
            abi.encodeWithSelector(IGmxDataStore.getUint.selector, factorKey),
            abi.encode(uint256(10))
        );
        vm.mockCall(
            GMX_DATA_STORE,
            abi.encodeWithSelector(IGmxDataStore.getUint.selector, reductionKey),
            abi.encode(uint256(20))
        );

        assertEq(GmxLib.claimableCollateralAmount(amountKey, address(this)), 0);
    }

    /// @notice Callback-recorded funding fees on the short token are also returned.
    function test_GetGmxPositionBalances_CallbackBalances_ShortTokenFunding() public {
        address market = MARKET;
        address token = SHORT_TOKEN;
        uint256 fundingAmount = 0.1 ether;

        bytes32 fundingKey = keccak256(
            abi.encode(GmxCallbackLib.CLAIMABLE_FUNDING_AMOUNT_KEY, market, token, address(this))
        );

        GmxCallbackLib.GmxCallbackSlot storage cb = GmxCallbackLib.gmxCallbackData();
        bytes32 marketKey = bytes32(uint256(uint160(market)));
        cb.trackedMarkets.values.push(marketKey);
        cb.trackedMarkets.positions[marketKey] = 1;

        vm.mockCall(GMX_DATA_STORE, abi.encodeWithSelector(IGmxDataStore.getUint.selector), abi.encode(uint256(0)));
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getMarket.selector, GMX_DATA_STORE, market),
            abi.encode(
                Market.Props({marketToken: market, indexToken: INDEX_TOKEN, longToken: LONG_TOKEN, shortToken: token})
            )
        );
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountPositions.selector),
            abi.encode(new Position.Props[](0))
        );
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountOrders.selector),
            abi.encode(new GmxOrderInfo[](0))
        );
        vm.mockCall(
            GMX_DATA_STORE,
            abi.encodeWithSelector(IGmxDataStore.getUint.selector, fundingKey),
            abi.encode(fundingAmount)
        );

        AppTokenBalance[] memory balances = GmxLib.getGmxPositionBalances(address(this));
        assertEq(balances.length, 1);
        assertEq(balances[0].token, token);
        assertEq(balances[0].amount, int256(fundingAmount));
    }

    /// @notice If getMarket reverts while iterating callback-recorded markets,
    ///  the loop must continue instead of reverting.
    function test_GetGmxPositionBalances_CallbackMarketRevert_SkipsMarket() public {
        address market = MARKET;
        bytes32 marketKey = bytes32(uint256(uint160(market)));
        GmxCallbackLib.GmxCallbackSlot storage cb = GmxCallbackLib.gmxCallbackData();
        cb.trackedMarkets.values.push(marketKey);
        cb.trackedMarkets.positions[marketKey] = 1;

        vm.mockCallRevert(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getMarket.selector, GMX_DATA_STORE, market),
            abi.encode("market revert")
        );
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountPositions.selector),
            abi.encode(new Position.Props[](0))
        );
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountOrders.selector),
            abi.encode(new GmxOrderInfo[](0))
        );

        AppTokenBalance[] memory balances = GmxLib.getGmxPositionBalances(address(this));
        assertEq(balances.length, 0);
    }
}
