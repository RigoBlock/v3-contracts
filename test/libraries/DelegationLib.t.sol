// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DelegationData, DelegationLib} from "../../contracts/protocol/libraries/DelegationLib.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Harness
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Exposes DelegationLib mutations through a concrete storage struct.
///      Restricts the test universe to 4 selectors × 4 addresses so Foundry's
///      bounded invariant engine can explore all states exhaustively.
contract DelegationHarness {
    using DelegationLib for DelegationData;

    DelegationData internal _d;

    // Bounded universe keeps invariant depth manageable
    bytes4[4] public selectors = [bytes4(0xaabbccdd), bytes4(0x11223344), bytes4(0x55667788), bytes4(0x99aabbcc)];
    address[4] public addrs;

    constructor() {
        addrs[0] = address(0x1111);
        addrs[1] = address(0x2222);
        addrs[2] = address(0x3333);
        addrs[3] = address(0x4444);
    }

    function add(uint8 si, uint8 ai) external returns (bool) {
        return _d.add(selectors[si % 4], addrs[ai % 4]);
    }

    function remove(uint8 si, uint8 ai) external returns (bool) {
        return _d.remove(selectors[si % 4], addrs[ai % 4]);
    }

    function removeAllByAddress(uint8 ai) external {
        _d.removeAllByAddress(addrs[ai % 4]);
    }

    function removeAllBySelector(uint8 si) external {
        _d.removeAllBySelector(selectors[si % 4]);
    }

    // ── View proxies for invariant assertions ──────────────────────────────

    function selectorAddressesLength(uint8 si) external view returns (uint256) {
        return _d.selectorAddresses[selectors[si % 4]].length;
    }

    function selectorAddressAt(uint8 si, uint256 i) external view returns (address) {
        return _d.selectorAddresses[selectors[si % 4]][i];
    }

    function addressSelectorsLength(uint8 ai) external view returns (uint256) {
        return _d.addressSelectors[addrs[ai % 4]].length;
    }

    function addressSelectorAt(uint8 ai, uint256 i) external view returns (bytes4) {
        return _d.addressSelectors[addrs[ai % 4]][i];
    }

    function positionInSelector(uint8 si, uint8 ai) external view returns (uint256) {
        return _d.selectorToAddressPosition[selectors[si % 4]][addrs[ai % 4]];
    }

    function positionInAddr(uint8 ai, uint8 si) external view returns (uint256) {
        return _d.addressToSelectorPosition[addrs[ai % 4]][selectors[si % 4]];
    }

    // Counts how many addresses in the bounded universe are delegated to a given selector
    function countDelegatedAddrs(uint8 si) external view returns (uint256 count) {
        bytes4 sel = selectors[si % 4];
        for (uint256 j = 0; j < 4; j++) {
            if (_d.selectorToAddressPosition[sel][addrs[j]] != 0) count++;
        }
    }

    // Counts how many selectors in the bounded universe are delegated to a given address
    function countDelegatedSelectors(uint8 ai) external view returns (uint256 count) {
        address addr = addrs[ai % 4];
        for (uint256 j = 0; j < 4; j++) {
            if (_d.addressToSelectorPosition[addr][selectors[j]] != 0) count++;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests
// ─────────────────────────────────────────────────────────────────────────────

contract DelegationLibTest is Test {
    using DelegationLib for DelegationData;

    DelegationData internal d;

    bytes4 constant SEL1 = bytes4(0xaabbccdd);
    bytes4 constant SEL2 = bytes4(0x11223344);
    address constant ADDR1 = address(0x1111);
    address constant ADDR2 = address(0x2222);

    // ── add ───────────────────────────────────────────────────────────────

    function test_add_ReturnsTrueOnFirstAdd() public {
        assertTrue(d.add(SEL1, ADDR1));
    }

    function test_add_ReturnsFalseOnDuplicate() public {
        d.add(SEL1, ADDR1);
        assertFalse(d.add(SEL1, ADDR1));
    }

    function test_add_SelectorAddressesGrows() public {
        d.add(SEL1, ADDR1);
        assertEq(d.selectorAddresses[SEL1].length, 1);
        assertEq(d.selectorAddresses[SEL1][0], ADDR1);
    }

    function test_add_AddressSelectorsGrows() public {
        d.add(SEL1, ADDR1);
        assertEq(d.addressSelectors[ADDR1].length, 1);
        assertEq(d.addressSelectors[ADDR1][0], SEL1);
    }

    function test_add_PositionIsOneIndexed() public {
        d.add(SEL1, ADDR1);
        assertEq(d.selectorToAddressPosition[SEL1][ADDR1], 1);
        assertEq(d.addressToSelectorPosition[ADDR1][SEL1], 1);
    }

    function test_add_MultipleAddrsForSameSelector() public {
        d.add(SEL1, ADDR1);
        d.add(SEL1, ADDR2);
        assertEq(d.selectorAddresses[SEL1].length, 2);
        assertEq(d.selectorToAddressPosition[SEL1][ADDR1], 1);
        assertEq(d.selectorToAddressPosition[SEL1][ADDR2], 2);
    }

    function test_add_MultipleSelectorsForSameAddr() public {
        d.add(SEL1, ADDR1);
        d.add(SEL2, ADDR1);
        assertEq(d.addressSelectors[ADDR1].length, 2);
        assertEq(d.addressToSelectorPosition[ADDR1][SEL1], 1);
        assertEq(d.addressToSelectorPosition[ADDR1][SEL2], 2);
    }

    // ── remove ────────────────────────────────────────────────────────────

    function test_remove_ReturnsFalseWhenNotPresent() public {
        assertFalse(d.remove(SEL1, ADDR1));
    }

    function test_remove_ReturnsTrueWhenPresent() public {
        d.add(SEL1, ADDR1);
        assertTrue(d.remove(SEL1, ADDR1));
    }

    function test_remove_ClearsPosition() public {
        d.add(SEL1, ADDR1);
        d.remove(SEL1, ADDR1);
        assertEq(d.selectorToAddressPosition[SEL1][ADDR1], 0);
        assertEq(d.addressToSelectorPosition[ADDR1][SEL1], 0);
    }

    function test_remove_SelectorAddressesShrinks() public {
        d.add(SEL1, ADDR1);
        d.remove(SEL1, ADDR1);
        assertEq(d.selectorAddresses[SEL1].length, 0);
    }

    function test_remove_AddressSelectorsShrinks() public {
        d.add(SEL1, ADDR1);
        d.remove(SEL1, ADDR1);
        assertEq(d.addressSelectors[ADDR1].length, 0);
    }

    function test_remove_SwapsLastElementCorrectly() public {
        // ADDR1 at index 0, ADDR2 at index 1; remove ADDR1 → ADDR2 moves to index 0
        d.add(SEL1, ADDR1);
        d.add(SEL1, ADDR2);
        d.remove(SEL1, ADDR1);

        assertEq(d.selectorAddresses[SEL1].length, 1);
        assertEq(d.selectorAddresses[SEL1][0], ADDR2);
        assertEq(d.selectorToAddressPosition[SEL1][ADDR2], 1);
    }

    function test_remove_IsIdempotentAfterRemoval() public {
        d.add(SEL1, ADDR1);
        d.remove(SEL1, ADDR1);
        assertFalse(d.remove(SEL1, ADDR1)); // second remove is a no-op
        assertEq(d.selectorAddresses[SEL1].length, 0);
    }

    function test_remove_CanReAddAfterRemove() public {
        d.add(SEL1, ADDR1);
        d.remove(SEL1, ADDR1);
        assertTrue(d.add(SEL1, ADDR1));
        assertEq(d.selectorToAddressPosition[SEL1][ADDR1], 1);
    }

    // ── removeAllByAddress ────────────────────────────────────────────────

    function test_removeAllByAddress_ClearsAddressSelectors() public {
        d.add(SEL1, ADDR1);
        d.add(SEL2, ADDR1);
        d.removeAllByAddress(ADDR1);
        assertEq(d.addressSelectors[ADDR1].length, 0);
    }

    function test_removeAllByAddress_ClearsAllSelectorSides() public {
        d.add(SEL1, ADDR1);
        d.add(SEL2, ADDR1);
        d.removeAllByAddress(ADDR1);
        assertEq(d.selectorAddresses[SEL1].length, 0);
        assertEq(d.selectorAddresses[SEL2].length, 0);
    }

    function test_removeAllByAddress_OnlyAffectsTargetAddress() public {
        d.add(SEL1, ADDR1);
        d.add(SEL1, ADDR2);
        d.removeAllByAddress(ADDR1);
        // ADDR2 entry for SEL1 should survive
        assertEq(d.selectorAddresses[SEL1].length, 1);
        assertEq(d.selectorAddresses[SEL1][0], ADDR2);
        assertEq(d.selectorToAddressPosition[SEL1][ADDR2], 1);
    }

    function test_removeAllByAddress_NoOpOnEmptyAddress() public {
        d.removeAllByAddress(ADDR1); // must not revert
    }

    // ── removeAllBySelector ───────────────────────────────────────────────

    function test_removeAllBySelector_ClearsSelectorAddresses() public {
        d.add(SEL1, ADDR1);
        d.add(SEL1, ADDR2);
        d.removeAllBySelector(SEL1);
        assertEq(d.selectorAddresses[SEL1].length, 0);
    }

    function test_removeAllBySelector_ClearsAllAddressSides() public {
        d.add(SEL1, ADDR1);
        d.add(SEL1, ADDR2);
        d.removeAllBySelector(SEL1);
        assertEq(d.addressSelectors[ADDR1].length, 0);
        assertEq(d.addressSelectors[ADDR2].length, 0);
    }

    function test_removeAllBySelector_OnlyAffectsTargetSelector() public {
        d.add(SEL1, ADDR1);
        d.add(SEL2, ADDR1);
        d.removeAllBySelector(SEL1);
        // SEL2 delegation for ADDR1 should survive
        assertEq(d.addressSelectors[ADDR1].length, 1);
        assertEq(d.addressSelectors[ADDR1][0], SEL2);
        assertEq(d.addressToSelectorPosition[ADDR1][SEL2], 1);
    }

    function test_removeAllBySelector_NoOpOnEmptySelector() public {
        d.removeAllBySelector(SEL1); // must not revert
    }

    // ── getAddresses / getSelectors ───────────────────────────────────────

    function test_getAddresses_ReturnsEmptyWhenNone() public view {
        assertEq(d.getAddresses(SEL1).length, 0);
    }

    function test_getAddresses_ReturnsCorrectEntries() public {
        d.add(SEL1, ADDR1);
        d.add(SEL1, ADDR2);
        address[] memory got = d.getAddresses(SEL1);
        assertEq(got.length, 2);
        assertEq(got[0], ADDR1);
        assertEq(got[1], ADDR2);
    }

    function test_getSelectors_ReturnsEmptyWhenNone() public view {
        assertEq(d.getSelectors(ADDR1).length, 0);
    }

    function test_getSelectors_ReturnsCorrectEntries() public {
        d.add(SEL1, ADDR1);
        d.add(SEL2, ADDR1);
        bytes4[] memory got = d.getSelectors(ADDR1);
        assertEq(got.length, 2);
        assertEq(got[0], SEL1);
        assertEq(got[1], SEL2);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Fuzz tests
// ─────────────────────────────────────────────────────────────────────────────

contract DelegationLibFuzz is Test {
    using DelegationLib for DelegationData;

    DelegationData internal d;

    /// @dev add then remove always clears both position maps
    function testFuzz_addThenRemove_ClearsState(bytes4 sel, address addr) public {
        d.add(sel, addr);
        d.remove(sel, addr);
        assertEq(d.selectorToAddressPosition[sel][addr], 0);
        assertEq(d.addressToSelectorPosition[addr][sel], 0);
        assertEq(d.selectorAddresses[sel].length, 0);
        assertEq(d.addressSelectors[addr].length, 0);
    }

    /// @dev add is idempotent: repeated calls must not grow the arrays
    function testFuzz_add_Idempotent(bytes4 sel, address addr) public {
        d.add(sel, addr);
        uint256 lenSel = d.selectorAddresses[sel].length;
        uint256 lenAddr = d.addressSelectors[addr].length;
        d.add(sel, addr);
        assertEq(d.selectorAddresses[sel].length, lenSel);
        assertEq(d.addressSelectors[addr].length, lenAddr);
    }

    /// @dev remove is idempotent: repeated calls on absent pair stay length 0
    function testFuzz_remove_Idempotent(bytes4 sel, address addr) public {
        d.remove(sel, addr);
        assertEq(d.selectorToAddressPosition[sel][addr], 0);
        d.remove(sel, addr); // no revert
        assertEq(d.selectorToAddressPosition[sel][addr], 0);
    }

    /// @dev position map is consistent with array content (single entry)
    function testFuzz_position_ConsistentWithArray(bytes4 sel, address addr) public {
        d.add(sel, addr);
        uint256 pos = d.selectorToAddressPosition[sel][addr];
        assertGt(pos, 0);
        assertEq(d.selectorAddresses[sel][pos - 1], addr);
    }

    /// @dev bidirectional: after add, addr is in selectorAddresses iff sel is in addressSelectors
    function testFuzz_biDirectional_AfterAdd(bytes4 sel, address addr) public {
        d.add(sel, addr);
        // sel-side has addr
        bool foundAddr;
        for (uint256 i = 0; i < d.selectorAddresses[sel].length; i++) {
            if (d.selectorAddresses[sel][i] == addr) { foundAddr = true; break; }
        }
        // addr-side has sel
        bool foundSel;
        for (uint256 i = 0; i < d.addressSelectors[addr].length; i++) {
            if (d.addressSelectors[addr][i] == sel) { foundSel = true; break; }
        }
        assertEq(foundAddr, foundSel);
        assertTrue(foundAddr);
    }

    /// @dev bidirectional: after remove, neither side contains the pair
    function testFuzz_biDirectional_AfterRemove(bytes4 sel, address addr) public {
        d.add(sel, addr);
        d.remove(sel, addr);
        for (uint256 i = 0; i < d.selectorAddresses[sel].length; i++) {
            assertNotEq(d.selectorAddresses[sel][i], addr);
        }
        for (uint256 i = 0; i < d.addressSelectors[addr].length; i++) {
            assertNotEq(d.addressSelectors[addr][i], sel);
        }
    }

    /// @dev swap-and-pop preserves validity of surviving entry when removing first of two
    function testFuzz_swapAndPop_PreservesSecondEntry(bytes4 sel, address first, address second) public {
        vm.assume(first != second);
        d.add(sel, first);
        d.add(sel, second);
        d.remove(sel, first);
        // second must still be accessible
        assertEq(d.selectorAddresses[sel].length, 1);
        assertEq(d.selectorToAddressPosition[sel][second], 1);
        assertEq(d.selectorAddresses[sel][0], second);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Invariant tests
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Structural invariants that must hold after any sequence of mutations.
/// @dev Foundry calls the harness methods in random order to explore the state space.
contract DelegationLibInvariant is Test {
    DelegationHarness internal harness;

    function setUp() public {
        harness = new DelegationHarness();
        // Drive mutations through the harness so storage is populated
        targetContract(address(harness));
        // Restrict to the harness mutation functions only (not view functions)
        bytes4[] memory selectors_ = new bytes4[](4);
        selectors_[0] = DelegationHarness.add.selector;
        selectors_[1] = DelegationHarness.remove.selector;
        selectors_[2] = DelegationHarness.removeAllByAddress.selector;
        selectors_[3] = DelegationHarness.removeAllBySelector.selector;
        targetSelector(FuzzSelector({ addr: address(harness), selectors: selectors_ }));
    }

    /// @notice For every entry in selectorAddresses[sel], the position map must point back to it.
    function invariant_selectorAddressesPositionConsistency() public view {
        for (uint8 si = 0; si < 4; si++) {
            uint256 len = harness.selectorAddressesLength(si);
            for (uint256 i = 0; i < len; i++) {
                address addr = harness.selectorAddressAt(si, i);
                // Find which ai corresponds to this addr
                for (uint8 ai = 0; ai < 4; ai++) {
                    if (harness.addrs(ai) == addr) {
                        assertEq(harness.positionInSelector(si, ai), i + 1,
                            "position map must equal 1-indexed array position");
                        break;
                    }
                }
            }
        }
    }

    /// @notice For every entry in addressSelectors[addr], the position map must point back to it.
    function invariant_addressSelectorsPositionConsistency() public view {
        for (uint8 ai = 0; ai < 4; ai++) {
            uint256 len = harness.addressSelectorsLength(ai);
            for (uint256 i = 0; i < len; i++) {
                bytes4 sel = harness.addressSelectorAt(ai, i);
                for (uint8 si = 0; si < 4; si++) {
                    if (harness.selectors(si) == sel) {
                        assertEq(harness.positionInAddr(ai, si), i + 1,
                            "position map must equal 1-indexed array position");
                        break;
                    }
                }
            }
        }
    }

    /// @notice The count of delegated addresses for a selector must equal selectorAddresses[sel].length.
    function invariant_selectorArrayLengthMatchesPositionMapCount() public view {
        for (uint8 si = 0; si < 4; si++) {
            assertEq(
                harness.selectorAddressesLength(si),
                harness.countDelegatedAddrs(si),
                "array length must match non-zero position count"
            );
        }
    }

    /// @notice The count of delegated selectors for an address must equal addressSelectors[addr].length.
    function invariant_addressArrayLengthMatchesPositionMapCount() public view {
        for (uint8 ai = 0; ai < 4; ai++) {
            assertEq(
                harness.addressSelectorsLength(ai),
                harness.countDelegatedSelectors(ai),
                "array length must match non-zero position count"
            );
        }
    }

    /// @notice Bidirectional sync: addr in selectorAddresses[sel] iff sel in addressSelectors[addr].
    function invariant_biDirectionalSync() public view {
        for (uint8 si = 0; si < 4; si++) {
            for (uint8 ai = 0; ai < 4; ai++) {
                bool inSelArr = harness.positionInSelector(si, ai) != 0;
                bool inAddrArr = harness.positionInAddr(ai, si) != 0;
                assertEq(inSelArr, inAddrArr, "selector and address directions must be in sync");
            }
        }
    }

    /// @notice No duplicate entries in selectorAddresses arrays.
    function invariant_noDuplicatesInSelectorArrays() public view {
        for (uint8 si = 0; si < 4; si++) {
            uint256 len = harness.selectorAddressesLength(si);
            for (uint256 i = 0; i < len; i++) {
                for (uint256 j = i + 1; j < len; j++) {
                    assertNotEq(
                        harness.selectorAddressAt(si, i),
                        harness.selectorAddressAt(si, j),
                        "duplicate address in selectorAddresses"
                    );
                }
            }
        }
    }

    /// @notice No duplicate entries in addressSelectors arrays.
    function invariant_noDuplicatesInAddressArrays() public view {
        for (uint8 ai = 0; ai < 4; ai++) {
            uint256 len = harness.addressSelectorsLength(ai);
            for (uint256 i = 0; i < len; i++) {
                for (uint256 j = i + 1; j < len; j++) {
                    assertNotEq(
                        harness.addressSelectorAt(ai, i),
                        harness.addressSelectorAt(ai, j),
                        "duplicate selector in addressSelectors"
                    );
                }
            }
        }
    }
}
