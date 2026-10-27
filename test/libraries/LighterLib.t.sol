// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {LighterLib} from "../../contracts/protocol/libraries/LighterLib.sol";
import {LighterTypes} from "../../contracts/protocol/extensions/adapters/interfaces/lighter/LighterTypes.sol";
import {StorageLib} from "../../contracts/protocol/libraries/StorageLib.sol";
import {LighterConstants} from "../../contracts/protocol/types/LighterConstants.sol";
import {UnknownMarket} from "../../contracts/protocol/types/LighterConstants.sol";
import {LighterSlot, TrackedMarket} from "../../contracts/protocol/types/Applications.sol";
import {AppTokenBalance} from "../../contracts/protocol/types/ExternalApp.sol";

/// @notice Exposes LighterLib internals for unit testing.
/// @dev The lib reads the Lighter slot from the executing contract's own storage: tracked
///  markets and in-flight accounting all run against the harness's storage.
contract LighterLibHarness {
    function getLighterBalances(address account) external returns (AppTokenBalance[] memory) {
        return LighterLib.getLighterBalances(account);
    }

    function trackMarket(uint16 marketId) external {
        LighterLib.trackMarket(marketId);
    }

    function readPosition(address account, uint16 marketId) external view returns (LighterTypes.Position memory) {
        return LighterLib.readPosition(account, marketId);
    }

    /// @notice Seeds a tracked-market entry directly into storage, bypassing the Core validation
    ///  (and the release-time decimals table), so the 32-entry cap can be exercised with more
    ///  markets than the table whitelists.
    function seedTrackedMarket(uint16 marketId, uint8 sizeDecimals, uint8 priceDecimals) external {
        LighterSlot storage slot = StorageLib.lighterSlot();
        slot.marketIndex[marketId] = slot.trackedMarkets.length + 1;
        slot.markets[marketId] = TrackedMarket({sizeDecimals: sizeDecimals, priceDecimals: priceDecimals});
        slot.trackedMarkets.push(marketId);
    }

    function coreAccountExists(address account) external view returns (bool) {
        return LighterLib.coreAccountExists(account);
    }

    function readTxStatus(uint64 reqId) external view returns (uint8) {
        return LighterLib.readTxStatus(reqId);
    }

    function recordAction(int256 amount, uint64 reqId) external {
        LighterLib.recordAction(amount, reqId);
    }

    function marketIndex(uint16 marketId) external view returns (uint256) {
        return StorageLib.lighterSlot().marketIndex[marketId];
    }

    function trackedMarkets() external view returns (uint16[] memory) {
        return StorageLib.lighterSlot().trackedMarkets;
    }
}

