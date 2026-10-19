// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {LighterLib} from "../../contracts/protocol/libraries/LighterLib.sol";
import {LighterTypes} from "../../contracts/protocol/extensions/adapters/interfaces/lighter/LighterTypes.sol";
import {StorageLib} from "../../contracts/protocol/libraries/StorageLib.sol";
import {LighterConstants} from "../../contracts/protocol/types/LighterConstants.sol";

/// @notice Exposes LighterLib market-tracking internals for unit testing.
contract LighterLibMarketHarness {
    function trackMarket(uint16 marketId, uint8 sizeDecimals, uint8 priceDecimals) external {
        LighterLib.trackMarket(marketId, sizeDecimals, priceDecimals);
    }

    function untrackMarket(uint16 marketId) external {
        LighterLib.untrackMarket(marketId);
    }

    function isTrackedMarket(uint16 marketId) external view returns (bool) {
        return LighterLib.isTrackedMarket(marketId);
    }

    function trackedMarkets() external view returns (uint16[] memory) {
        return StorageLib.lighterSlot().trackedMarkets;
    }
}

/// @title LighterLibTest
/// @notice Non-fork unit tests for LighterLib's tracked-market registry: validation, swap-remove
///  bookkeeping and the tracking cap.
contract LighterLibTest is Test {
    LighterLibMarketHarness internal harness;

    address internal constant READ_CORE = LighterConstants.READ_CORE;

    function setUp() public {
        harness = new LighterLibMarketHarness();
    }

    function _mockMarketInfo(uint16 marketId, uint8 marketType, uint32 quoteAssetId) private {
        // Every read except 0x0000 returns abi.encode(bool found, bytes data) per the Lighter docs.
        vm.mockCall(
            READ_CORE,
            abi.encodePacked(LighterLib._SELECTOR_MARKET_INFO, marketId),
            abi.encode(
                true,
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

    function _track(uint16 marketId) internal {
        // Perps carry quoteAssetId == 0 on Core (docs + live devnet verification): marketType == 0
        // is the USDC-settlement guarantee, so tracking must succeed with quoteAssetId 0.
        _mockMarketInfo(marketId, 0, 0);
        harness.trackMarket(marketId, 2, 4);
    }

    function testSwapRemoveMiddleKeepsOrderAndIndices() public {
        _track(1);
        _track(2);
        _track(3);

        harness.untrackMarket(2);

        uint16[] memory markets = harness.trackedMarkets();
        assertEq(markets.length, 2);
        assertEq(markets[0], 1);
        assertEq(markets[1], 3);
        assertTrue(harness.isTrackedMarket(1));
        assertTrue(harness.isTrackedMarket(3));
        assertFalse(harness.isTrackedMarket(2));
    }

    function testSwapRemoveFirstMovesLastIntoPlace() public {
        _track(1);
        _track(2);
        _track(3);

        harness.untrackMarket(1);

        uint16[] memory markets = harness.trackedMarkets();
        assertEq(markets.length, 2);
        assertEq(markets[0], 3);
        assertEq(markets[1], 2);
        assertTrue(harness.isTrackedMarket(2));
        assertTrue(harness.isTrackedMarket(3));
        assertFalse(harness.isTrackedMarket(1));
    }

    function testSwapRemoveLastIsPlainPop() public {
        _track(1);
        _track(2);
        _track(3);

        harness.untrackMarket(3);

        uint16[] memory markets = harness.trackedMarkets();
        assertEq(markets.length, 2);
        assertEq(markets[0], 1);
        assertEq(markets[1], 2);
        assertTrue(harness.isTrackedMarket(1));
        assertTrue(harness.isTrackedMarket(2));
        assertFalse(harness.isTrackedMarket(3));
    }

    function testUntrackAllSequentiallyEmptiesRegistry() public {
        _track(1);
        _track(2);
        _track(3);

        harness.untrackMarket(3);
        harness.untrackMarket(2);
        harness.untrackMarket(1);

        assertEq(harness.trackedMarkets().length, 0);
        assertFalse(harness.isTrackedMarket(1));
        assertFalse(harness.isTrackedMarket(2));
        assertFalse(harness.isTrackedMarket(3));

        // Re-untracking an already removed market reverts.
        vm.expectRevert(LighterLib.MarketNotTracked.selector);
        harness.untrackMarket(1);
    }

    function testTrackDuplicateReverts() public {
        _track(1);

        _mockMarketInfo(1, 0, 0);
        vm.expectRevert(LighterLib.MarketAlreadyTracked.selector);
        harness.trackMarket(1, 2, 4);
    }

    function testUntrackUnknownReverts() public {
        vm.expectRevert(LighterLib.MarketNotTracked.selector);
        harness.untrackMarket(9);
    }

    function testCapRevertsAboveMaxTrackedMarkets() public {
        for (uint256 i; i < LighterConstants.MAX_TRACKED_MARKETS; ++i) {
            _track(uint16(100 + i));
        }
        assertEq(harness.trackedMarkets().length, LighterConstants.MAX_TRACKED_MARKETS);

        // All 32 slots are full: the 33rd valid market reverts.
        _mockMarketInfo(200, 0, 0);
        vm.expectRevert(LighterLib.MaxTrackedMarketsReached.selector);
        harness.trackMarket(200, 2, 4);

        // The failed attempt must not have corrupted the registry.
        assertEq(harness.trackedMarkets().length, LighterConstants.MAX_TRACKED_MARKETS);
    }

    function testInvalidDecimalsRevert() public {
        _mockMarketInfo(1, 0, 0);

        vm.expectRevert(LighterLib.InvalidMarketDecimals.selector);
        harness.trackMarket(1, 19, 4);

        vm.expectRevert(LighterLib.InvalidMarketDecimals.selector);
        harness.trackMarket(1, 2, 17);
    }

    function testNonPerpMarketReverts() public {
        _mockMarketInfo(1, 1, LighterConstants.USDC_ASSET_INDEX);
        vm.expectRevert(LighterLib.InvalidMarket.selector);
        harness.trackMarket(1, 2, 4);
    }

    /// @notice Perps are USDC-settled by protocol design; Core reports quoteAssetId == 0 for
    ///  perpetuals (docs + live devnet verification), and that layout must track successfully.
    function testPerpTracksWithZeroQuoteAssetId() public {
        _track(1);
        assertTrue(harness.isTrackedMarket(1));
    }
}
