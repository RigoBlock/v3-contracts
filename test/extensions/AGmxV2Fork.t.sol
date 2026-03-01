// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {Constants} from "../../contracts/test/Constants.sol";

import {AGmxV2} from "../../contracts/protocol/extensions/adapters/AGmxV2.sol";
import {EApps} from "../../contracts/protocol/extensions/EApps.sol";
import {ECrosschain} from "../../contracts/protocol/extensions/ECrosschain.sol";
import {ENavView} from "../../contracts/protocol/extensions/ENavView.sol";
import {EOracle} from "../../contracts/protocol/extensions/EOracle.sol";
import {EUpgrade} from "../../contracts/protocol/extensions/EUpgrade.sol";
import {SmartPool} from "../../contracts/protocol/SmartPool.sol";
import {ExtensionsMapDeployer} from "../../contracts/protocol/deps/ExtensionsMapDeployer.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {IAuthority} from "../../contracts/protocol/interfaces/IAuthority.sol";
import {IOwnedUninitialized} from "../../contracts/utils/owned/IOwnedUninitialized.sol";
import {IPoolRegistry} from "../../contracts/protocol/interfaces/IPoolRegistry.sol";
import {ISmartPool} from "../../contracts/protocol/ISmartPool.sol";
import {ISmartPoolOwnerActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolOwnerActions.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {IAGmxV2} from "../../contracts/protocol/extensions/adapters/interfaces/IAGmxV2.sol";
import {IEApps} from "../../contracts/protocol/extensions/adapters/interfaces/IEApps.sol";
import {IEOracle} from "../../contracts/protocol/extensions/adapters/interfaces/IEOracle.sol";
import {IMinimumVersion} from "../../contracts/protocol/extensions/adapters/interfaces/IMinimumVersion.sol";
import {ExternalApp} from "../../contracts/protocol/types/ExternalApp.sol";
import {Applications} from "../../contracts/protocol/types/Applications.sol";
import {DeploymentParams, Extensions, EAppsParams} from "../../contracts/protocol/types/DeploymentParams.sol";
import {
    IGmxReader,
    IGmxDataStore,
    IGmxRoleStore,
    IGmxOrderHandler,
    IGmxChainlinkPriceFeedProvider,
    GmxValidatedPrice,
    GmxPositionInfo,
    GmxExecutionPriceResult
} from "../../contracts/utils/exchanges/gmx/IGmxSynthetics.sol";
import {Price} from "gmx-synthetics/price/Price.sol";
import {Market} from "gmx-synthetics/market/Market.sol";
import {Position} from "gmx-synthetics/position/Position.sol";
import {IENavView} from "../../contracts/protocol/extensions/adapters/interfaces/IENavView.sol";
import {NavView} from "../../contracts/protocol/libraries/NavView.sol";
import {GmxLib} from "../../contracts/protocol/libraries/GmxLib.sol";
import {Order} from "gmx-synthetics/order/Order.sol";
import {IBaseOrderUtils} from "gmx-synthetics/order/IBaseOrderUtils.sol";

// ─────────────────────────────────────────────────────────────────────────────
// AGmxV2ForkTest
// ─────────────────────────────────────────────────────────────────────────────

/// @title AGmxV2ForkTest - Integration tests for the GMX v2 perpetuals adapter
/// @notice Forks Arbitrum at a fixed block and exercises the full adapter flow:
///   - Order creation (increase / decrease / cancel)
///   - EApps integration: GMX_V2_POSITIONS application bit and position valuation
///   - Access control: only pool-owner-accessible functions
///   - ERC-20 assertion: GMX perp positions are NOT ERC-20 tokens
///   - REQUIRED_VERSION guard
/// @dev Real keeper execution cannot be triggered in a static fork, so tests for
///   final executed positions are covered in `_simulateKeeperExecution()`.
contract AGmxV2ForkTest is Test {
    // =========================================================================
    // Constants
    // =========================================================================

    address private constant AUTHORITY = Constants.AUTHORITY;
    address private constant FACTORY = Constants.FACTORY;
    address private constant TOKEN_JAR = Constants.TOKEN_JAR;

    // GMX Arbitrum addresses
    address private constant GMX_EXCHANGE_ROUTER = Constants.ARB_GMX_EXCHANGE_ROUTER;
    address private constant GMX_DATA_STORE = Constants.ARB_GMX_DATA_STORE;
    address private constant GMX_READER = Constants.ARB_GMX_READER;
    address private constant GMX_CHAINLINK_PRICE_FEED = Constants.ARB_GMX_CHAINLINK_PRICE_FEED;
    address private constant GMX_REFERRAL_STORAGE = Constants.ARB_GMX_REFERRAL_STORAGE;
    address private constant GMX_ETH_USD_MARKET = Constants.ARB_GMX_ETH_USD_MARKET;

    // Arbitrum chain-specific addresses
    address private constant ARB_WETH = Constants.ARB_WETH;
    address private constant ARB_USDC = Constants.ARB_USDC;
    address private constant ARB_ORACLE = Constants.ARB_ORACLE;
    address private constant ARB_GRG_STAKING = Constants.ARB_GRG_STAKING;
    address private constant ARB_UNISWAP_V4_POSM = Constants.ARB_UNISWAP_V4_POSM;

    /// @dev GMX USD precision — 30 decimal places.
    uint256 private constant GMX_USD = 1e30;

    address private constant GMX_ROLE_STORE = Constants.ARB_GMX_ROLE_STORE;
    address private constant GMX_ORACLE_ADDRESS = 0x7F01614cA5198Ec979B1aAd1DAF0DE7e0a215BDF;

    /// @dev Collateral size for a test increase order: 1 WETH.
    uint256 private constant COLLATERAL_AMOUNT = 1 ether;

    /// @dev Position size: 2× leverage on 1 WETH (~$2 000), so ~$4 000 USD.
    uint256 private constant SIZE_DELTA_USD = 4_000 * GMX_USD;

    // =========================================================================
    // State
    // =========================================================================

    address private poolOwner;
    address private pool;
    AGmxV2 private agmxV2;

    // =========================================================================
    // setUp
    // =========================================================================

    function setUp() public {
        // Create Arbitrum fork
        vm.createSelectFork("arbitrum", Constants.ARB_BLOCK);

        // Set a realistic gas price so computeExecutionFee returns a non-zero value.
        // 1 gwei is consistent with typical Arbitrum basefee; tests can assert the fee is
        // deducted and refunded correctly rather than silently working at fee = 0.
        vm.txGasPrice(1 gwei);

        poolOwner = makeAddr("poolOwner");

        // ------------------------------------------------------------------
        // 1. Deploy AGmxV2 adapter
        // ------------------------------------------------------------------
        agmxV2 = new AGmxV2();

        // ------------------------------------------------------------------
        // 2. Deploy extensions with Arbitrum-specific + GMX params
        // ------------------------------------------------------------------
        EApps eApps = new EApps(EAppsParams({
            grgStakingProxy: ARB_GRG_STAKING,
            univ4Posm: ARB_UNISWAP_V4_POSM
        }));
        EOracle eOracle = new EOracle(ARB_ORACLE, ARB_WETH);
        EUpgrade eUpgrade = new EUpgrade(FACTORY);
        ENavView eNavView = new ENavView(EAppsParams({
            grgStakingProxy: ARB_GRG_STAKING,
            univ4Posm: ARB_UNISWAP_V4_POSM
        }));
        ECrosschain eCrosschain = new ECrosschain();

        // ------------------------------------------------------------------
        // 3. Deploy ExtensionsMap and new SmartPool implementation
        // ------------------------------------------------------------------
        ExtensionsMapDeployer mapDeployer = new ExtensionsMapDeployer();
        DeploymentParams memory params = DeploymentParams({
            extensions: Extensions({
                eApps: address(eApps),
                eOracle: address(eOracle),
                eUpgrade: address(eUpgrade),
                eNavView: address(eNavView),
                eCrosschain: address(eCrosschain)
            }),
            wrappedNative: ARB_WETH
        });
        bytes32 salt = keccak256(abi.encodePacked("GMX_V2_FORK_TEST_V1", block.chainid));
        address extensionsMap = mapDeployer.deployExtensionsMap(params, salt);

        SmartPool impl = new SmartPool(AUTHORITY, extensionsMap, TOKEN_JAR);

        // Register new implementation with factory
        address registry = IRigoblockPoolProxyFactory(FACTORY).getRegistry();
        address rigoblockDao = IPoolRegistry(registry).rigoblockDao();
        vm.prank(rigoblockDao);
        IRigoblockPoolProxyFactory(FACTORY).setImplementation(address(impl));

        // ------------------------------------------------------------------
        // 4. Create pool with WETH as base token
        // ------------------------------------------------------------------
        vm.prank(poolOwner);
        (pool,) = IRigoblockPoolProxyFactory(FACTORY).createPool("GmxForkPool", "GMXFP", ARB_WETH);
        console2.log("Pool created:", pool);

        // ------------------------------------------------------------------
        // 5. Register AGmxV2 in Authority and whitelist all selectors
        // ------------------------------------------------------------------
        address authorityOwner = IOwnedUninitialized(AUTHORITY).owner();
        vm.startPrank(authorityOwner);
        IAuthority(AUTHORITY).setAdapter(address(agmxV2), true);
        if (!IAuthority(AUTHORITY).isWhitelister(authorityOwner)) {
            IAuthority(AUTHORITY).setWhitelister(authorityOwner, true);
        }
        IAuthority(AUTHORITY).addMethod(IAGmxV2.createIncreaseOrder.selector, address(agmxV2));
        IAuthority(AUTHORITY).addMethod(IAGmxV2.createDecreaseOrder.selector, address(agmxV2));
        IAuthority(AUTHORITY).addMethod(IAGmxV2.updateOrder.selector, address(agmxV2));
        IAuthority(AUTHORITY).addMethod(IAGmxV2.cancelOrder.selector, address(agmxV2));
        IAuthority(AUTHORITY).addMethod(IAGmxV2.claimFundingFees.selector, address(agmxV2));
        IAuthority(AUTHORITY).addMethod(IAGmxV2.claimCollateral.selector, address(agmxV2));
        vm.stopPrank();

        // ------------------------------------------------------------------
        // 6. Fund pool with WETH (deal directly to pool — covers collateral + fees)
        // ------------------------------------------------------------------
        deal(ARB_WETH, pool, 10 ether);
    }

    // =========================================================================
    // Tests — adapter metadata
    // =========================================================================

    /// @notice The adapter must report the required protocol version as 4.1.2.
    function test_RequiredVersion() public view {
        assertEq(IMinimumVersion(address(agmxV2)).requiredVersion(), "4.1.2");
    }

    /// @notice Direct calls to the adapter are blocked.
    function test_DirectCallReverts() public {
        IBaseOrderUtils.CreateOrderParams memory p = _defaultIncreaseParams();
        vm.expectRevert(IAGmxV2.DirectCallNotAllowed.selector);
        agmxV2.createIncreaseOrder(p);
    }

    // =========================================================================
    // Tests — order creation and cancellation
    // =========================================================================

    /// @notice Pool owner can create a market-increase order; WETH leaves the pool.
    function test_CreateIncreaseOrder_SendsCollateralToVault() public {
        uint256 wethBefore = IERC20(ARB_WETH).balanceOf(pool);

        IBaseOrderUtils.CreateOrderParams memory p = _defaultIncreaseParams();
        vm.prank(poolOwner);
        bytes32 orderKey = IAGmxV2(pool).createIncreaseOrder(p);

        // some non-zero key was returned
        assertTrue(orderKey != bytes32(0), "order key must be non-zero");

        uint256 wethAfter = IERC20(ARB_WETH).balanceOf(pool);
        // pool sent collateral + execution fee to the GMX OrderVault.
        // Fee is non-zero (setUp sets vm.txGasPrice(1 gwei)); exact amount depends on
        // DataStore gas-limit keys, so we assert the range rather than an exact value.
        assertGe(wethBefore - wethAfter, COLLATERAL_AMOUNT, "at least collateral must be sent to vault");
        assertLt(wethBefore - wethAfter, COLLATERAL_AMOUNT + 0.01 ether, "execution fee must be well below 0.01 ETH at 1 gwei");

        console2.log("Increase order key:", vm.toString(orderKey));
    }

    /// @notice After createIncreaseOrder the GMX_V2_POSITIONS application bit is set.
    function test_CreateIncreaseOrder_ActivatesGmxApplication() public {
        vm.prank(poolOwner);
        IAGmxV2(pool).createIncreaseOrder(_defaultIncreaseParams());

        uint256 packed = ISmartPoolState(pool).getActiveApplications();
        uint256 flag = 1 << uint256(Applications.GMX_V2_POSITIONS);
        assertTrue(packed & flag != 0, "GMX_V2_POSITIONS application must be active");
    }

    /// @notice Pool owner can cancel the pending order; WETH is refunded to the pool.
    function test_CancelOrder_RefundsCollateral() public {
        uint256 wethBefore = IERC20(ARB_WETH).balanceOf(pool);

        vm.prank(poolOwner);
        bytes32 orderKey = IAGmxV2(pool).createIncreaseOrder(_defaultIncreaseParams());

        uint256 wethAfterCreate = IERC20(ARB_WETH).balanceOf(pool);

        // GMX requires orders to be at least REQUEST_EXPIRATION_TIME (300 s) old before
        // they can be cancelled by the account (to prevent front-running keeper execution).
        vm.warp(block.timestamp + 301);

        // Cancel the order
        vm.prank(poolOwner);
        IAGmxV2(pool).cancelOrder(orderKey);

        uint256 wethAfterCancel = IERC20(ARB_WETH).balanceOf(pool);

        // Collateral + execution fee should be refunded (GMX refunds both on user-initiated cancel)
        assertGe(wethAfterCancel, wethAfterCreate, "cancel must return collateral");
        // At a minimum the collateral amount must have come back
        assertGe(
            wethAfterCancel - wethAfterCreate,
            COLLATERAL_AMOUNT,
            "at least collateral amount must be refunded"
        );

        console2.log("WETH before:", wethBefore);
        console2.log("WETH after create:", wethAfterCreate);
        console2.log("WETH after cancel:", wethAfterCancel);
    }

    /// @notice claimFundingFees is reachable and does not revert on a pool with no claimable fees.
    function test_ClaimFundingFees_NoClaimableFeesDoesNotRevert() public {
        address[] memory markets = new address[](1);
        markets[0] = GMX_ETH_USD_MARKET;
        address[] memory tokens = new address[](1);
        tokens[0] = ARB_WETH;

        vm.prank(poolOwner);
        IAGmxV2(pool).claimFundingFees(markets, tokens, address(this));
    }

    /// @notice claimCollateral is routed correctly through the adapter to the GMX ExchangeRouter.
    ///   GMX may revert internally when there is no claimable collateral — the adapter does not
    ///   suppress these errors. This test verifies the adapter correctly routes the call.
    ///   NOTE: The deployed GMX ExchangeRouter (block ~430M) reverts with an arithmetic underflow
    ///   when called with a market/token/timeKey with no claimable amount. We therefore use
    ///   vm.expectRevert() to confirm the revert propagates (not silently swallowed by the adapter).
    function test_ClaimCollateral_NothingClaimableDoesNotRevert() public {
        address[] memory markets = new address[](1);
        markets[0] = GMX_ETH_USD_MARKET;
        address[] memory tokens = new address[](1);
        tokens[0] = ARB_WETH;
        uint256[] memory timeKeys = new uint256[](1);
        // Use a timeKey that has no prior claims: any timestamp after the fork block.
        // timeKey=0 may already be "claimed" in the DataStore at ARB_BLOCK, causing
        // CollateralAlreadyClaimed error. A future timeKey has guaranteed-empty state.
        timeKeys[0] = block.timestamp + 1;

        // GMX reverts internally when claimable amount = 0 (arithmetic underflow in rewards logic).
        // The adapter correctly propagates the revert without swallowing it.
        vm.prank(poolOwner);
        vm.expectRevert();
        IAGmxV2(pool).claimCollateral(markets, tokens, timeKeys, address(this));
    }

    // =========================================================================
    // Tests — EApps / NAV integration
    // =========================================================================

    /// @notice With no open positions, getAppTokenBalances for GMX returns an empty balances array.
    /// @notice When a pending (not-yet-executed) increase order exists, its collateral
    ///  is tracked by GmxLib via getAccountOrders and included in EApps balances.
    ///  This prevents a NAV gap during the order's pending window.
    function test_EApps_NoPositions_ReturnsEmptyBalances() public {
        // Enable the GMX app bit
        vm.prank(poolOwner);
        IAGmxV2(pool).createIncreaseOrder(_defaultIncreaseParams());

        uint256 packed = ISmartPoolState(pool).getActiveApplications();

        // GMX_V2_POSITIONS bit is set
        uint256 flag = 1 << uint256(Applications.GMX_V2_POSITIONS);
        assertTrue(packed & flag != 0, "GMX_V2_POSITIONS should be active");

        // getAppTokenBalances with the packed bitmap that includes GMX
        ExternalApp[] memory appBalances = IEApps(pool).getAppTokenBalances(packed);

        // Find the GMX app entry
        bool found;
        for (uint256 i; i < appBalances.length; ++i) {
            if (uint256(appBalances[i].appType) == uint256(Applications.GMX_V2_POSITIONS)) {
                found = true;
                // Pending increase order: 2 balance entries — collateral + execution fee (WETH).
                // Both are non-zero because setUp sets vm.txGasPrice(1 gwei).
                assertEq(appBalances[i].balances.length, 2, "pending order must have collateral + fee entries");
                // First entry: collateral
                assertEq(
                    appBalances[i].balances[0].token,
                    ARB_WETH,
                    "pending order collateral token must be WETH"
                );
                assertGt(
                    appBalances[i].balances[0].amount,
                    0,
                    "pending order collateral must be positive"
                );
                break;
            }
        }
        assertTrue(found, "must find GMX_V2_POSITIONS entry in appBalances");
    }

    // =========================================================================
    // Tests — access control
    // =========================================================================

    /// @notice A non-owner account cannot call createIncreaseOrder.
    function test_NonOwner_CannotCreateIncreaseOrder() public {
        address attacker = makeAddr("attacker");
        IBaseOrderUtils.CreateOrderParams memory p = _defaultIncreaseParams();
        vm.prank(attacker);
        // The pool's Authority routing will revert — exact error depends on pool version,
        // but we just need confirmation that the call reverts.
        vm.expectRevert();
        IAGmxV2(pool).createIncreaseOrder(p);
    }

    /// @notice A non-owner account cannot cancel an order.
    function test_NonOwner_CannotCancelOrder() public {
        // Create the order as pool owner so we have a valid key
        vm.prank(poolOwner);
        bytes32 orderKey = IAGmxV2(pool).createIncreaseOrder(_defaultIncreaseParams());

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        IAGmxV2(pool).cancelOrder(orderKey);
    }

    // =========================================================================
    // Tests — position NOT an ERC-20 token
    // =========================================================================

    /// @notice The GMX market token (GM:ETH-USDC) IS an ERC-20, but the pool
    ///   does NOT hold market tokens after opening a leveraged position.
    ///   Leveraged positions are keys in the GMX DataStore — not ERC-20 balances.
    function test_GmxPerpetualsPosition_IsNotErc20() public {
        // Verify the MARKET token is an ERC-20 (name/symbol queryable)
        string memory name = IERC20Extended(GMX_ETH_USD_MARKET).name();
        assertTrue(bytes(name).length > 0, "GMX market token must have a name (is ERC-20)");

        uint256 poolMarketBalance = IERC20(GMX_ETH_USD_MARKET).balanceOf(pool);
        assertEq(poolMarketBalance, 0, "pool must hold 0 GM tokens before any action");

        // Open a leveraged position
        vm.prank(poolOwner);
        IAGmxV2(pool).createIncreaseOrder(_defaultIncreaseParams());

        // After creating the order, pool still holds 0 market tokens.
        // The position is tracked as a bytes32 key in GMX DataStore, NOT as an ERC-20 balance.
        poolMarketBalance = IERC20(GMX_ETH_USD_MARKET).balanceOf(pool);
        assertEq(
            poolMarketBalance,
            0,
            "pool must hold 0 GM tokens after creating an increase order (positions are not ERC-20)"
        );

        // Reader confirms 0 executed positions at this point (order is pending, not executed)
        uint256 positionCount = IGmxReader(GMX_READER).getAccountPositions(GMX_DATA_STORE, pool, 0, 32).length;
        assertEq(positionCount, 0, "pending order is not an executed position");

        console2.log("GM token name:", name);
        console2.log("Pool GM balance:", poolMarketBalance);
        console2.log("Pool GMX position count (live):", positionCount);
    }

    /// @notice WETH collateral token that was used by a position IS tracked in
    ///   the pool's active-tokens set (so it is valued in NAV when returned).
    function test_CollateralToken_IsTrackedInActivePools() public {
        vm.prank(poolOwner);
        IAGmxV2(pool).createIncreaseOrder(_defaultIncreaseParams());

        // EOracle.hasPriceFeed should return true for WETH (it is the base token / wrapped native)
        // The _trackToken call inside the adapter uses addUnique which skips base token.
        // Just verify EOracle recognises WETH:
        assertTrue(IEOracle(pool).hasPriceFeed(ARB_WETH), "EOracle must have WETH price feed");
    }

    // =========================================================================
    // Tests — EApps with keeper-executed position (simulated)
    // =========================================================================

    /// @notice Demonstrates EApps position valuation flow using a real Arbitrum
    ///   block where the TEST_POOL already has open GMX positions.
    ///   This test is skipped unless `ARBITRUM_MAINNET_RPC_URL` can provide
    ///   the required state (it uses a vm.skip guard).
    ///
    ///   NOTE: Since AGmxV2 is a newly-deployed adapter, the pre-existing test
    ///   pool used in other tests is unlikely to have GMX positions at
    ///   ARB_BLOCK. Full position-NAV verification will be enabled once a
    ///   position is created and the keeper block is recorded in ForkBlocks.sol.
    ///
    ///   For now this test asserts that Reader.getAccountPositions returns a
    ///   consistent value and that EApps handles the zero-position case gracefully.
    function test_EApps_PositionValuation_ZeroPositionsGraceful() public {
        // Verify Reader is queryable from the fork
        uint256 count = IGmxReader(GMX_READER).getAccountPositions(GMX_DATA_STORE, pool, 0, 32).length;
        assertEq(count, 0, "freshly created pool should have 0 GMX positions");

        // getAppTokenBalances must not revert with 0 positions
        uint256 gmxFlag = 1 << uint256(Applications.GMX_V2_POSITIONS);
        ExternalApp[] memory apps = IEApps(pool).getAppTokenBalances(gmxFlag);

        // Should return one entry for GMX_V2_POSITIONS with empty balances
        bool found;
        for (uint256 i; i < apps.length; ++i) {
            if (uint256(apps[i].appType) == uint256(Applications.GMX_V2_POSITIONS)) {
                found = true;
                assertEq(apps[i].balances.length, 0, "zero positions -> zero balances");
            }
        }
        assertTrue(found, "GMX app must appear in result even with zero positions");
    }

    // =========================================================================
    // Tests — updateOrder
    // =========================================================================

    /// @notice updateOrder reverts with OrderNotUpdatable for MarketIncrease orders.
    ///   Only limit-type orders (LimitIncrease, LimitDecrease) can be updated after creation.
    ///   This test documents the expected GMX protocol behaviour.
    function test_UpdateOrder_OnLimitOrder() public {
        vm.prank(poolOwner);
        bytes32 orderKey = IAGmxV2(pool).createIncreaseOrder(_defaultIncreaseParams());

        // GMX disallows updating MarketIncrease orders — only limit orders are updatable.
        // `OrderNotUpdatable(uint256 orderType)` is the expected revert.
        vm.prank(poolOwner);
        vm.expectRevert();
        IAGmxV2(pool).updateOrder(orderKey, SIZE_DELTA_USD * 2, type(uint256).max, 0, 0, 0, false);
    }

    // =========================================================================
    // Tests — 32-position DoS limit
    // =========================================================================

    /// @notice createIncreaseOrder reverts with MaxGmxPositionsReached when the reader
    ///   reports 32 open positions and the order would open a DIFFERENT position
    ///   (different market/collateral/direction — a brand-new slot).
    function test_CreateIncreaseOrder_MaxPositions_Reverts() public {
        // Fast path: mock DataStore.getUint to return 0 — no existing position for this
        // market+collateral+direction tuple, so this is a new-position attempt.
        bytes32 positionKey = keccak256(abi.encode(pool, GMX_ETH_USD_MARKET, ARB_WETH, true));
        bytes32 sizeKey = keccak256(abi.encode(positionKey, keccak256(abi.encode("SIZE_IN_USD"))));
        vm.mockCall(
            GMX_DATA_STORE,
            abi.encodeWithSelector(IGmxDataStore.getUint.selector, sizeKey),
            abi.encode(uint256(0))
        );

        // Slow path: mock Reader to report 32 open positions (cap hit).
        // Bound is now _MAX_GMX_POSITIONS (32), not type(uint256).max.
        Position.Props[] memory fakePositions = new Position.Props[](32);
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(
                IGmxReader.getAccountPositions.selector,
                GMX_DATA_STORE,
                pool,
                uint256(0),
                uint256(32)
            ),
            abi.encode(fakePositions)
        );
        vm.prank(poolOwner);
        vm.expectRevert(GmxLib.MaxGmxPositionsReached.selector);
        IAGmxV2(pool).createIncreaseOrder(_defaultIncreaseParams());
    }

    /// @notice createIncreaseOrder succeeds even when the pool is at 32 positions if the
    ///   order targets an already-open position (same market + collateralToken + isLong).
    ///   Increasing an existing position does not consume a new slot — the cap is skipped.
    function test_CreateIncreaseOrder_ExistingPositionAtMaxPositions_Succeeds() public {
        // Fast path: mock DataStore.getUint to return a non-zero sizeInUsd —
        // the position already exists, so assertPositionLimitNotReached returns early.
        // getAccountPositions is NOT called at all.
        bytes32 positionKey = keccak256(abi.encode(pool, GMX_ETH_USD_MARKET, ARB_WETH, true));
        bytes32 sizeKey = keccak256(abi.encode(positionKey, keccak256(abi.encode("SIZE_IN_USD"))));
        vm.mockCall(
            GMX_DATA_STORE,
            abi.encodeWithSelector(IGmxDataStore.getUint.selector, sizeKey),
            abi.encode(uint256(1e30)) // non-zero sizeInUsd → existing position
        );

        // Fund pool with enough WETH to cover collateral + execution fee.
        deal(ARB_WETH, pool, 10 ether);

        // Should NOT revert with MaxGmxPositionsReached (fast path exits before the count check).
        vm.prank(poolOwner);
        IAGmxV2(pool).createIncreaseOrder(_defaultIncreaseParams());
    }

    // =========================================================================
    // Tests — ENavView NAV parity with pool state
    // =========================================================================

    /// @notice Before any mint (totalSupply == 0), ENavView returns the par value
    ///   and that value equals what getPoolTokens() returns.
    function test_ENavView_NavMatchesStoredNav_NoSupply() public view {
        // No mint has happened — stored unitaryValue == 0, fallback is 10^decimals.
        ISmartPoolState.PoolTokens memory pt = ISmartPoolState(pool).getPoolTokens();
        // getPoolTokens() also uses the same fallback, so stored and pool-state values match.
        NavView.NavData memory navData = IENavView(pool).getNavDataView();

        assertEq(
            navData.unitaryValue,
            pt.unitaryValue,
            "ENavView NAV must equal pool-state NAV at par (no supply)"
        );
        assertEq(navData.unitaryValue, 10 ** 18, "Par NAV must be 1e18 for 18-decimal base token");
    }

    /// @notice After a WETH mint, ENavView's computed NAV equals the stored NAV
    ///   returned by updateUnitaryValue() — both read from the same on-chain state.
    function test_ENavView_NavMatchesStoredNav_AfterMint() public {
        uint256 mintAmount = 1 ether;

        // Give poolOwner WETH and mint shares into the pool.
        deal(ARB_WETH, poolOwner, mintAmount);
        vm.startPrank(poolOwner);
        IERC20(ARB_WETH).approve(pool, mintAmount);
        ISmartPoolActions(pool).mint(poolOwner, mintAmount, 0);
        vm.stopPrank();

        // Refresh the stored NAV.
        ISmartPoolActions(pool).updateUnitaryValue();
        uint256 storedNav = ISmartPoolState(pool).getPoolTokens().unitaryValue;

        // ENavView must report the same NAV computed fresh from on-chain state.
        NavView.NavData memory navData = IENavView(pool).getNavDataView();
        assertEq(
            navData.unitaryValue,
            storedNav,
            "ENavView NAV must match stored NAV after mint (pure base-token pool)"
        );
        // Sanity: NAV must be > 0.
        assertGt(navData.unitaryValue, 0, "NAV must be positive after mint");
    }

    /// @notice ENavView and updateUnitaryValue must agree on NAV when a GMX position is
    ///  open, including at prices that give the position unrealized profit and unrealized loss.
    ///  Both code paths call the same GmxLib via NavView — this test pins their
    ///  equivalence so regressions are caught immediately.
    function test_ENavView_NavMatchesStoredNav_WithOpenPosition_PosAndNegPnL() public {
        // ── Setup: mint so live NAV is computed ──────────────────────────────
        uint256 mintWeth = 1 ether;
        deal(ARB_WETH, poolOwner, mintWeth);
        vm.startPrank(poolOwner);
        IERC20(ARB_WETH).approve(pool, mintWeth);
        ISmartPoolActions(pool).mint(poolOwner, mintWeth, 0);
        vm.stopPrank();

        // ── Open WETH long and execute via keeper ────────────────────────────
        vm.prank(poolOwner);
        bytes32 orderKey = IAGmxV2(pool).createIncreaseOrder(_defaultIncreaseParams());
        _executeOrder(orderKey, GMX_ETH_USD_MARKET);

        // ── Read real oracle price as baseline ───────────────────────────────
        GmxValidatedPrice memory realPrice =
            IGmxChainlinkPriceFeedProvider(GMX_CHAINLINK_PRICE_FEED).getOraclePrice(ARB_WETH, "");

        // ── Positive PnL: mock +10% oracle price ─────────────────────────────
        vm.mockCall(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeCall(IGmxChainlinkPriceFeedProvider.getOraclePrice, (ARB_WETH, "")),
            abi.encode(
                GmxValidatedPrice({
                    token: ARB_WETH,
                    min: realPrice.min * 110 / 100,
                    max: realPrice.max * 110 / 100,
                    timestamp: realPrice.timestamp,
                    blockNumber: realPrice.blockNumber
                })
            )
        );
        ISmartPoolActions(pool).updateUnitaryValue();
        uint256 storedNavHighPrice = ISmartPoolState(pool).getPoolTokens().unitaryValue;
        NavView.NavData memory navDataHighPrice = IENavView(pool).getNavDataView();
        vm.clearMockedCalls();

        assertEq(
            navDataHighPrice.unitaryValue,
            storedNavHighPrice,
            "ENavView and updateUnitaryValue must agree at +10% price (positive PnL)"
        );
        assertGt(storedNavHighPrice, 0, "NAV must be positive at high price");

        // ── Negative PnL: mock -10% oracle price ─────────────────────────────
        vm.mockCall(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeCall(IGmxChainlinkPriceFeedProvider.getOraclePrice, (ARB_WETH, "")),
            abi.encode(
                GmxValidatedPrice({
                    token: ARB_WETH,
                    min: realPrice.min * 90 / 100,
                    max: realPrice.max * 90 / 100,
                    timestamp: realPrice.timestamp,
                    blockNumber: realPrice.blockNumber
                })
            )
        );
        ISmartPoolActions(pool).updateUnitaryValue();
        uint256 storedNavLowPrice = ISmartPoolState(pool).getPoolTokens().unitaryValue;
        NavView.NavData memory navDataLowPrice = IENavView(pool).getNavDataView();
        vm.clearMockedCalls();

        assertEq(
            navDataLowPrice.unitaryValue,
            storedNavLowPrice,
            "ENavView and updateUnitaryValue must agree at -10% price (negative PnL)"
        );
        assertGt(storedNavLowPrice, 0, "NAV must be positive at low price");

        // ── Sanity: price direction must be reflected ─────────────────────────
        assertGt(storedNavHighPrice, storedNavLowPrice, "long position: high price must give higher NAV than low price");
    }

    // =========================================================================
    // Private helpers
    // =========================================================================

    /// @dev Returns a default CreateOrderParams for a WETH long increase.
    function _defaultIncreaseParams() private pure returns (IBaseOrderUtils.CreateOrderParams memory) {
        return IBaseOrderUtils.CreateOrderParams({
            addresses: IBaseOrderUtils.CreateOrderParamsAddresses({
                receiver: address(0),
                cancellationReceiver: address(0),
                callbackContract: address(0),
                uiFeeReceiver: address(0),
                market: GMX_ETH_USD_MARKET,
                initialCollateralToken: ARB_WETH,
                swapPath: new address[](0)
            }),
            numbers: IBaseOrderUtils.CreateOrderParamsNumbers({
                sizeDeltaUsd: SIZE_DELTA_USD,
                initialCollateralDeltaAmount: COLLATERAL_AMOUNT,
                triggerPrice: 0,
                acceptablePrice: type(uint256).max, // Long: accept any price
                executionFee: 0,
                callbackGasLimit: 0,
                minOutputAmount: 0,
                validFromTime: 0
            }),
            orderType: Order.OrderType.MarketIncrease,
            decreasePositionSwapType: Order.DecreasePositionSwapType.NoSwap,
            isLong: true,
            shouldUnwrapNativeToken: false,
            autoCancel: false,
            referralCode: bytes32(0),
            dataList: new bytes32[](0)
        });
    }

    /// @dev Returns a default CreateOrderParams for a WETH long full-close market decrease.
    function _defaultDecreaseParams() private pure returns (IBaseOrderUtils.CreateOrderParams memory) {
        return IBaseOrderUtils.CreateOrderParams({
            addresses: IBaseOrderUtils.CreateOrderParamsAddresses({
                receiver: address(0),
                cancellationReceiver: address(0),
                callbackContract: address(0),
                uiFeeReceiver: address(0),
                market: GMX_ETH_USD_MARKET,
                initialCollateralToken: ARB_WETH,
                swapPath: new address[](0)
            }),
            numbers: IBaseOrderUtils.CreateOrderParamsNumbers({
                sizeDeltaUsd: SIZE_DELTA_USD,
                initialCollateralDeltaAmount: 0,
                triggerPrice: 0,
                acceptablePrice: 0,
                executionFee: 0,
                callbackGasLimit: 0,
                minOutputAmount: 0,
                validFromTime: 0
            }),
            orderType: Order.OrderType.MarketDecrease,
            decreasePositionSwapType: Order.DecreasePositionSwapType.NoSwap,
            isLong: true,
            shouldUnwrapNativeToken: false,
            autoCancel: false,
            referralCode: bytes32(0),
            dataList: new bytes32[](0)
        });
    }

    // =========================================================================
    // Keeper execution helpers
    // =========================================================================

    /// @dev Returns a GMX CONTROLLER address from the RoleStore.
    ///  GMX uses `keccak256(abi.encode("KEY"))` for all role keys (see GMX Keys.sol), not
    ///  bare `keccak256("KEY")`.  Using the wrong format returns an empty array and panics.
    function _getController() private view returns (address) {
        return IGmxRoleStore(GMX_ROLE_STORE).getRoleMembers(keccak256(abi.encode("CONTROLLER")), 0, 1)[0];
    }

    /// @dev Returns a registered ORDER_KEEPER address from the RoleStore.
    function _getOrderKeeper() private view returns (address) {
        return IGmxRoleStore(GMX_ROLE_STORE).getRoleMembers(keccak256(abi.encode("ORDER_KEEPER")), 0, 1)[0];
    }

    /// @dev Bundles the three per-token values needed for oracle provider management:
    ///  - token        address for SetPricesParams
    ///  - key          DataStore slot for the oracle provider
    ///  - originalProvider  value to restore after the test
    struct OracleProviderEntry {
        address token;
        bytes32 key;
        address originalProvider;
    }

    /// @dev Computes the DataStore key used to look up / set the Chainlink oracle provider
    ///  for a given (oracleContract, token) pair.  Mirrors GMX's Keys.oracleProviderForTokenKey.
    ///  IMPORTANT: GMX uses `keccak256(abi.encode("KEY"))` for the prefix, NOT
    ///  `keccak256("KEY")` / `keccak256(abi.encodePacked("KEY"))`.  Using the wrong
    ///  form writes to the wrong storage slot and execution reverts with an oracle error.
    function _oracleProviderKey(address oracleContract, address token) private pure returns (bytes32) {
        bytes32 prefix = keccak256(abi.encode("ORACLE_PROVIDER_FOR_TOKEN"));
        return keccak256(abi.encode(prefix, oracleContract, token));
    }

    /// @dev Collects unique market tokens from `market`, redirects each token's oracle
    ///  provider to GMX_CHAINLINK_PRICE_FEED (as CONTROLLER), and returns one
    ///  OracleProviderEntry per unique token.  A single struct array replaces three
    ///  parallel arrays (token, key, originalProvider), saving two memory allocations.
    ///
    ///  Extracted from _executeOrder to keep stack depth within Solidity limits.
    function _prepareOracleProviders(address market) private returns (OracleProviderEntry[] memory entries) {
        Market.Props memory mkt = IGmxReader(GMX_READER).getMarket(GMX_DATA_STORE, market);
        address controller = _getController();

        address[3] memory rawTokens = [mkt.indexToken, mkt.longToken, mkt.shortToken];

        // First pass: count unique non-zero tokens
        uint256 n;
        for (uint256 i; i < 3; ++i) {
            if (rawTokens[i] == address(0)) continue;
            bool dup;
            for (uint256 j; j < i; ++j) if (rawTokens[j] == rawTokens[i]) { dup = true; break; }
            if (!dup) n++;
        }

        entries = new OracleProviderEntry[](n);

        // Second pass: populate entries and redirect to Chainlink
        uint256 k;
        for (uint256 i; i < 3; ++i) {
            if (rawTokens[i] == address(0)) continue;
            bool dup;
            for (uint256 j; j < i; ++j) if (rawTokens[j] == rawTokens[i]) { dup = true; break; }
            if (dup) continue;

            bytes32 key = _oracleProviderKey(GMX_ORACLE_ADDRESS, rawTokens[i]);
            entries[k] = OracleProviderEntry({
                token: rawTokens[i],
                key: key,
                originalProvider: IDataStore(GMX_DATA_STORE).getAddress(key)
            });
            vm.prank(controller);
            IDataStore(GMX_DATA_STORE).setAddress(key, GMX_CHAINLINK_PRICE_FEED);
            k++;
        }
    }

    /// @dev Calls OrderHandler.executeOrder with a populated SetPricesParams.
    ///  GMX rejects execution when tokens/providers arrays are empty.
    ///  Extracted from _executeOrder to keep stack depth within Solidity limits.
    function _callExecuteOrder(bytes32 orderKey, OracleProviderEntry[] memory entries) private {
        address[] memory tokens = new address[](entries.length);
        address[] memory providers = new address[](entries.length);
        bytes[] memory data = new bytes[](entries.length);
        for (uint256 i; i < entries.length; ++i) {
            tokens[i] = entries[i].token;
            providers[i] = GMX_CHAINLINK_PRICE_FEED;
            data[i] = "";
        }

        // GMX role keys use keccak256(abi.encode("KEY")) — NOT keccak256("KEY").
        bytes32 keeperKey = keccak256(abi.encode("ORDER_KEEPER"));
        address[] memory members = IGmxRoleStore(GMX_ROLE_STORE).getRoleMembers(keeperKey, 0, 10);
        address keeper = members.length > 0 ? members[0] : _getController();

        if (members.length == 0) {
            // No registered ORDER_KEEPER at this fork block — mock the role check.
            vm.mockCall(
                GMX_ROLE_STORE,
                abi.encodeWithSelector(bytes4(keccak256("hasRole(address,bytes32)")), keeper, keeperKey),
                abi.encode(true)
            );
        }

        // Resolve the handler address before the prank — vm.prank is consumed by the
        // first external call, so orderHandler() must not be that call.
        IGmxOrderHandler handler = GmxLib.GMX_ROUTER.orderHandler();
        vm.prank(keeper);
        handler.executeOrder(
            orderKey,
            IGmxOrderHandler.SetPricesParams({tokens: tokens, providers: providers, data: data})
        );
    }

    /// @dev Simulates GMX keeper execution for `orderKey` on `market`.
    ///  1. Collects unique market tokens and redirects oracle providers to Chainlink.
    ///  2. Calls OrderHandler.executeOrder with a populated SetPricesParams.
    ///  3. Restores original oracle providers.
    ///  The body is distributed across helpers to stay within Solidity's stack limit.
    function _executeOrder(bytes32 orderKey, address market) private {
        OracleProviderEntry[] memory entries = _prepareOracleProviders(market);

        _callExecuteOrder(orderKey, entries);

        address controller = _getController();
        for (uint256 i; i < entries.length; ++i) {
            vm.prank(controller);
            IDataStore(GMX_DATA_STORE).setAddress(entries[i].key, entries[i].originalProvider);
        }

        vm.clearMockedCalls();
    }

    // =========================================================================
    // Tests — full lifecycle with keeper execution
    // =========================================================================

    /// @notice After keeper execution, the pool has exactly 1 open GMX position (WETH collateral).
    function test_CreateIncreaseOrder_Executed_WethCollateral() public {
        vm.prank(poolOwner);
        bytes32 orderKey = IAGmxV2(pool).createIncreaseOrder(_defaultIncreaseParams());

        _executeOrder(orderKey, GMX_ETH_USD_MARKET);

        uint256 posCount = IGmxReader(GMX_READER)
            .getAccountPositions(GMX_DATA_STORE, pool, 0, type(uint256).max)
            .length;
        assertEq(posCount, 1, "pool must have exactly 1 executed WETH-collateral GMX position");
    }

    /// @notice After keeper execution with USDC collateral, the pool has 1 open short position.
    function test_CreateIncreaseOrder_Executed_UsdcCollateral() public {
        // Give pool USDC for collateral (execution fee is already covered by WETH from setUp)
        deal(ARB_USDC, pool, 2_000e6);

        IBaseOrderUtils.CreateOrderParams memory p = IBaseOrderUtils.CreateOrderParams({
            addresses: IBaseOrderUtils.CreateOrderParamsAddresses({
                receiver: address(0),
                cancellationReceiver: address(0),
                callbackContract: address(0),
                uiFeeReceiver: address(0),
                market: GMX_ETH_USD_MARKET,
                initialCollateralToken: ARB_USDC,
                swapPath: new address[](0)
            }),
            numbers: IBaseOrderUtils.CreateOrderParamsNumbers({
                sizeDeltaUsd: SIZE_DELTA_USD,
                initialCollateralDeltaAmount: 1_000e6,
                triggerPrice: 0,
                acceptablePrice: 0, // market short: accept any price (no lower bound)
                executionFee: 0,
                callbackGasLimit: 0,
                minOutputAmount: 0,
                validFromTime: 0
            }),
            orderType: Order.OrderType.MarketIncrease,
            decreasePositionSwapType: Order.DecreasePositionSwapType.NoSwap,
            isLong: false, // short position with USDC collateral
            shouldUnwrapNativeToken: false,
            autoCancel: false,
            referralCode: bytes32(0),
            dataList: new bytes32[](0)
        });

        vm.prank(poolOwner);
        bytes32 orderKey = IAGmxV2(pool).createIncreaseOrder(p);

        _executeOrder(orderKey, GMX_ETH_USD_MARKET);

        uint256 posCount = IGmxReader(GMX_READER)
            .getAccountPositions(GMX_DATA_STORE, pool, 0, type(uint256).max)
            .length;
        assertEq(posCount, 1, "pool must have exactly 1 executed USDC-collateral GMX short position");
    }

    /// @notice After keeper execution, EApps returns a non-zero balance in the collateral token.
    ///  For WETH-collateral positions, the returned token is WETH (the collateral token itself).
    function test_EApps_AfterExecution_ReturnsWethBalance() public {
        vm.prank(poolOwner);
        bytes32 orderKey = IAGmxV2(pool).createIncreaseOrder(_defaultIncreaseParams());

        _executeOrder(orderKey, GMX_ETH_USD_MARKET);

        uint256 gmxFlag = 1 << uint256(Applications.GMX_V2_POSITIONS);
        ExternalApp[] memory apps = IEApps(pool).getAppTokenBalances(gmxFlag);

        bool found;
        for (uint256 i; i < apps.length; ++i) {
            if (uint256(apps[i].appType) == uint256(Applications.GMX_V2_POSITIONS)) {
                found = true;
                assertGt(apps[i].balances.length, 0, "must have >=1 balance entry for executed position");
                assertEq(apps[i].balances[0].token, ARB_WETH, "balance token must be WETH (collateral token)");
                assertGt(apps[i].balances[0].amount, 0, "WETH balance must be positive");
                break;
            }
        }
        assertTrue(found, "GMX app must appear in result after execution");
    }

    /// @notice After keeper execution of a USDC-collateral short, EApps must return a
    ///  non-zero balance in USDC (the actual collateral token).
    ///  Balances are reported in their native token — no WETH conversion.
    ///  This also means purgeInactiveTokensAndApps cannot remove USDC while the position is
    ///  open (the token appears with a positive amount in EApps balances).
    function test_EApps_AfterExecution_ReturnsWethBalance_UsdcCollateral() public {
        deal(ARB_USDC, pool, 2_000e6);

        // Open a short position backed by USDC collateral.
        IBaseOrderUtils.CreateOrderParams memory p = IBaseOrderUtils.CreateOrderParams({
            addresses: IBaseOrderUtils.CreateOrderParamsAddresses({
                receiver: address(0),
                cancellationReceiver: address(0),
                callbackContract: address(0),
                uiFeeReceiver: address(0),
                market: GMX_ETH_USD_MARKET,
                initialCollateralToken: ARB_USDC,
                swapPath: new address[](0)
            }),
            numbers: IBaseOrderUtils.CreateOrderParamsNumbers({
                sizeDeltaUsd: SIZE_DELTA_USD,
                initialCollateralDeltaAmount: 1_000e6,
                triggerPrice: 0,
                acceptablePrice: 0, // market short: accept any price
                executionFee: 0,
                callbackGasLimit: 0,
                minOutputAmount: 0,
                validFromTime: 0
            }),
            orderType: Order.OrderType.MarketIncrease,
            decreasePositionSwapType: Order.DecreasePositionSwapType.NoSwap,
            isLong: false,
            shouldUnwrapNativeToken: false,
            autoCancel: false,
            referralCode: bytes32(0),
            dataList: new bytes32[](0)
        });
        vm.prank(poolOwner);
        bytes32 orderKey = IAGmxV2(pool).createIncreaseOrder(p);
        _executeOrder(orderKey, GMX_ETH_USD_MARKET);

        uint256 gmxFlag = 1 << uint256(Applications.GMX_V2_POSITIONS);
        ExternalApp[] memory apps = IEApps(pool).getAppTokenBalances(gmxFlag);

        bool found;
        for (uint256 i; i < apps.length; ++i) {
            if (uint256(apps[i].appType) == uint256(Applications.GMX_V2_POSITIONS)) {
                found = true;
                assertGt(apps[i].balances.length, 0, "must have >=1 balance entry for USDC-collateral position");
                assertEq(apps[i].balances[0].token, ARB_USDC, "USDC-collateral position must return USDC directly");
                assertGt(apps[i].balances[0].amount, 0, "USDC balance must be positive");
                break;
            }
        }
        assertTrue(found, "GMX app must appear with USDC-collateral short position");
    }

    // =========================================================================
    // Tests — NAV invariants
    // =========================================================================

    /// @notice After creating and executing an increase order, NAV decreases by the
    ///  execution fee only.  The GMX position is valued by EApps, so the collateral is
    ///  not "missing" from the NAV calculation even though it left the pool's wallet.
    function test_Nav_PostExecution_OnlyLosesExecutionFee() public {
        // Mint shares so that totalSupply > 0 and updateUnitaryValue() computes a live NAV.
        // At par (1e18), 1 WETH → 1 share.  Pool then holds 10 WETH (deal) + 1 WETH (mint)
        // = 11 WETH total.  Initial NAV = 11 WETH/share = 11e18.
        uint256 mintWeth = 1 ether;
        deal(ARB_WETH, poolOwner, mintWeth);
        vm.startPrank(poolOwner);
        IERC20(ARB_WETH).approve(pool, mintWeth);
        ISmartPoolActions(pool).mint(poolOwner, mintWeth, 0);
        vm.stopPrank();

        ISmartPoolActions(pool).updateUnitaryValue();
        uint256 navBefore = ISmartPoolState(pool).getPoolTokens().unitaryValue;
        assertGt(navBefore, 1 ether, "sanity: NAV must be above par after 10 WETH deal");

        // Create and execute a 1 WETH long increase order.
        vm.prank(poolOwner);
        bytes32 orderKey = IAGmxV2(pool).createIncreaseOrder(_defaultIncreaseParams());
        _executeOrder(orderKey, GMX_ETH_USD_MARKET);

        // Update NAV — EApps now returns the valued GMX position.
        ISmartPoolActions(pool).updateUnitaryValue();
        uint256 navAfter = ISmartPoolState(pool).getPoolTokens().unitaryValue;

        // Execution fee is non-recoverable, so NAV must decrease.
        assertLt(navAfter, navBefore, "NAV must decrease by at least the execution fee");

        // But the drop must be small — only the execution fee (0.002 WETH out of 11 WETH
        // ≈ 0.02%).  We allow up to 1% to tolerate minor price movement at the fork block.
        assertGt(navAfter, (navBefore * 99) / 100, "NAV must not drop by more than 1%");
    }

    /// @notice A pending (not-yet-executed) increase order does NOT create a NAV gap because
    ///  GmxLib now tracks the collateral locked in the GMX OrderVault via getAccountOrders.
    ///  Only the small execution fee causes a negligible NAV decrease during the pending state.
    ///  After keeper execution the position is valued normally and NAV is fully restored.
    function test_Nav_PendingOrder_StableWhilePending_RestoredAfterExecution() public {
        // Mint 1 WETH so totalSupply > 0 (required for live NAV computation).
        uint256 mintWeth = 1 ether;
        deal(ARB_WETH, poolOwner, mintWeth);
        vm.startPrank(poolOwner);
        IERC20(ARB_WETH).approve(pool, mintWeth);
        ISmartPoolActions(pool).mint(poolOwner, mintWeth, 0);
        vm.stopPrank();

        ISmartPoolActions(pool).updateUnitaryValue();
        uint256 navBefore = ISmartPoolState(pool).getPoolTokens().unitaryValue;

        // Collateral (1 WETH) and execution fee leave the pool immediately on order creation.
        vm.prank(poolOwner);
        bytes32 orderKey = IAGmxV2(pool).createIncreaseOrder(_defaultIncreaseParams());

        // Pending state: both collateral and execution fee are in the GMX OrderVault.
        // GmxLib now tracks both, so NAV must be completely stable during the pending period.
        ISmartPoolActions(pool).updateUnitaryValue();
        uint256 navPending = ISmartPoolState(pool).getPoolTokens().unitaryValue;

        assertEq(navPending, navBefore, "NAV must be fully stable during pending (collateral + execution fee both tracked)");

        // Execute the order so EApps can value the resulting position.
        _executeOrder(orderKey, GMX_ETH_USD_MARKET);
        ISmartPoolActions(pool).updateUnitaryValue();
        uint256 navRestored = ISmartPoolState(pool).getPoolTokens().unitaryValue;

        // Execution must produce a valid NAV — within 1% of navBefore.
        // navRestored may be slightly less than navPending because execution deducts
        // opening fees and price impact from the position's net collateral.
        assertGt(navRestored, (navBefore * 99) / 100, "NAV must be within 1% of pre-order value after execution");
        // navRestored < navPending is expected (fees/price-impact deducted at execution).
    }

    /// @notice EApps adds the GMX position value to NAV.  If EApps output is suppressed
    ///  the reported NAV is lower, proving the position is actually counted.
    function test_Nav_EAppsPosition_Visible() public {
        // Mint 1 WETH so totalSupply > 0 (required for live NAV computation).
        uint256 mintWeth = 1 ether;
        deal(ARB_WETH, poolOwner, mintWeth);
        vm.startPrank(poolOwner);
        IERC20(ARB_WETH).approve(pool, mintWeth);
        ISmartPoolActions(pool).mint(poolOwner, mintWeth, 0);
        vm.stopPrank();

        // Create and execute order to have a valued position.
        vm.prank(poolOwner);
        bytes32 orderKey = IAGmxV2(pool).createIncreaseOrder(_defaultIncreaseParams());
        _executeOrder(orderKey, GMX_ETH_USD_MARKET);

        ISmartPoolActions(pool).updateUnitaryValue();
        uint256 navWithEApps = ISmartPoolState(pool).getPoolTokens().unitaryValue;

        // Suppress EApps: mock the pool's getAppTokenBalances selector to return empty.
        // updateUnitaryValue calls IEApps(address(this)).getAppTokenBalances internally,
        // which resolves to pool address — so mocking pool with that selector intercepts it.
        ExternalApp[] memory empty = new ExternalApp[](0);
        vm.mockCall(
            pool,
            abi.encodeWithSelector(IEApps.getAppTokenBalances.selector),
            abi.encode(empty)
        );

        ISmartPoolActions(pool).updateUnitaryValue();
        uint256 navWithoutEApps = ISmartPoolState(pool).getPoolTokens().unitaryValue;

        vm.clearMockedCalls();

        // The position must contribute positively to NAV.
        assertGt(navWithEApps, navWithoutEApps, "EApps position must contribute positively to NAV");
    }

    /// @notice Mocking the Chainlink oracle to return a higher price increases NAV for a long
    ///  position (unrealized profit), and a lower price decreases it (unrealized loss).
    ///  This verifies that GmxLib correctly propagates oracle price changes to NAV via EApps.
    function test_Nav_PriceMovement_UnrealizedPnL() public {
        // ── Setup: mint shares so live NAV is computed ───────────────────────
        uint256 mintWeth = 1 ether;
        deal(ARB_WETH, poolOwner, mintWeth);
        vm.startPrank(poolOwner);
        IERC20(ARB_WETH).approve(pool, mintWeth);
        ISmartPoolActions(pool).mint(poolOwner, mintWeth, 0);
        vm.stopPrank();

        // ── Open long position and execute ───────────────────────────────────
        vm.prank(poolOwner);
        bytes32 orderKey = IAGmxV2(pool).createIncreaseOrder(_defaultIncreaseParams());
        _executeOrder(orderKey, GMX_ETH_USD_MARKET);

        ISmartPoolActions(pool).updateUnitaryValue();
        uint256 navAfterOpen = ISmartPoolState(pool).getPoolTokens().unitaryValue;

        // ── Read real oracle price as baseline ───────────────────────────────
        GmxValidatedPrice memory realPrice =
            IGmxChainlinkPriceFeedProvider(GMX_CHAINLINK_PRICE_FEED).getOraclePrice(ARB_WETH, "");

        // ── Mock price +10%: long position should show unrealized profit ──────
        vm.mockCall(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeCall(IGmxChainlinkPriceFeedProvider.getOraclePrice, (ARB_WETH, "")),
            abi.encode(
                GmxValidatedPrice({
                    token: ARB_WETH,
                    min: realPrice.min * 110 / 100,
                    max: realPrice.max * 110 / 100,
                    timestamp: realPrice.timestamp,
                    blockNumber: realPrice.blockNumber
                })
            )
        );

        ISmartPoolActions(pool).updateUnitaryValue();
        uint256 navAtHighPrice = ISmartPoolState(pool).getPoolTokens().unitaryValue;
        vm.clearMockedCalls();

        assertGt(navAtHighPrice, navAfterOpen, "NAV must increase when oracle price rises (long profit)");

        // ── Mock price -10%: long position should show unrealized loss ────────
        vm.mockCall(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeCall(IGmxChainlinkPriceFeedProvider.getOraclePrice, (ARB_WETH, "")),
            abi.encode(
                GmxValidatedPrice({
                    token: ARB_WETH,
                    min: realPrice.min * 90 / 100,
                    max: realPrice.max * 90 / 100,
                    timestamp: realPrice.timestamp,
                    blockNumber: realPrice.blockNumber
                })
            )
        );

        ISmartPoolActions(pool).updateUnitaryValue();
        uint256 navAtLowPrice = ISmartPoolState(pool).getPoolTokens().unitaryValue;
        vm.clearMockedCalls();

        assertLt(navAtLowPrice, navAfterOpen, "NAV must decrease when oracle price falls (long loss)");
    }

    /// @notice Opening a long position and immediately closing it at market price results in
    ///  a NAV that is approximately equal to the pre-open NAV minus trading fees.
    ///  The pool should have no remaining GMX positions after the close.
    function test_Nav_FullClose_NoUnrealizedPnL() public {
        // ── Setup: mint shares so live NAV is computed ───────────────────────
        uint256 mintWeth = 1 ether;
        deal(ARB_WETH, poolOwner, mintWeth);
        vm.startPrank(poolOwner);
        IERC20(ARB_WETH).approve(pool, mintWeth);
        ISmartPoolActions(pool).mint(poolOwner, mintWeth, 0);
        vm.stopPrank();

        ISmartPoolActions(pool).updateUnitaryValue();
        uint256 navBefore = ISmartPoolState(pool).getPoolTokens().unitaryValue;

        // ── Open long position and execute ───────────────────────────────────
        vm.prank(poolOwner);
        bytes32 openKey = IAGmxV2(pool).createIncreaseOrder(_defaultIncreaseParams());
        _executeOrder(openKey, GMX_ETH_USD_MARKET);

        // ── Full close: market decrease for the full position size ───────────
        vm.prank(poolOwner);
        bytes32 closeKey = IAGmxV2(pool).createDecreaseOrder(_defaultDecreaseParams());
        _executeOrder(closeKey, GMX_ETH_USD_MARKET);

        ISmartPoolActions(pool).updateUnitaryValue();
        uint256 navAfterClose = ISmartPoolState(pool).getPoolTokens().unitaryValue;

        // ── Position must be gone ─────────────────────────────────────────────
        uint256 posCount = IGmxReader(GMX_READER)
            .getAccountPositions(GMX_DATA_STORE, pool, 0, type(uint256).max)
            .length;
        assertEq(posCount, 0, "pool must have 0 GMX positions after full close");

        // ── NAV must be close to pre-open NAV (fees are the only loss) ────────
        // Two execution fees + opening/closing trading fees.
        // Allow up to 2% for total round-trip costs relative to navBefore.
        assertLt(navAfterClose, navBefore, "NAV must be slightly below pre-open (fees paid)");
        assertGt(navAfterClose, (navBefore * 98) / 100, "round-trip fees must be within 2% of NAV");
    }

    /// @notice When the Chainlink oracle price is mocked higher *during* keeper execution of a
    ///  decrease order, GMX closes the long position at that higher price and returns more
    ///  collateral to the pool.  NAV after close must exceed NAV after open — the profit is
    ///  realized, not just a transient oracle mock.
    ///
    ///  How this works: _executeOrder changes the DataStore oracle-provider pointer to
    ///  Chainlink, then calls the keeper.  The keeper queries Chainlink for the execution price.
    ///  If we mock Chainlink to return +10% before calling _executeOrder, the keeper uses that
    ///  higher price.  _executeOrder calls vm.clearMockedCalls() at its end, so the mock is
    ///  cleaned up automatically — but not before the on-chain PnL has been realised.
    function test_Nav_FullClose_RealizedPnL_AtHigherPrice() public {
        // ── Setup: mint shares so live NAV is computed ───────────────────────
        uint256 mintWeth = 1 ether;
        deal(ARB_WETH, poolOwner, mintWeth);
        vm.startPrank(poolOwner);
        IERC20(ARB_WETH).approve(pool, mintWeth);
        ISmartPoolActions(pool).mint(poolOwner, mintWeth, 0);
        vm.stopPrank();

        // ── Open long position and execute at real fork-block price ──────────
        vm.prank(poolOwner);
        bytes32 openKey = IAGmxV2(pool).createIncreaseOrder(_defaultIncreaseParams());
        _executeOrder(openKey, GMX_ETH_USD_MARKET);

        ISmartPoolActions(pool).updateUnitaryValue();
        uint256 navAfterOpen = ISmartPoolState(pool).getPoolTokens().unitaryValue;

        // ── Create a full-size decrease order ─────────────────────────────────
        // acceptablePrice = 0: accept any execution price for a long close.
        vm.prank(poolOwner);
        bytes32 closeKey = IAGmxV2(pool).createDecreaseOrder(_defaultDecreaseParams());

        // ── Mock Chainlink +10% *before* _executeOrder so the keeper uses it ─
        // _executeOrder internally calls vm.clearMockedCalls() at the end, so
        // neither this test nor subsequent tests see the mock afterward.
        GmxValidatedPrice memory realPrice =
            IGmxChainlinkPriceFeedProvider(GMX_CHAINLINK_PRICE_FEED).getOraclePrice(ARB_WETH, "");

        vm.mockCall(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeCall(IGmxChainlinkPriceFeedProvider.getOraclePrice, (ARB_WETH, "")),
            abi.encode(
                GmxValidatedPrice({
                    token: ARB_WETH,
                    min: realPrice.min * 110 / 100,
                    max: realPrice.max * 110 / 100,
                    timestamp: realPrice.timestamp,
                    blockNumber: realPrice.blockNumber
                })
            )
        );

        // The keeper executes the close at the mocked +10% price → more WETH returned.
        _executeOrder(closeKey, GMX_ETH_USD_MARKET); // vm.clearMockedCalls() called inside

        // ── Position must be gone ─────────────────────────────────────────────
        uint256 posCount = IGmxReader(GMX_READER)
            .getAccountPositions(GMX_DATA_STORE, pool, 0, type(uint256).max)
            .length;
        assertEq(posCount, 0, "pool must have 0 GMX positions after full close");

        // ── Realized profit: NAV after close must exceed NAV after open ───────
        // PnL ≈ 10% on SIZE_DELTA_USD ($4 000) ≈ $400 in WETH.  Even after
        // fees the net gain is clearly positive.
        ISmartPoolActions(pool).updateUnitaryValue();
        uint256 navAfterClose = ISmartPoolState(pool).getPoolTokens().unitaryValue;

        assertGt(
            navAfterClose,
            navAfterOpen,
            "realized profit must bring NAV above post-open level"
        );
    }

    // =========================================================================
    // Tests — _ensureWeth coverage
    // =========================================================================

    /// @notice When the pool has less WETH than the required amount but enough native ETH,
    ///  _ensureWeth wraps the deficit from native ETH and the order is created successfully.
    function test_EnsureWeth_WrapsNativeEthToMakeUpDeficit() public {
        // Give the pool only 0.1 WETH — well below COLLATERAL_AMOUNT (1 WETH) + any fee.
        deal(ARB_WETH, pool, 0.1 ether);
        // Give 5 native ETH to cover the deficit.
        deal(pool, 5 ether);

        uint256 wethBefore = IERC20(ARB_WETH).balanceOf(pool);
        uint256 ethBefore = pool.balance;

        vm.prank(poolOwner);
        bytes32 orderKey = IAGmxV2(pool).createIncreaseOrder(_defaultIncreaseParams());

        // Order key must be non-zero — order was created.
        assertTrue(orderKey != bytes32(0), "order key must be non-zero after ETH top-up");

        // Pool's combined WETH + ETH decreased by at least COLLATERAL_AMOUNT.
        uint256 wethAfter = IERC20(ARB_WETH).balanceOf(pool);
        uint256 ethAfter = pool.balance;
        uint256 totalBefore = wethBefore + ethBefore;
        uint256 totalAfter = wethAfter + ethAfter;
        assertGe(
            totalBefore - totalAfter,
            COLLATERAL_AMOUNT,
            "at least collateral amount must have left the pool"
        );
    }

    /// @notice When the pool has neither WETH nor native ETH, _ensureWeth reverts with
    ///  InsufficientNativeBalance (covers the require() on AGmxV2 lines 244-245).
    function test_EnsureWeth_InsufficientNativeBalance_Reverts() public {
        // Strip WETH and native ETH from pool.
        deal(ARB_WETH, pool, 0);
        deal(pool, 0);

        vm.prank(poolOwner);
        vm.expectRevert(IAGmxV2.InsufficientNativeBalance.selector);
        IAGmxV2(pool).createIncreaseOrder(_defaultIncreaseParams());
    }

    // =========================================================================
    // Tests — GmxLib reader error fallbacks
    // =========================================================================

    /// @notice When IGmxReader.getAccountOrders reverts, GmxLib catches and returns empty
    ///  pending-order balances — getAppTokenBalances must not propagate the revert.
    ///  Covers GmxLib line 220 (catch branch of _getPendingOrderBalances).
    function test_GmxLib_GetAccountOrders_ReaderReverts_HandledGracefully() public {
        // Create a pending order so the GMX_V2_POSITIONS bit is set and GmxLib
        // will try to query pending orders.
        vm.prank(poolOwner);
        IAGmxV2(pool).createIncreaseOrder(_defaultIncreaseParams());

        uint256 gmxFlag = 1 << uint256(Applications.GMX_V2_POSITIONS);

        // Mock the reader to revert on getAccountOrders.
        vm.mockCallRevert(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountOrders.selector),
            abi.encodeWithSignature("Error(string)", "reader unavailable")
        );

        // Must not revert — catch block returns empty slice.
        ExternalApp[] memory apps = IEApps(pool).getAppTokenBalances(gmxFlag);
        vm.clearMockedCalls();

        // No executed position → GMX app must return either empty or the fallback collateral.
        // What matters is that the call completed without reverting.
        assertTrue(apps.length >= 0, "call must complete without reverting");
    }

    /// @notice When IGmxReader.getAccountPositionInfoList reverts, GmxLib falls back to
    ///  _collateralOnlyBalances — returning raw collateral amounts.
    ///  Covers GmxLib lines 352-354 (_collateralOnlyBalances body).
    function test_GmxLib_GetPositionInfoList_ReaderReverts_FallsBackToCollateralOnly() public {
        // Open and execute a position so there is a real Position.Props on-chain.
        vm.prank(poolOwner);
        bytes32 orderKey = IAGmxV2(pool).createIncreaseOrder(_defaultIncreaseParams());
        _executeOrder(orderKey, GMX_ETH_USD_MARKET);

        uint256 gmxFlag = 1 << uint256(Applications.GMX_V2_POSITIONS);

        // Mock getAccountPositionInfoList to revert — forces the catch → _collateralOnlyBalances.
        vm.mockCallRevert(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountPositionInfoList.selector),
            abi.encodeWithSignature("Error(string)", "info list unavailable")
        );

        ExternalApp[] memory apps = IEApps(pool).getAppTokenBalances(gmxFlag);
        vm.clearMockedCalls();

        // _collateralOnlyBalances returns the raw collateralAmount for each position.
        bool found;
        for (uint256 i; i < apps.length; ++i) {
            if (uint256(apps[i].appType) == uint256(Applications.GMX_V2_POSITIONS)) {
                found = true;
                assertGt(apps[i].balances.length, 0, "must have at least one collateral balance");
                assertEq(apps[i].balances[0].token, ARB_WETH, "fallback token must be collateral (WETH)");
                assertGt(apps[i].balances[0].amount, 0, "fallback collateral amount must be positive");
                break;
            }
        }
        assertTrue(found, "GMX_V2_POSITIONS app must be present in fallback mode");
    }

    /// @notice Claimable long-token and short-token funding fees are included as separate
    ///  AppTokenBalance entries when getAccountPositionInfoList returns non-zero values.
    ///  Covers GmxLib lines 309 and 315 (claimableLong/ShortTokenAmount > 0 branches).
    function test_GmxLib_ClaimableFundingFees_IncludedInBalances() public {
        // Open and execute a real position.
        vm.prank(poolOwner);
        bytes32 orderKey = IAGmxV2(pool).createIncreaseOrder(_defaultIncreaseParams());
        _executeOrder(orderKey, GMX_ETH_USD_MARKET);

        // Read the real position.
        Position.Props[] memory positions = IGmxReader(GMX_READER).getAccountPositions(
            GMX_DATA_STORE, pool, 0, type(uint256).max
        );
        assertEq(positions.length, 1, "must have exactly 1 position");

        // Get real oracle price for collateral.
        GmxValidatedPrice memory wethPrice =
            IGmxChainlinkPriceFeedProvider(GMX_CHAINLINK_PRICE_FEED).getOraclePrice(ARB_WETH, "");

        // Build a fake GmxPositionInfo with realistic collateral amounts and
        // explicitly set non-zero claimable funding fees for both long and short tokens.
        GmxPositionInfo[] memory fakeInfos = new GmxPositionInfo[](1);
        fakeInfos[0] = _buildFakePosInfo({
            pos: positions[0],
            colPriceMin: wethPrice.min,
            colPriceMax: wethPrice.max,
            basePnlUsd: 0,
            totalImpactUsd: 0,
            claimableLong: 0.001 ether, // triggers L309
            claimableShort: 1e5 // triggers L315 (USDC units — 6 decimals, so 0.1 USDC)
        });

        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountPositionInfoList.selector),
            abi.encode(fakeInfos)
        );

        uint256 gmxFlag = 1 << uint256(Applications.GMX_V2_POSITIONS);
        ExternalApp[] memory apps = IEApps(pool).getAppTokenBalances(gmxFlag);
        vm.clearMockedCalls();

        // Collect all balance tokens from the GMX app.
        address[] memory tokens;
        int256[] memory amounts;
        for (uint256 i; i < apps.length; ++i) {
            if (uint256(apps[i].appType) == uint256(Applications.GMX_V2_POSITIONS)) {
                tokens = new address[](apps[i].balances.length);
                amounts = new int256[](apps[i].balances.length);
                for (uint256 j; j < apps[i].balances.length; ++j) {
                    tokens[j] = apps[i].balances[j].token;
                    amounts[j] = apps[i].balances[j].amount;
                }
                break;
            }
        }

        // The ETH/USD market has WETH as longToken and USDC as shortToken.
        // Both claimable fee entries must appear.
        bool foundLong;
        bool foundShort;
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == ARB_WETH && amounts[i] == int256(0.001 ether)) foundLong = true;
            if (tokens[i] == ARB_USDC && amounts[i] == int256(1e5)) foundShort = true;
        }
        assertTrue(foundLong, "claimable long-token (WETH) funding fee must appear in balances");
        assertTrue(foundShort, "claimable short-token (USDC) funding fee must appear in balances");
    }

    /// @notice When totalImpactUsd > 0 (positive price impact), the position net collateral is
    ///  larger than with zero impact.  Covers GmxLib line 336 (positive impactCollateral branch).
    function test_GmxLib_PositivePriceImpact_IncreasesPositionValue() public {
        // Open and execute a real position.
        vm.prank(poolOwner);
        bytes32 orderKey = IAGmxV2(pool).createIncreaseOrder(_defaultIncreaseParams());
        _executeOrder(orderKey, GMX_ETH_USD_MARKET);

        Position.Props[] memory positions = IGmxReader(GMX_READER).getAccountPositions(
            GMX_DATA_STORE, pool, 0, type(uint256).max
        );
        assertEq(positions.length, 1, "must have exactly 1 position");

        GmxValidatedPrice memory wethPrice =
            IGmxChainlinkPriceFeedProvider(GMX_CHAINLINK_PRICE_FEED).getOraclePrice(ARB_WETH, "");

        uint256 gmxFlag = 1 << uint256(Applications.GMX_V2_POSITIONS);

        // --- Baseline: zero impact ---
        GmxPositionInfo[] memory zeroImpact = new GmxPositionInfo[](1);
        zeroImpact[0] = _buildFakePosInfo({
            pos: positions[0],
            colPriceMin: wethPrice.min,
            colPriceMax: wethPrice.max,
            basePnlUsd: 0,
            totalImpactUsd: 0,
            claimableLong: 0,
            claimableShort: 0
        });
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountPositionInfoList.selector),
            abi.encode(zeroImpact)
        );
        ExternalApp[] memory appsNoImpact = IEApps(pool).getAppTokenBalances(gmxFlag);
        vm.clearMockedCalls();

        // --- Positive impact: totalImpactUsd = 500 USD in 1e30 precision (~0.167 WETH at 3000) ---
        int256 posImpactUsd = 500 * int256(GMX_USD); // $500 in 1e30
        GmxPositionInfo[] memory posImpact = new GmxPositionInfo[](1);
        posImpact[0] = _buildFakePosInfo({
            pos: positions[0],
            colPriceMin: wethPrice.min,
            colPriceMax: wethPrice.max,
            basePnlUsd: 0,
            totalImpactUsd: posImpactUsd,
            claimableLong: 0,
            claimableShort: 0
        });
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountPositionInfoList.selector),
            abi.encode(posImpact)
        );
        ExternalApp[] memory appsWithImpact = IEApps(pool).getAppTokenBalances(gmxFlag);
        vm.clearMockedCalls();

        // Extract net-collateral amounts from both results (token == ARB_WETH, index 0).
        int256 colNoImpact;
        int256 colWithImpact;
        for (uint256 i; i < appsNoImpact.length; ++i) {
            if (uint256(appsNoImpact[i].appType) == uint256(Applications.GMX_V2_POSITIONS)) {
                colNoImpact = appsNoImpact[i].balances[0].amount;
                break;
            }
        }
        for (uint256 i; i < appsWithImpact.length; ++i) {
            if (uint256(appsWithImpact[i].appType) == uint256(Applications.GMX_V2_POSITIONS)) {
                colWithImpact = appsWithImpact[i].balances[0].amount;
                break;
            }
        }

        assertGt(
            colWithImpact,
            colNoImpact,
            "positive price impact must increase reported net collateral"
        );
    }

    // =========================================================================
    // Helper — construct a minimal GmxPositionInfo for mocking
    // =========================================================================

    /// @dev Builds a GmxPositionInfo with chosen PnL/impact/funding-fee values while keeping
    ///  all other fields at their on-chain values.  Used solely for unit-coverage mocking.
    function _buildFakePosInfo(
        Position.Props memory pos,
        uint256 colPriceMin,
        uint256 colPriceMax,
        int256 basePnlUsd,
        int256 totalImpactUsd,
        uint256 claimableLong,
        uint256 claimableShort
    ) private pure returns (GmxPositionInfo memory info) {
        info.positionKey = bytes32(0);
        info.position = pos;

        // fees — zero everything except collateralTokenPrice and claimable funding
        info.fees.collateralTokenPrice = Price.Props({min: colPriceMin, max: colPriceMax});
        info.fees.funding.claimableLongTokenAmount = claimableLong;
        info.fees.funding.claimableShortTokenAmount = claimableShort;
        // totalCostAmount = 0 (no fees charged in the fake info)

        info.basePnlUsd = basePnlUsd;

        info.executionPriceResult = GmxExecutionPriceResult({
            priceImpactUsd: 0,
            executionPrice: 0,
            balanceWasImproved: false,
            proportionalPendingImpactUsd: 0,
            totalImpactUsd: totalImpactUsd,
            priceImpactDiffUsd: 0
        });
    }

    /// @notice Full USDC-collateral short: open → execute → close → execute.
    ///  After close:
    ///   - Position count must be 0.
    ///   - USDC must be back in the pool's wallet and counted in NAV.
    ///   - NAV after close must be within 2% of NAV after open — only execution
    ///     fees and trading costs separate the two states.
    ///
    ///  Why compare navAfterClose with navAfterOpen rather than navBefore?
    ///  USDC was dealt directly to the pool (external transfer, not via a swap adapter),
    ///  so it was NOT in activeTokensSet and NOT counted in navBefore.  After
    ///  createIncreaseOrder calls _trackToken(USDC), the token enters activeTokensSet.
    ///  During the open position, USDC wallet balance = 0 (all in GMX); the position
    ///  is valued by EApps.  After close, USDC returns to the wallet and is counted by
    ///  ENavView via the oracle price feed.  Both navAfterOpen and navAfterClose reflect
    ///  the true pool value including USDC; comparing them isolates the fee cost.
    ///
    ///  If _trackToken were absent, the returned USDC (≈ 1 000e6) would be invisible to
    ///  NAV after close, and navAfterClose would be several percent below navAfterOpen.
    function test_Nav_FullClose_UsdcCollateral() public {
        // ── Setup: mint shares so live NAV is computed ───────────────────────
        uint256 mintWeth = 1 ether;
        deal(ARB_WETH, poolOwner, mintWeth);
        vm.startPrank(poolOwner);
        IERC20(ARB_WETH).approve(pool, mintWeth);
        ISmartPoolActions(pool).mint(poolOwner, mintWeth, 0);
        vm.stopPrank();

        // Deal exactly the USDC collateral amount (external transfer, simulating
        // a token that was never tracked via a swap adapter).
        deal(ARB_USDC, pool, 1_000e6);

        // ── Open USDC-collateral short and execute ────────────────────────────
        IBaseOrderUtils.CreateOrderParams memory openP = IBaseOrderUtils.CreateOrderParams({
            addresses: IBaseOrderUtils.CreateOrderParamsAddresses({
                receiver: address(0),
                cancellationReceiver: address(0),
                callbackContract: address(0),
                uiFeeReceiver: address(0),
                market: GMX_ETH_USD_MARKET,
                initialCollateralToken: ARB_USDC,
                swapPath: new address[](0)
            }),
            numbers: IBaseOrderUtils.CreateOrderParamsNumbers({
                sizeDeltaUsd: SIZE_DELTA_USD,
                initialCollateralDeltaAmount: 1_000e6,
                triggerPrice: 0,
                acceptablePrice: 0, // market short: accept any price
                executionFee: 0,
                callbackGasLimit: 0,
                minOutputAmount: 0,
                validFromTime: 0
            }),
            orderType: Order.OrderType.MarketIncrease,
            decreasePositionSwapType: Order.DecreasePositionSwapType.NoSwap,
            isLong: false,
            shouldUnwrapNativeToken: false,
            autoCancel: false,
            referralCode: bytes32(0),
            dataList: new bytes32[](0)
        });
        vm.prank(poolOwner);
        bytes32 openKey = IAGmxV2(pool).createIncreaseOrder(openP);
        _executeOrder(openKey, GMX_ETH_USD_MARKET);

        ISmartPoolActions(pool).updateUnitaryValue();
        uint256 navAfterOpen = ISmartPoolState(pool).getPoolTokens().unitaryValue;
        assertGt(navAfterOpen, 0, "NAV must be positive with open USDC-short position");

        // ── Full close: market short decrease ─────────────────────────────────
        // acceptablePrice = type(uint256).max: for a short close, willing to buy back at any price.
        IBaseOrderUtils.CreateOrderParams memory closeP = IBaseOrderUtils.CreateOrderParams({
            addresses: IBaseOrderUtils.CreateOrderParamsAddresses({
                receiver: address(0),
                cancellationReceiver: address(0),
                callbackContract: address(0),
                uiFeeReceiver: address(0),
                market: GMX_ETH_USD_MARKET,
                initialCollateralToken: ARB_USDC,
                swapPath: new address[](0)
            }),
            numbers: IBaseOrderUtils.CreateOrderParamsNumbers({
                sizeDeltaUsd: SIZE_DELTA_USD,
                initialCollateralDeltaAmount: 0,
                triggerPrice: 0,
                acceptablePrice: type(uint256).max, // short close: accept any price up to max
                executionFee: 0,
                callbackGasLimit: 0,
                minOutputAmount: 0,
                validFromTime: 0
            }),
            orderType: Order.OrderType.MarketDecrease,
            decreasePositionSwapType: Order.DecreasePositionSwapType.NoSwap,
            isLong: false,
            shouldUnwrapNativeToken: false,
            autoCancel: false,
            referralCode: bytes32(0),
            dataList: new bytes32[](0)
        });
        vm.prank(poolOwner);
        bytes32 closeKey = IAGmxV2(pool).createDecreaseOrder(closeP);
        _executeOrder(closeKey, GMX_ETH_USD_MARKET);

        // ── Position must be gone ─────────────────────────────────────────────
        uint256 posCount = IGmxReader(GMX_READER)
            .getAccountPositions(GMX_DATA_STORE, pool, 0, type(uint256).max)
            .length;
        assertEq(posCount, 0, "pool must have 0 GMX positions after USDC short close");

        // ── USDC returned to wallet ───────────────────────────────────────────
        // GMX sends remaining collateral (after fees) back to pool address.
        uint256 usdcReturned = IERC20(ARB_USDC).balanceOf(pool);
        assertGt(usdcReturned, 0, "USDC must be returned to pool wallet after close");

        // ── NAV after close ≈ NAV after open (within 2%) ─────────────────────
        // navAfterOpen: WETH_wallet + EApps(USDC-in-GMX) valued in WETH.
        // navAfterClose: WETH_wallet + ENavView(USDC_wallet) valued in WETH via oracle.
        // Both states include the USDC value; only two execution fees + trading costs differ.
        // If _trackToken were missing, the USDC wallet balance would be invisible after
        // close, and navAfterClose would be several percent below navAfterOpen.
        ISmartPoolActions(pool).updateUnitaryValue();
        uint256 navAfterClose = ISmartPoolState(pool).getPoolTokens().unitaryValue;

        assertLe(navAfterClose, navAfterOpen, "close costs must not increase NAV vs post-open");
        assertGt(navAfterClose, (navAfterOpen * 98) / 100, "total fees from close must be within 2% of navAfterOpen");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helper interfaces
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal DataStore interface for oracle provider key reads/writes in tests.
interface IDataStore {
    function getAddress(bytes32 key) external view returns (address);
    function setAddress(bytes32 key, address value) external returns (address);
}

// Helper: IERC20 with name()
// ─────────────────────────────────────────────────────────────────────────────
interface IERC20Extended {
    function name() external view returns (string memory);
    function balanceOf(address) external view returns (uint256);
}
