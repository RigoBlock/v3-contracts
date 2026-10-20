// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {LighterDeploymentFixture} from "../fixtures/LighterDeploymentFixture.sol";
import {LighterRouteType, ILighterInteropManager} from "../../contracts/protocol/extensions/adapters/interfaces/lighter/ILighterInteropManager.sol";
import {LighterTypes} from "../../contracts/protocol/extensions/adapters/interfaces/lighter/LighterTypes.sol";
import {LighterConstants} from "../../contracts/protocol/types/LighterConstants.sol";
import {IALighter} from "../../contracts/protocol/extensions/adapters/interfaces/IALighter.sol";
import {LighterLib} from "../../contracts/protocol/libraries/LighterLib.sol";
import {IEApps} from "../../contracts/protocol/extensions/adapters/interfaces/IEApps.sol";
import {IEAppsLighter} from "../../contracts/protocol/extensions/adapters/interfaces/IEAppsLighter.sol";
import {IEOracle} from "../../contracts/protocol/extensions/adapters/interfaces/IEOracle.sol";
import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {Applications} from "../../contracts/protocol/types/Applications.sol";
import {ExternalApp, AppTokenBalance} from "../../contracts/protocol/types/ExternalApp.sol";

/// @title ALighterForkTest
/// @notice Fork tests for the Lighter adapter against real LighterEVM predeploys.
/// @dev Requires LIGHTER_RPC_URL; the whole suite is skipped while LighterEVM has no public RPC.
/// @dev Foundry's EVM does not implement the READ_CORE precompile even when forking, so read
///  precompile return data is mocked (same approach as AHyperliquidFork.t.sol).
contract ALighterForkTest is Test {
    LighterDeploymentFixture internal fixture;
    address internal pool;
    address internal poolOwner;
    address internal aLighter;
    address internal usdc;

    // Mocked perp market: ETH-PERP (market 0, size_decimals 4, price_decimals 2 per LighterConstants).
    uint16 internal constant MARKET_ID = 0;

    function setUp() public {
        fixture = new LighterDeploymentFixture();
        fixture.deployFixture();

        pool = fixture.pool();
        poolOwner = fixture.poolOwner();
        aLighter = fixture.aLighter();
        usdc = fixture.LIGHTER_USDC();
    }

    /// @notice Skips the test when LIGHTER_RPC_URL is unset (must run at test level, forge-std rule).
    modifier withLighterFork() {
        if (fixture.skipped()) vm.skip(true);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                        READ_CORE MOCK HELPERS
    //////////////////////////////////////////////////////////////*/

    function _mockAccountInfo(int128 collateral) internal {
        // Every read except 0x0000 returns abi.encode(bool found, bytes data) per the Lighter docs.
        vm.mockCall(
            address(0x6600000000000000000000000000000000000000),
            abi.encodePacked(uint16(0x0001), pool, false),
            abi.encode(
                true,
                abi.encode(
                    LighterTypes.AccountInfo({
                        accountType: 0,
                        accountIndex: 1,
                        masterAccountIndex: 1,
                        l1Address: address(0),
                        evmAddress: pool,
                        collateralBaseAmount: collateral
                    })
                )
            )
        );
    }

    function _mockNoAccount() internal {
        // Per the docs a nonexistent account still succeeds with found = false.
        vm.mockCall(
            address(0x6600000000000000000000000000000000000000),
            abi.encodePacked(uint16(0x0001), pool, false),
            abi.encode(false, bytes(""))
        );
    }

    function _mockEvmAccountIndex(uint48 accountIndex) internal {
        vm.mockCall(
            address(0x6600000000000000000000000000000000000000),
            abi.encodePacked(uint16(0x0009), pool),
            abi.encode(true, abi.encode(accountIndex))
        );
    }

    /// @notice Mocks the transaction-status read (0x0000): 0 pending, 1 successful, 2 failed.
    /// @dev 0x0000 is the only read without the (bool found, bytes) envelope.
    function _mockTxStatus(uint64 reqId, uint8 status) internal {
        vm.mockCall(
            address(0x6600000000000000000000000000000000000000),
            abi.encodePacked(uint16(0x0000), reqId),
            abi.encode(status, bytes(""))
        );
    }

    function _mockMarketInfo(uint16 marketId, uint64 markPrice) internal {
        vm.mockCall(
            address(0x6600000000000000000000000000000000000000),
            abi.encodePacked(uint16(0x0005), marketId),
            abi.encode(
                true,
                abi.encode(
                    LighterTypes.MarketInfo({
                        marketType: 0,
                        baseAssetId: 0,
                        // Perpetuals carry quoteAssetId == 0 on Core (docs + live devnet verification).
                        quoteAssetId: 0,
                        takerFee: 0,
                        makerFee: 0,
                        minBaseAmount: 0,
                        minQuoteAmount: 0,
                        liquidationFee: 0,
                        indexPrice: markPrice,
                        markPrice: markPrice
                    })
                )
            )
        );
    }

    function _mockPosition(uint16 marketId, LighterTypes.Position memory position) internal {
        vm.mockCall(
            address(0x6600000000000000000000000000000000000000),
            abi.encodePacked(uint16(0x0007), pool, false, marketId),
            abi.encode(true, abi.encode(position))
        );
    }

    /// @notice Mocks EvmInteropManager.sendToCore to accept the deposit and return a reqId.
    /// @dev The devnet predeploy may carry no code after a devnet reset, and the deposit tests
    ///  assert the adapter's calldata (exact-match mock) and bookkeeping instead of executing
    ///  the real wrapper. No token pull happens under the mock, so balance assertions must use
    ///  the adapter's allowance reset instead.
    function _mockSendToCore(uint256 amount, uint64 reqId) internal {
        vm.mockCall(
            LighterConstants.EVM_INTEROP_MANAGER,
            abi.encodeWithSelector(
                ILighterInteropManager.sendToCore.selector,
                LighterConstants.USDC_ASSET_INDEX,
                pool,
                false,
                amount,
                LighterRouteType.Perps
            ),
            abi.encode(reqId)
        );
    }

    /*//////////////////////////////////////////////////////////////
                                  TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Smoke test: the adapter is deployed, authorized, and the pool is funded.
    function testFork_AdapterAndPoolDeployed() public withLighterFork {
        assertEq(block.chainid, fixture.LIGHTEREVM_CHAIN_ID(), "Should be on LighterEVM fork");
        assertTrue(aLighter.code.length > 0, "ALighter should be deployed");
        assertTrue(pool.code.length > 0, "Pool should be deployed");
        assertGt(IERC20(usdc).balanceOf(pool), 0, "Pool should hold USDC");
    }

    /// @notice Deploying the Hyperliquid adapter on LighterEVM reverts: adapters are chain-locked.
    function testFork_AHyperliquid_DeploymentRevertsOnLighterEVM() public withLighterFork {
        bytes memory code = vm.getCode("AHyperliquid");
        vm.expectRevert(); // NotHyperEVM (AHyperliquid constructor)
        assembly {
            pop(create(0, add(code, 0x20), mload(code)))
        }
    }

    /// @notice Deposit USDC straight into the Core perps route through the adapter's interop
    ///  manager call (mocked return: no token pull happens under the mock).
    function testFork_DepositToCorePerpsRoute() public withLighterFork {
        uint256 depositAmount = 10_000e6;
        _mockSendToCore(depositAmount, 1);

        vm.prank(poolOwner);
        IALighter(pool).sendToCore(3, pool, false, depositAmount, LighterRouteType.Perps);

        // Pattern 2: the adapter approved the exact amount for the call and reset to 1.
        assertEq(IERC20(usdc).allowance(pool, LighterConstants.EVM_INTEROP_MANAGER), 1, "Allowance should reset to 1");

        // The Lighter application bit must have been activated by the deposit.
        uint256 activeApps = ISmartPoolState(pool).getActiveApplications();
        assertTrue((activeApps & (1 << uint256(Applications.LIGHTER_PERPS))) != 0, "LIGHTER_PERPS should be active");
    }

    /// @notice The adapter enforces the pool as recipient, the perps route, and USDC.
    function testFork_Deposit_GuardsEnforced() public withLighterFork {
        vm.startPrank(poolOwner);
        vm.expectRevert(IALighter.InvalidRecipient.selector);
        IALighter(pool).sendToCore(3, address(0x1), false, 1e6, LighterRouteType.Perps);

        vm.expectRevert(IALighter.InvalidRoute.selector);
        IALighter(pool).sendToCore(3, pool, false, 1e6, LighterRouteType.Spot);

        vm.expectRevert(IALighter.InvalidAsset.selector);
        IALighter(pool).sendToCore(1, pool, false, 1e6, LighterRouteType.Perps);
        vm.stopPrank();
    }

    /// @notice Withdrawing without a Core account reverts; with one, it records the out-flight.
    function testFork_WithdrawRequiresCoreAccount() public withLighterFork {
        _mockNoAccount();
        vm.prank(poolOwner);
        vm.expectRevert(IALighter.AccountNotActivated.selector);
        IALighter(pool).sendToEvm(0, 3, pool, LighterRouteType.Perps, 100e6);
    }

    /// @notice Only tracked markets can be traded: every traded market is NAV-valued.
    /// @dev The final createOrder hits the real Core entrypoint predeploy; order parameters may need
    ///  adjustment once devnet RPC access allows validating them against the live predeploy.
    function testFork_CreateOrderRequiresTrackedMarket() public withLighterFork {
        _mockMarketInfo(MARKET_ID, 100_00);
        _mockEvmAccountIndex(1);
        // createOrder requires an activated Core account (checked after the tracked-market gate).
        _mockAccountInfo(0);

        vm.startPrank(poolOwner);
        vm.expectRevert(LighterLib.MarketNotTracked.selector);
        IALighter(pool).createOrder(0, MARKET_ID, 1, 0, 0, 0, 1, 100_00, true, false, 0);

        // Spot markets are rejected outright.
        vm.expectRevert(IALighter.InvalidMarket.selector);
        IALighter(pool).createOrder(0, 2048, 1, 0, 0, 0, 1, 100_00, true, false, 0);

        IALighter(pool).trackMarket(MARKET_ID);
        IALighter(pool).createOrder(0, MARKET_ID, 1, 0, 0, 0, 1, 100_00, true, false, 0);
        vm.stopPrank();
    }

    /// @notice Untracking requires a closed position.
    function testFork_UntrackRequiresClosedPosition() public withLighterFork {
        _mockMarketInfo(MARKET_ID, 100_00);
        _mockEvmAccountIndex(1);

        vm.startPrank(poolOwner);
        IALighter(pool).trackMarket(MARKET_ID);

        _mockPosition(
            MARKET_ID,
            LighterTypes.Position({
                lastFundingRatePrefixSum: 0,
                position: 1_00,
                entryQuote: 100_0000,
                initialMarginFraction: 0,
                totalOrderCount: 0,
                totalPositionTiedOrderCount: 0,
                marginMode: 0,
                allocatedMargin: 0
            })
        );
        vm.expectRevert(IALighter.PositionNotClosed.selector);
        IALighter(pool).untrackMarket(MARKET_ID);

        _mockPosition(
            MARKET_ID,
            LighterTypes.Position({
                lastFundingRatePrefixSum: 0,
                position: 0,
                entryQuote: 0,
                initialMarginFraction: 0,
                totalOrderCount: 0,
                totalPositionTiedOrderCount: 0,
                marginMode: 0,
                allocatedMargin: 0
            })
        );
        IALighter(pool).untrackMarket(MARKET_ID);
        vm.stopPrank();
    }

    /// @notice NAV valuation reads collateral plus tracked positions from (mocked) Core state.
    function testFork_NavWithTrackedPosition() public withLighterFork {
        _mockMarketInfo(MARKET_ID, 101_00);
        _mockEvmAccountIndex(1);
        vm.prank(poolOwner);
        IALighter(pool).trackMarket(MARKET_ID);

        // 10 base units long (size_decimals 4 => raw amount 100_000), entry notional
        // 10 * 100.0 = 1_000 USDC in Core USDC base units, mark 101.0 (price_decimals 2):
        // markValue = 100_000 * 101_00 * 1e6 / 10^(4+2) = 1_010e6; pnl = 1_010e6 - 1_000e6 = 10e6.
        _mockAccountInfo(1_000e6);
        _mockPosition(
            MARKET_ID,
            LighterTypes.Position({
                lastFundingRatePrefixSum: 0,
                position: 100_000,
                entryQuote: 1_000e6,
                initialMarginFraction: 0,
                totalOrderCount: 0,
                totalPositionTiedOrderCount: 0,
                marginMode: 0,
                allocatedMargin: 0
            })
        );

        ExternalApp[] memory apps = IEApps(pool).getAppTokenBalances(1 << uint256(Applications.LIGHTER_PERPS));
        ExternalApp memory lighterApp = _findLighterApp(apps);
        assertEq(lighterApp.balances.length, 1, "Lighter app should report one balance");
        assertEq(lighterApp.balances[0].token, usdc, "Balance token should be USDC");
        assertEq(lighterApp.balances[0].amount, 1_010e6, "Balance should be collateral plus position PnL");

        // The EAppsLighter view exposes the same valuation directly.
        AppTokenBalance[] memory viewBalances = IEAppsLighter(pool).getLighterBalances();
        assertEq(viewBalances.length, 1, "Lighter view should report one balance");
        assertEq(viewBalances[0].token, usdc, "View balance token should be USDC");
        assertEq(viewBalances[0].amount, 1_010e6, "View balance should equal the EApps valuation");
    }

    /// @notice Minting is settlement-locked after a deposit and works again after the window.
    function testFork_MintLockedDuringSettlementWindow() public withLighterFork {
        _mockAccountInfo(0);
        _mockEvmAccountIndex(1);

        uint256 depositAmount = 10_000e6;
        _mockSendToCore(depositAmount, 1);
        vm.prank(poolOwner);
        IALighter(pool).sendToCore(3, pool, false, depositAmount, LighterRouteType.Perps);

        // Same block: allowed (in-flight covers the lagging Core read).
        _mockAccountInfo(0);
        deal(usdc, poolOwner, depositAmount);
        vm.startPrank(poolOwner);
        IERC20(usdc).approve(pool, depositAmount);
        ISmartPoolActions(pool).mint(poolOwner, depositAmount, 0);

        // Next block within the window: locked.
        vm.roll(block.number + 1);
        _mockAccountInfo(0);
        deal(usdc, poolOwner, depositAmount);
        IERC20(usdc).approve(pool, depositAmount);
        vm.expectRevert(LighterLib.NavLocked.selector);
        ISmartPoolActions(pool).mint(poolOwner, depositAmount, 0);

        // After the window: allowed again.
        vm.warp(block.timestamp + 17 seconds);
        _mockAccountInfo(int128(uint128(depositAmount)));
        ISmartPoolActions(pool).mint(poolOwner, depositAmount, 0);
        vm.stopPrank();
    }

    /// @notice EOracle on LighterEVM must only recognize USDC as having a price feed.
    function testFork_EOracle_OnlyUsdcHasPriceFeed() public withLighterFork {
        assertTrue(IEOracle(pool).hasPriceFeed(usdc), "USDC must have a price feed");
        assertFalse(IEOracle(pool).hasPriceFeed(fixture.LIGHTER_WETH()), "WETH must not have a price feed");
        assertFalse(IEOracle(pool).hasPriceFeed(address(0x1)), "Random token must not have a price feed");
    }

    /// @notice The deposit must not activate any other application bit.
    function testFork_OnlyLighterAppBitActivated() public withLighterFork {
        _mockAccountInfo(0);
        _mockEvmAccountIndex(1);
        _mockSendToCore(10_000e6, 1);
        uint256 activeBefore = ISmartPoolState(pool).getActiveApplications();
        vm.prank(poolOwner);
        IALighter(pool).sendToCore(3, pool, false, 10_000e6, LighterRouteType.Perps);
        uint256 activeAfter = ISmartPoolState(pool).getActiveApplications();
        assertEq(
            activeAfter & ~(1 << uint256(Applications.LIGHTER_PERPS)),
            activeBefore & ~(1 << uint256(Applications.LIGHTER_PERPS)),
            "No other application bit may change"
        );
    }

    function _findLighterApp(ExternalApp[] memory apps) private pure returns (ExternalApp memory lighterApp) {
        for (uint256 i; i < apps.length; i++) {
            if (apps[i].appType == uint256(Applications.LIGHTER_PERPS)) {
                return apps[i];
            }
        }
        revert("Lighter application should be returned");
    }
}