/// @title LighterLibTest
/// @notice Non-fork unit tests for LighterLib's deterministic READ_CORE reads, tracked-market
///  registry validation and the NAV-loop pruning of stale tracked markets.
/// @dev Per the Lighter docs every read except tx status returns the
///  abi.encode(bool found, bytes data) envelope: found=false (with empty data, read still
///  succeeding) means the queried account/asset/market does not exist, while a failed
///  staticcall means a malformed query. Mocks below reproduce the envelope.
contract LighterLibTest is Test {
    LighterLibHarness internal harness;

    address internal constant READ_CORE = LighterConstants.READ_CORE;
    address internal constant ACCOUNT = address(0xabc);

    function setUp() public {
        harness = new LighterLibHarness();
        _mockAccountInfo(ACCOUNT, _accountInfo(0));
    }

    // =========================================================================
    // READ_CORE mock helpers (found/data envelope, per the Lighter docs)
    // =========================================================================

    function _wrap(bytes memory data) internal pure returns (bytes memory) {
        return abi.encode(true, data);
    }

    function _notFound() internal pure returns (bytes memory) {
        return abi.encode(false, bytes(""));
    }

    function _mockAccountInfo(address account, LighterTypes.AccountInfo memory info) private {
        vm.mockCall(
            READ_CORE,
            abi.encodePacked(LighterLib._SELECTOR_ACCOUNT_INFO, account, false),
            _wrap(abi.encode(info))
        );
    }

    function _mockMarketInfo(uint16 marketId, uint8 marketType, uint32 quoteAssetId) private {
        vm.mockCall(
            READ_CORE,
            abi.encodePacked(LighterLib._SELECTOR_MARKET_INFO, marketId),
            _wrap(
                abi.encode(
                    LighterTypes.MarketInfo({
                        marketType: marketType,
                        baseAssetId: 2,
                        quoteAssetId: quoteAssetId,
                        takerFee: 0,
                        makerFee: 0,
                        minBaseAmount: 0,
                        minQuoteAmount: 0,
                        liquidationFee: 0,
                        indexPrice: 500_0000,
                        markPrice: 500_0000
                    })
                )
            )
        );
    }

    /// @notice Perp market-info mock with a specific mark price (the default helper pins 500_0000).
    function _mockMarketInfoWithPrice(uint16 marketId, uint64 markPrice) private {
        vm.mockCall(
            READ_CORE,
            abi.encodePacked(LighterLib._SELECTOR_MARKET_INFO, marketId),
            _wrap(
                abi.encode(
                    LighterTypes.MarketInfo({
                        marketType: 0,
                        baseAssetId: 2,
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

    function _mockPosition(address account, uint16 marketId, LighterTypes.Position memory position) private {
        vm.mockCall(
            READ_CORE,
            abi.encodePacked(LighterLib._SELECTOR_POSITION, account, false, marketId),
            _wrap(abi.encode(position))
        );
    }

    /// @notice found=false envelope: the position read succeeds and reports "no position".
    function _mockPositionNotFound(address account, uint16 marketId) private {
        vm.mockCall(READ_CORE, abi.encodePacked(LighterLib._SELECTOR_POSITION, account, false, marketId), _notFound());
    }

    /// @notice found=false means "no account": coreAccountExists reports false.
    function testCoreAccountExistsFalseWhenNotFound() public {
        vm.mockCall(READ_CORE, abi.encodePacked(LighterLib._SELECTOR_ACCOUNT_INFO, ACCOUNT, false), _notFound());
        assertFalse(harness.coreAccountExists(ACCOUNT));
    }

    /// @notice A failed staticcall is a malformed-query error, not "not found": it reverts.
    function testCoreAccountExistsRevertsOnFailedRead() public {
        vm.mockCallRevert(READ_CORE, abi.encodePacked(LighterLib._SELECTOR_ACCOUNT_INFO, ACCOUNT, false), "");
        vm.expectRevert(LighterLib.LighterReadFailed.selector);
        harness.coreAccountExists(ACCOUNT);
    }

    function testCoreAccountExistsTrueOnSixWords() public {
        assertTrue(harness.coreAccountExists(ACCOUNT));
    }

    /// @notice An envelope claiming found=true with a malformed inner payload reverts at the
    ///  tuple decode instead of being silently treated as "no position".
    function testReadPositionRevertsOnMalformedSuccessfulData() public {
        // found=true wrapping fewer words than the 7-field Position tuple.
        vm.mockCall(
            READ_CORE,
            abi.encodePacked(LighterLib._SELECTOR_POSITION, ACCOUNT, false, uint16(1)),
            abi.encode(true, new bytes(6 * 32))
        );
        vm.expectRevert();
        harness.readPosition(ACCOUNT, 1);
    }

    /// @notice A not-found position read means "no position": the zeroed struct is pruned by
    ///  the NAV loop and NAV degrades to collateral-only instead of reverting.
    function testGetLighterBalancesNoPositionWhenNotFound() public {
        _track(1);
        _mockPositionNotFound(ACCOUNT, 1);

        AppTokenBalance[] memory balances = harness.getLighterBalances(ACCOUNT);
        assertEq(balances.length, 0, "No collateral and no size: purgeable empty list");
        assertEq(harness.trackedMarkets().length, 0, "Not-found market must be pruned by the NAV loop");
        assertEq(harness.marketIndex(1), 0);
    }

    /// @notice A zero-PnL open position keeps a dust value so the position stays valued and the
    ///  app bit cannot be purged while a position is open.
    function testGetLighterBalancesDustWithZeroPnlOpenPosition() public {
        _track(1);
        // Market 1 (BTC-PERP): size_decimals 5 + price_decimals 1; mark 500_0000 → a 100-unit
        //  position is worth 100 * 5_000_000 * 1e6 / 10^6 = 500_000_000; entry notional set equal.
        LighterTypes.Position memory position = _position(100, 0, 0);
        position.entryQuote = 500_000_000;
        _mockPosition(ACCOUNT, 1, position);

        AppTokenBalance[] memory balances = harness.getLighterBalances(ACCOUNT);
        assertEq(balances.length, 1);
        assertEq(balances[0].amount, 1, "Zero-PnL open position keeps the dust value");
    }

    /// @notice A negative total is returned as-is: the liability stays in NAV, the list stays
    ///  non-empty and the app cannot be purged while the pool owes money (mirrors
    ///  HyperliquidLib's sign handling).
    function testGetLighterBalancesNegativeTotalReturnedAsIs() public {
        _track(1);
        _mockMarketInfoWithPrice(1, 510_0000);
        // 100-unit short on market 1 (5+1 decimals): entry notional 500_000_000, mark value
        //  100 * 5_100_000 * 1e6 / 10^6 = 510_000_000 → PnL -10_000_000; zero collateral.
        LighterTypes.Position memory position = _position(-100, 0, 0);
        position.entryQuote = 500_000_000;
        _mockPosition(ACCOUNT, 1, position);

        AppTokenBalance[] memory balances = harness.getLighterBalances(ACCOUNT);
        assertEq(balances.length, 1, "A negative liability keeps the list non-empty");
        assertEq(balances[0].amount, -10_000_000, "Negative total must be returned as-is");
    }

    function testReadTxStatusDirectRead() public {
        vm.mockCall(
            READ_CORE,
            abi.encodePacked(LighterLib._SELECTOR_TX_STATUS, uint64(7)),
            abi.encode(uint8(2), bytes(""))
        );
        assertEq(harness.readTxStatus(7), 2);
    }

    function testReadTxStatusRevertsOnFailure() public {
        vm.mockCallRevert(READ_CORE, abi.encodePacked(LighterLib._SELECTOR_TX_STATUS, uint64(7)), "");
        vm.expectRevert(LighterLib.LighterReadFailed.selector);
        harness.readTxStatus(7);
    }

    // =========================================================================
    // Struct builders and tracking helpers
    // =========================================================================

    function _accountInfo(int128 collateral) internal pure returns (LighterTypes.AccountInfo memory) {
        return
            LighterTypes.AccountInfo({
                accountType: 0,
                accountIndex: 0,
                masterAccountIndex: 0,
                l1Address: address(0),
                evmAddress: address(0),
                collateralBaseAmount: collateral
            });
    }

    function _position(
        int64 positionSize,
        uint64 totalOrderCount,
        uint64 totalPositionTiedOrderCount
    ) internal pure returns (LighterTypes.Position memory) {
        return
            LighterTypes.Position({
                size: positionSize,
                entryQuote: 0,
                initialMarginFraction: 0,
                totalOrderCount: totalOrderCount,
                totalPositionTiedOrderCount: totalPositionTiedOrderCount,
                marginMode: 0,
                allocatedMargin: 0
            });
    }

    function _track(uint16 marketId) internal {
        // Perps carry quoteAssetId == 0 on Core (docs + live devnet verification): marketType == 0
        // is the USDC-settlement guarantee, so tracking must succeed with quoteAssetId 0. The
        // decimal scales come from the LighterConstants table (markets 0-3), never from calldata.
        _mockMarketInfo(marketId, 0, 0);
        harness.trackMarket(marketId);
    }

    // =========================================================================
    // trackMarket validation
    // =========================================================================

    function testTrackDuplicateIsSilentNoOp() public {
        _track(1);
        _mockMarketInfo(1, 0, 0);
        harness.trackMarket(1);
        assertEq(harness.trackedMarkets().length, 1);
        assertGt(harness.marketIndex(1), 0);
    }

    /// @notice Markets absent from the LighterConstants release-time decimals table can never be
    ///  tracked: the decimal scales are protocol constants, so an unknown id reverts before any
    ///  Core read.
    function testUnknownMarketReverts() public {
        vm.expectRevert(abi.encodeWithSelector(UnknownMarket.selector, uint16(9)));
        harness.trackMarket(9);
    }

    function testNonPerpMarketReverts() public {
        _mockMarketInfo(1, 1, LighterConstants.USDC_ASSET_INDEX);
        vm.expectRevert(LighterLib.InvalidMarket.selector);
        harness.trackMarket(1);
    }

    /// @notice A market absent from Core reports found=false and reverts LighterReadFailed.
    function testNonexistentMarketRevertsReadFailed() public {
        vm.mockCall(READ_CORE, abi.encodePacked(LighterLib._SELECTOR_MARKET_INFO, uint16(1)), _notFound());
        vm.expectRevert(LighterLib.LighterReadFailed.selector);
        harness.trackMarket(1);
    }

    /// @notice Perps are USDC-settled by protocol design; Core reports quoteAssetId == 0 for
    ///  perpetuals (docs + live devnet verification), and that layout must track successfully.
    function testPerpTracksWithZeroQuoteAssetId() public {
        _track(1);
        assertGt(harness.marketIndex(1), 0);
    }

    // =========================================================================
    // NAV-loop pruning of stale tracked markets (getLighterBalances is state-changing)
    // =========================================================================

    /// @dev Seeds MAX_TRACKED_MARKETS entries directly (bypassing the 4-entry decimals table)
    ///  and reports found=false for every position read of `account`: a not-found read is a
    ///  zeroed position, i.e. an empty (stale) market.
    function _seedFullRegistry(address account) internal {
        for (uint256 i; i < LighterConstants.MAX_TRACKED_MARKETS; ++i) {
            uint16 marketId = 100 + uint16(i);
            harness.seedTrackedMarket(marketId, 4, 2);
            _mockPositionNotFound(account, marketId);
        }
        assertEq(harness.trackedMarkets().length, LighterConstants.MAX_TRACKED_MARKETS);
    }

    /// @notice The NAV loop prunes a tracked market that holds no position and no orders, and a
    ///  fully pruned registry with zero collateral and no in-flight returns the purgeable empty
    ///  list.
    function testNavLoopPrunesStaleMarket() public {
        _track(1);
        _mockPosition(ACCOUNT, 1, _position(0, 0, 0));

        AppTokenBalance[] memory balances = harness.getLighterBalances(ACCOUNT);

        assertEq(balances.length, 0, "Zero collateral and no active market: purgeable empty list");
        assertEq(harness.trackedMarkets().length, 0, "Stale market must be pruned by the NAV loop");
        assertEq(harness.marketIndex(1), 0);
    }

    /// @notice Markets holding an open position or open orders (including position-tied ones)
    ///  survive the NAV loop, and swap-pop keeps the survivors' 1-based indices consistent.
    function testNavLoopPreservesMarketsWithPositionOrOrders() public {
        _seedFullRegistry(ACCOUNT);
        _mockPosition(ACCOUNT, 105, _position(100, 0, 0));
        _mockPosition(ACCOUNT, 110, _position(0, 1, 0));
        _mockPosition(ACCOUNT, 115, _position(0, 0, 1));
        _mockMarketInfoWithPrice(105, 500_0000);

        AppTokenBalance[] memory balances = harness.getLighterBalances(ACCOUNT);

        assertEq(balances.length, 1, "A surviving position keeps the list non-empty");
        uint16[] memory markets = harness.trackedMarkets();
        assertEq(markets.length, 3);
        uint16[3] memory survivors = [uint16(105), 110, 115];
        for (uint256 i; i < survivors.length; ++i) {
            uint256 index = harness.marketIndex(survivors[i]);
            assertGt(index, 0, "Stateful market must survive the NAV loop");
            assertEq(markets[index - 1], survivors[i], "Survivor index must point at the market");
        }
        assertEq(harness.marketIndex(100), 0);
    }

    /// @notice trackMarket no longer sweeps at the cap: with the registry full of stale entries,
    ///  tracking a new market reverts until a NAV-evaluating call prunes them.
    function testTrackAtCapRevertsWithoutSweeping() public {
        _seedFullRegistry(ACCOUNT);

        _mockMarketInfo(1, 0, 0);
        vm.expectRevert(LighterLib.MaxTrackedMarketsReached.selector);
        harness.trackMarket(1);

        assertEq(harness.trackedMarkets().length, LighterConstants.MAX_TRACKED_MARKETS);
        assertEq(harness.marketIndex(1), 0, "New market must not be tracked while the cap holds");
    }

    /// @notice A NAV-evaluating call prunes the stale registry, so tracking succeeds afterwards.
    function testTrackSucceedsAtCapAfterNavLoopPruned() public {
        _seedFullRegistry(ACCOUNT);

        harness.getLighterBalances(ACCOUNT);
        assertEq(harness.trackedMarkets().length, 0, "NAV loop must prune the stale registry");

        _mockMarketInfo(1, 0, 0);
        harness.trackMarket(1);
        uint16[] memory markets = harness.trackedMarkets();
        assertEq(markets.length, 1);
        assertEq(markets[0], 1);
    }
}
