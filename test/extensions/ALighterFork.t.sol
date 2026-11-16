// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {LighterDeploymentFixture} from "../fixtures/LighterDeploymentFixture.sol";
import {LighterRouteType, ILighterInteropManager} from "../../contracts/protocol/extensions/adapters/interfaces/lighter/ILighterInteropManager.sol";
import {ILighterCoreEntrypoint} from "../../contracts/protocol/extensions/adapters/interfaces/lighter/ILighterCoreEntrypoint.sol";
import {LighterTypes} from "../../contracts/protocol/types/LighterTypes.sol";
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
import {ExternalApp} from "../../contracts/protocol/types/ExternalApp.sol";

/// @title ALighterForkTest
/// @notice Fork tests for the Lighter adapter against real LighterEVM predeploys.
/// @dev Requires LIGHTER_DEVNET_RPC_URL; a missing or misconfigured URL fails setUp loudly (like every
///  other chain's fork suite), it never skips.
/// @dev Foundry's EVM does not implement the READ_CORE precompile even when forking, so read
///  precompile return data is mocked (same approach as AHyperliquidFork.t.sol).
contract ALighterForkTest is Test {
    LighterDeploymentFixture internal fixture;
    address internal pool;
    address internal poolOwner;
    address internal aLighter;
    address internal usdc;

    // Mocked perp market: ETH-PERP (market 0, quoteMultiplier 1 as verified live on devnet 1.2.0).
    uint16 internal constant MARKET_ID = 0;

    function setUp() public {
        fixture = new LighterDeploymentFixture();
        fixture.deployFixture();

        pool = fixture.pool();
        poolOwner = fixture.poolOwner();
        aLighter = fixture.aLighter();
        usdc = fixture.LIGHTER_USDC();
    }

    /*//////////////////////////////////////////////////////////////
                        READ_CORE MOCK HELPERS
    //////////////////////////////////////////////////////////////*/

    function _wrap(bytes memory data) internal pure returns (bytes memory) {
        return abi.encode(true, data);
    }

    function _notFound() internal pure returns (bytes memory) {
        return abi.encode(false, bytes(""));
    }

    function _mockAccountInfo(int128 collateral) internal {
        vm.mockCall(
            address(0x6600000000000000000000000000000000000000),
            abi.encodePacked(uint16(0x0001), pool, false),
            _wrap(
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
        // The account-info read reports found=false when the account does not exist.
        vm.mockCall(
            address(0x6600000000000000000000000000000000000000),
            abi.encodePacked(uint16(0x0001), pool, false),
            _notFound()
        );
    }

    function _mockEvmAccountIndex(uint48 accountIndex) internal {
        vm.mockCall(
            address(0x6600000000000000000000000000000000000000),
            abi.encodePacked(uint16(0x0009), pool),
            _wrap(abi.encode(accountIndex))
        );
    }

    /// @notice Mocks the transaction-status read (0x0000): 0 pending, 1 successful, 2 failed.
    /// @dev Tx status is the one read without the (bool found, bytes) envelope.
    function _mockTxStatus(uint64 reqId, uint8 status) internal {
        vm.mockCall(
            address(0x6600000000000000000000000000000000000000),
            abi.encodePacked(uint16(0x0000), reqId),
            abi.encode(status, bytes(""))
        );
    }

    /// @notice Tx status with a success payload (a deposit's abi.encode(uint64 acceptedAmount)).
    function _mockTxStatusWithPayload(uint64 reqId, uint8 status, bytes memory payload) internal {
        vm.mockCall(
            address(0x6600000000000000000000000000000000000000),
            abi.encodePacked(uint16(0x0000), reqId),
            abi.encode(status, payload)
        );
    }

    function _mockMarketInfo(uint16 marketId, uint64 markPrice) internal {
        vm.mockCall(
            address(0x6600000000000000000000000000000000000000),
            abi.encodePacked(uint16(0x0005), marketId),
            _wrap(
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
                        markPrice: markPrice,
                        // Devnet 1.2.0: quoteMultiplier 1 (verified live on all devnet perp markets).
                        quoteMultiplier: 1,
                        fundingRatePrefixSum: 0,
                        lastFundingRoundTimestamp: 0
                    })
                )
            )
        );
    }

    function _mockPosition(uint16 marketId, LighterTypes.Position memory position) internal {
        vm.mockCall(
            address(0x6600000000000000000000000000000000000000),
            abi.encodePacked(uint16(0x0007), pool, false, marketId),
            _wrap(abi.encode(position))
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

    /// @notice Mocks EvmToCoreEntrypoint.createOrder to accept the write. Since devnet 1.1.0 the
    ///  predeploy applies Core's order admission checks (account must exist on Core with
    ///  collateral), which a forked pool can never satisfy — the order-write tests assert the
    ///  adapter's calldata and auto-tracking instead of executing real Core admission. Selector
    ///  prefix match covers every argument combination; per the 1.2.0 spec a successful
    ///  createOrder returns abi.encode(uint64 orderIndex).
    function _mockCreateOrder() internal {
        vm.mockCall(
            LighterConstants.CORE_ENTRYPOINT,
            abi.encodePacked(ILighterCoreEntrypoint.createOrder.selector),
            abi.encode(uint64(1))
        );
    }

    /*//////////////////////////////////////////////////////////////
                                  TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Smoke test: the adapter is deployed, authorized, and the pool is funded.
    function testFork_AdapterAndPoolDeployed() public {
        assertEq(block.chainid, fixture.LIGHTEREVM_CHAIN_ID(), "Should be on LighterEVM fork");
        assertTrue(aLighter.code.length > 0, "ALighter should be deployed");
        assertTrue(pool.code.length > 0, "Pool should be deployed");
        assertGt(IERC20(usdc).balanceOf(pool), 0, "Pool should hold USDC");
    }

    /// @notice Deploying the Hyperliquid adapter on LighterEVM reverts: adapters are chain-locked.
    function testFork_AHyperliquid_DeploymentRevertsOnLighterEVM() public {
        bytes memory code = vm.getCode("AHyperliquid");
        vm.expectRevert(); // NotHyperEVM (AHyperliquid constructor)
        assembly {
            pop(create(0, add(code, 0x20), mload(code)))
        }
    }

    /// @notice Deposit USDC straight into the Core perps route through the adapter's interop
    ///  manager call (mocked return: no token pull happens under the mock).
    function testFork_DepositToCorePerpsRoute() public {
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
    function testFork_Deposit_GuardsEnforced() public {
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
    function testFork_WithdrawRequiresCoreAccount() public {
        _mockNoAccount();
        vm.prank(poolOwner);
        vm.expectRevert(IALighter.AccountNotActivated.selector);
        IALighter(pool).sendToEvm(0, 3, pool, LighterRouteType.Perps, 100e6);
    }

    /// @notice createOrder auto-tracks the traded market: no separate tracking step is needed.
    ///  Since devnet 1.2.0 any Core perp market can be traded (the on-chain quoteMultiplier
    ///  replaced the release-time decimals table).
    /// @dev The final createOrder hits the real Core entrypoint predeploy; order parameters may need
    ///  adjustment once devnet RPC access allows validating them against the live predeploy.
    function testFork_CreateOrderAutoTracksMarket() public {
        _mockMarketInfo(MARKET_ID, 100_00);
        _mockMarketInfo(5, 100_00);
        _mockEvmAccountIndex(1);
        // createOrder requires an activated Core account (checked after the market gates).
        _mockAccountInfo(0);
        _mockCreateOrder();

        vm.startPrank(poolOwner);

        // Spot markets are rejected outright.
        vm.expectRevert(IALighter.InvalidMarket.selector);
        IALighter(pool).createOrder(0, 2048, 1, 0, 0, 0, 1, 100_00, true, false, 0);

        // A previously untracked perp market trades and is auto-tracked.
        IALighter(pool).createOrder(0, 5, 1, 0, 0, 0, 1, 100_00, true, false, 0);
        IALighter(pool).createOrder(0, MARKET_ID, 1, 0, 0, 0, 1, 100_00, true, false, 0);
        vm.stopPrank();

        // The traded markets are tracked for NAV valuation without any explicit tracking call.
        uint16[] memory marketIds = IEAppsLighter(pool).getLighterTrackedMarkets();
        assertEq(marketIds.length, 2, "Traded markets should be auto-tracked");
        assertEq(marketIds[0], 5);
        assertEq(marketIds[1], MARKET_ID);
    }

    /// @notice NAV valuation reads collateral plus tracked positions from (mocked) Core state.
    function testFork_NavWithTrackedPosition() public {
        _mockMarketInfo(MARKET_ID, 101_00);
        _mockEvmAccountIndex(1);
        _mockAccountInfo(0);
        _mockCreateOrder();
        vm.startPrank(poolOwner);
        IALighter(pool).createOrder(0, MARKET_ID, 1, 0, 0, 0, 1, 100_00, true, false, 0);
        vm.stopPrank();

        // 10 base units long, entry notional 10 * 100.0 = 1_000 USDC in Core USDC base units,
        // mark 101.0 with quoteMultiplier 1: markValue = 100_000 * 101_00 = 1_010e6;
        // pnl = 1_010e6 - 1_000e6 = 10e6.
        _mockAccountInfo(1_000e6);
        _mockPosition(
            MARKET_ID,
            LighterTypes.Position({
                size: 100_000,
                entryQuote: 1_000e6,
                initialMarginFraction: 0,
                totalOrderCount: 0,
                totalPositionTiedOrderCount: 0,
                marginMode: 0,
                allocatedMargin: 0,
                lastFundingRatePrefixSum: 0
            })
        );

        ExternalApp[] memory apps = IEApps(pool).getAppTokenBalances(1 << uint256(Applications.LIGHTER_PERPS));
        ExternalApp memory lighterApp = _findLighterApp(apps);
        assertEq(lighterApp.balances.length, 1, "Lighter app should report one balance");
        assertEq(lighterApp.balances[0].token, usdc, "Balance token should be USDC");
        assertEq(lighterApp.balances[0].amount, 1_010e6, "Balance should be collateral plus position PnL");
    }

    /// @notice Lock semantics around a deposit: from the request until the async refund lands,
    ///  minting is locked (pending included — the lock keeps the request-time snapshot exact);
    ///  once the refund lands in the pool wallet, the mint's own evaluation clears the record and
    ///  unlocks in the same pass.
    function testFork_MintLockLifecycle() public {
        _mockAccountInfo(0);
        _mockEvmAccountIndex(1);

        uint256 depositAmount = 10_000e6;
        _mockSendToCore(depositAmount, 1);
        vm.prank(poolOwner);
        IALighter(pool).sendToCore(3, pool, false, depositAmount, LighterRouteType.Perps);

        // Pending: locked.
        deal(usdc, poolOwner, depositAmount);
        vm.startPrank(poolOwner);
        IERC20(usdc).approve(pool, depositAmount);
        vm.expectRevert(LighterLib.NavLocked.selector);
        ISmartPoolActions(pool).mint(poolOwner, depositAmount, 0);

        // Settled with a partial acceptance: the unaccepted remainder is in transit and the lock
        // holds (the reverted mint's evaluation is rolled back, so commit the record with an
        // exempt updateUnitaryValue).
        uint256 snapshot = IERC20(usdc).balanceOf(pool);
        vm.roll(block.number + 1);
        _mockAccountInfo(int128(uint128(depositAmount - 1e6)));
        _mockTxStatusWithPayload(1, 1, abi.encode(uint64(depositAmount - 1e6)));
        deal(usdc, poolOwner, depositAmount);
        IERC20(usdc).approve(pool, depositAmount);
        vm.expectRevert(LighterLib.NavLocked.selector);
        ISmartPoolActions(pool).mint(poolOwner, depositAmount, 0);
        ISmartPoolActions(pool).updateUnitaryValue();

        // The refund lands in the pool wallet (balance increases over the request-time snapshot):
        // the mint's own evaluation clears the record and unlocks in the same pass.
        deal(usdc, pool, snapshot + 1e6);
        ISmartPoolActions(pool).mint(poolOwner, depositAmount, 0);
        vm.stopPrank();
    }

    /// @notice EOracle on LighterEVM must only recognize USDC as having a price feed.
    function testFork_EOracle_OnlyUsdcHasPriceFeed() public {
        assertTrue(IEOracle(pool).hasPriceFeed(usdc), "USDC must have a price feed");
        assertFalse(IEOracle(pool).hasPriceFeed(fixture.LIGHTER_WETH()), "WETH must not have a price feed");
        assertFalse(IEOracle(pool).hasPriceFeed(address(0x1)), "Random token must not have a price feed");
    }

    /// @notice The deposit must not activate any other application bit.
    function testFork_OnlyLighterAppBitActivated() public {
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
