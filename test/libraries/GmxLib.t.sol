// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Price} from "gmx-synthetics/price/Price.sol";
import {Market} from "gmx-synthetics/market/Market.sol";
import {Position} from "gmx-synthetics/position/Position.sol";
import {Order} from "gmx-synthetics/order/Order.sol";
import {
    IGmxReader,
    IGmxDataStore,
    IGmxChainlinkPriceFeedProvider,
    GmxValidatedPrice,
    GmxPositionInfo,
    GmxPositionFees,
    GmxPositionFundingFees,
    GmxExecutionPriceResult,
    GmxMarketPrices,
    GmxOrderInfo
} from "../../contracts/utils/exchanges/gmx/IGmxSynthetics.sol";
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
    bytes32 internal constant KEY_FEE_BASE =
        keccak256(abi.encode("ESTIMATED_GAS_FEE_BASE_AMOUNT_V2_1"));
    bytes32 internal constant KEY_FEE_PER_ORACLE =
        keccak256(abi.encode("ESTIMATED_GAS_FEE_PER_ORACLE_PRICE"));
    bytes32 internal constant KEY_FEE_MULTIPLIER =
        keccak256(abi.encode("ESTIMATED_GAS_FEE_MULTIPLIER_FACTOR"));
    bytes32 internal constant KEY_INCREASE_ORDER_GAS =
        keccak256(abi.encode("INCREASE_ORDER_GAS_LIMIT"));
    bytes32 internal constant KEY_DECREASE_ORDER_GAS =
        keccak256(abi.encode("DECREASE_ORDER_GAS_LIMIT"));
    // Matches GmxLib._POSITION_SIZE_IN_USD_KEY
    bytes32 internal constant POSITION_SIZE_IN_USD_KEY =
        keccak256(abi.encode("SIZE_IN_USD"));

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
        uint256 fee = GmxLib.computeExecutionFee(true);

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
        uint256 fee = GmxLib.computeExecutionFee(false);

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
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountPositions.selector),
            abi.encode(positions)
        );

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
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountPositions.selector),
            abi.encode(positions)
        );

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
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountPositions.selector),
            abi.encode(emptyPos)
        );

        GmxOrderInfo[] memory orders = new GmxOrderInfo[](1);
        orders[0].order.numbers.orderType = Order.OrderType.MarketIncrease;
        orders[0].order.addresses.initialCollateralToken = COL_TOKEN;
        orders[0].order.numbers.initialCollateralDeltaAmount = 500e6;
        orders[0].order.numbers.executionFee = 0.001 ether;
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountOrders.selector),
            abi.encode(orders)
        );

        AppTokenBalance[] memory balances = GmxLib.getGmxPositionBalances(POOL);
        assertEq(balances.length, 2);
        assertEq(balances[0].token, COL_TOKEN);
        assertEq(balances[0].amount, int256(500e6));
        assertEq(balances[1].token, WRAPPED_NATIVE);
        assertEq(balances[1].amount, int256(0.001 ether));
    }

    /// @notice LimitIncrease counted; MarketDecrease NOT counted.
    function test_GetGmxPositionBalances_LimitIncrease_And_Decrease_OnlyIncreaseCounted()
        public
    {
        Position.Props[] memory emptyPos = new Position.Props[](0);
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountPositions.selector),
            abi.encode(emptyPos)
        );

        GmxOrderInfo[] memory orders = new GmxOrderInfo[](2);
        orders[0].order.numbers.orderType = Order.OrderType.LimitIncrease;
        orders[0].order.addresses.initialCollateralToken = COL_TOKEN;
        orders[0].order.numbers.initialCollateralDeltaAmount = 200e6;
        orders[0].order.numbers.executionFee = 0; // no fee entry

        orders[1].order.numbers.orderType = Order.OrderType.MarketDecrease;
        orders[1].order.addresses.initialCollateralToken = COL_TOKEN;
        orders[1].order.numbers.initialCollateralDeltaAmount = 999e6; // must be skipped

        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountOrders.selector),
            abi.encode(orders)
        );

        AppTokenBalance[] memory balances = GmxLib.getGmxPositionBalances(POOL);
        // Only LimitIncrease with nonzero collateral and no fee → 1 entry
        assertEq(balances.length, 1);
        assertEq(balances[0].token, COL_TOKEN);
        assertEq(balances[0].amount, int256(200e6));
    }

    /// @notice getAccountOrders reverts → _getPendingOrderBalances returns empty.
    function test_GetGmxPositionBalances_OrdersRevert_ReturnsEmpty() public {
        Position.Props[] memory emptyPos = new Position.Props[](0);
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountPositions.selector),
            abi.encode(emptyPos)
        );
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
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountOrders.selector),
            abi.encode(emptyOrders)
        );

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
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountOrders.selector),
            abi.encode(emptyOrders)
        );

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
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountOrders.selector),
            abi.encode(emptyOrders)
        );

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
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountOrders.selector),
            abi.encode(emptyOrders)
        );

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
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountOrders.selector),
            abi.encode(emptyOrders)
        );

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
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountOrders.selector),
            abi.encode(emptyOrders)
        );

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
            int256(50e30),  // would be +50e6 at 1e24, but price is zero
            Price.Props({min: 0, max: 0}), // zeroed price — guard must fire
            0,
            0,
            0
        );

        GmxOrderInfo[] memory emptyOrders = new GmxOrderInfo[](0);
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountOrders.selector),
            abi.encode(emptyOrders)
        );

        // With the zero-price guard: result = raw collateralAmount, no PnL/impact added.
        AppTokenBalance[] memory balances = GmxLib.getGmxPositionBalances(POOL);
        assertEq(balances.length, 1);
        assertEq(balances[0].amount, int256(500e6));
    }

    /// @notice _fetchPositionInfos try/catch fallback: Reader reverts → collateral-only.
    function test_GetGmxPositionBalances_PositionInfoListReverts_FallsBackToCollateralOnly()
        public
    {
        // One position in the raw list
        Position.Props[] memory positions = new Position.Props[](1);
        positions[0].addresses.collateralToken = COL_TOKEN;
        positions[0].addresses.market = MARKET;
        positions[0].numbers.collateralAmount = 777e6;
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountPositions.selector),
            abi.encode(positions)
        );

        Market.Props memory mktData = _buildMarket();
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getMarket.selector),
            abi.encode(mktData)
        );

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
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountOrders.selector),
            abi.encode(emptyOrders)
        );

        AppTokenBalance[] memory balances = GmxLib.getGmxPositionBalances(POOL);
        assertEq(balances.length, 1);
        assertEq(balances[0].token, COL_TOKEN);
        assertEq(balances[0].amount, int256(777e6));
    }

    /// @notice _safeGetGmxPrice catch branch: Chainlink reverts → zero price →
    ///         prices passed to getAccountPositionInfoList are zero →
    ///         that call also reverts → collateral-only fallback.
    function test_GetGmxPositionBalances_ChainlinkReverts_ZeroPrice_FallsBackToCollateralOnly()
        public
    {
        Position.Props[] memory positions = new Position.Props[](1);
        positions[0].addresses.collateralToken = COL_TOKEN;
        positions[0].addresses.market = MARKET;
        positions[0].numbers.collateralAmount = 500e6;
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountPositions.selector),
            abi.encode(positions)
        );

        Market.Props memory mktData = _buildMarket();
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getMarket.selector),
            abi.encode(mktData)
        );

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
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountOrders.selector),
            abi.encode(emptyOrders)
        );

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
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountOrders.selector),
            abi.encode(emptyOrders)
        );

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
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountPositions.selector),
            abi.encode(emptyPos)
        );
        GmxOrderInfo[] memory emptyOrders = new GmxOrderInfo[](0);
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountOrders.selector),
            abi.encode(emptyOrders)
        );
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
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountPositions.selector),
            abi.encode(positions)
        );

        // 2 – getMarket
        Market.Props memory mktData = _buildMarket();
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getMarket.selector),
            abi.encode(mktData)
        );

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
}
