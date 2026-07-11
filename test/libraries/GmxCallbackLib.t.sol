// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { GmxCallbackLib } from "../../contracts/protocol/libraries/GmxCallbackLib.sol";
import { Bytes32Set, EnumerableSet } from "../../contracts/protocol/libraries/EnumerableSet.sol";

/// @dev Harness to exercise GmxCallbackLib internal helpers.
contract GmxCallbackLibHarness {
    using EnumerableSet for Bytes32Set;

    function addTrackedMarket(address market) external {
        GmxCallbackLib.addTrackedMarket(market);
    }

    function removeTrackedMarket(address market) external {
        GmxCallbackLib.removeTrackedMarket(market);
    }

    function containsTrackedMarket(address market) external view returns (bool) {
        return GmxCallbackLib.containsTrackedMarket(market);
    }

    function trackedMarketsCount() external view returns (uint256) {
        return GmxCallbackLib.trackedMarketsCount();
    }

    function trackedMarketAt(uint256 index) external view returns (address) {
        return GmxCallbackLib.trackedMarketAt(index);
    }

    function removeClaimableCollateralKey(bytes32 key) external {
        GmxCallbackLib.removeClaimableCollateralKey(key);
    }
}

/// @title GmxCallbackLibTest
/// @notice Non-fork unit tests for GmxCallbackLib storage helpers.
contract GmxCallbackLibTest is Test {
    using EnumerableSet for Bytes32Set;

    GmxCallbackLibHarness internal harness;

    function setUp() public {
        harness = new GmxCallbackLibHarness();
    }

    function test_TrackedMarket_AddContainsCountAtRemove() public {
        address market1 = address(0x1111);
        address market2 = address(0x2222);

        assertEq(harness.trackedMarketsCount(), 0);
        assertFalse(harness.containsTrackedMarket(market1));

        harness.addTrackedMarket(market1);
        assertEq(harness.trackedMarketsCount(), 1);
        assertTrue(harness.containsTrackedMarket(market1));
        assertEq(harness.trackedMarketAt(0), market1);

        harness.addTrackedMarket(market1); // idempotent
        assertEq(harness.trackedMarketsCount(), 1);

        harness.addTrackedMarket(market2);
        assertEq(harness.trackedMarketsCount(), 2);
        assertEq(harness.trackedMarketAt(1), market2);

        harness.removeTrackedMarket(market1);
        assertEq(harness.trackedMarketsCount(), 1);
        assertFalse(harness.containsTrackedMarket(market1));
        assertEq(harness.trackedMarketAt(0), market2);

        harness.removeTrackedMarket(market2);
        assertEq(harness.trackedMarketsCount(), 0);
    }

    function test_RemoveClaimableCollateralKey_NonExistent() public {
        bytes32 key = bytes32(uint256(0xabc));
        // Removing a non-recorded key is a no-op and should not revert.
        harness.removeClaimableCollateralKey(key);
    }

    function test_RemoveClaimableCollateralKey_ExistingKey() public {
        bytes32 key = bytes32(uint256(0xabc));

        // Populate callback storage directly in this test contract, then remove it
        // directly so the storage context matches.
        GmxCallbackLib.GmxCallbackSlot storage cb = GmxCallbackLib.gmxCallbackData();
        cb.claimableCollateralKeys.add(key);
        cb.claimableCollateralInfo[key] =
            GmxCallbackLib.ClaimableCollateralInfo({ token: address(0x1111), market: address(0x2222), timeKey: 1 });

        GmxCallbackLib.removeClaimableCollateralKey(key);

        assertFalse(cb.claimableCollateralKeys.contains(key));
    }
}
