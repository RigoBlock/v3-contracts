// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { EnumerableSet, AddressSet, Bytes32Set } from "../../contracts/protocol/libraries/EnumerableSet.sol";
import { IEOracle } from "../../contracts/protocol/extensions/adapters/interfaces/IEOracle.sol";

/// @dev Harness for exercising EnumerableSet internal helpers in a non-fork unit test.
contract EnumerableSetHarness {
    using EnumerableSet for AddressSet;
    using EnumerableSet for Bytes32Set;

    AddressSet internal addressSet;
    Bytes32Set internal bytes32Set;

    function addAndCheckWasActive(address eOracle, address token, address baseToken) external returns (bool) {
        return addressSet.addAndCheckWasActive(IEOracle(eOracle), token, baseToken);
    }

    function addUnique(address eOracle, address token, address baseToken) external {
        addressSet.addUnique(IEOracle(eOracle), token, baseToken);
    }

    function containsAddress(address token) external view returns (bool) {
        return addressSet.isActive(token);
    }

    function removeAddress(address token) external {
        addressSet.remove(token);
    }

    function addBytes32(bytes32 value) external {
        bytes32Set.add(value);
    }

    function removeBytes32(bytes32 value) external {
        bytes32Set.remove(value);
    }

    function containsBytes32(bytes32 value) external view returns (bool) {
        return bytes32Set.contains(value);
    }

    function lengthBytes32() external view returns (uint256) {
        return bytes32Set.length();
    }

    function atBytes32(uint256 index) external view returns (bytes32) {
        return bytes32Set.at(index);
    }
}

/// @title EnumerableSetTest
/// @notice Non-fork unit tests for the EnumerableSet library additions.
contract EnumerableSetTest is Test {
    EnumerableSetHarness internal harness;
    address internal constant BASE_TOKEN = address(0x1000);
    address internal constant TOKEN = address(0x2000);
    address internal eOracle;

    function setUp() public {
        harness = new EnumerableSetHarness();
        eOracle = makeAddr("eOracle");
        vm.mockCall(eOracle, abi.encodeWithSelector(IEOracle.hasPriceFeed.selector, TOKEN), abi.encode(true));
    }

    // -------------------------------------------------------------------------
    // AddressSet
    // -------------------------------------------------------------------------

    function test_AddAndCheckWasActive_BaseToken_ReturnsTrue() public {
        assertTrue(harness.addAndCheckWasActive(eOracle, BASE_TOKEN, BASE_TOKEN));
    }

    function test_AddAndCheckWasActive_NewToken_ReturnsFalse() public {
        bool wasActive = harness.addAndCheckWasActive(eOracle, TOKEN, BASE_TOKEN);
        assertFalse(wasActive);
        assertTrue(harness.containsAddress(TOKEN));
    }

    function test_AddAndCheckWasActive_ExistingToken_ReturnsTrue() public {
        harness.addAndCheckWasActive(eOracle, TOKEN, BASE_TOKEN);
        bool wasActive = harness.addAndCheckWasActive(eOracle, TOKEN, BASE_TOKEN);
        assertTrue(wasActive);
    }

    function test_AddUnique_DuplicateIsIdempotent() public {
        harness.addUnique(eOracle, TOKEN, BASE_TOKEN);
        harness.addUnique(eOracle, TOKEN, BASE_TOKEN);
        assertTrue(harness.containsAddress(TOKEN));
    }

    function test_AddressSet_RemoveReorders() public {
        address token2 = address(0x3000);
        address token3 = address(0x4000);
        vm.mockCall(eOracle, abi.encodeWithSelector(IEOracle.hasPriceFeed.selector, token2), abi.encode(true));
        vm.mockCall(eOracle, abi.encodeWithSelector(IEOracle.hasPriceFeed.selector, token3), abi.encode(true));

        harness.addUnique(eOracle, TOKEN, BASE_TOKEN);
        harness.addUnique(eOracle, token2, BASE_TOKEN);
        harness.addUnique(eOracle, token3, BASE_TOKEN);

        harness.removeAddress(token2);
        assertFalse(harness.containsAddress(token2));
        assertTrue(harness.containsAddress(TOKEN));
        assertTrue(harness.containsAddress(token3));

        harness.removeAddress(TOKEN);
        assertFalse(harness.containsAddress(TOKEN));
        assertTrue(harness.containsAddress(token3));
    }

    // -------------------------------------------------------------------------
    // Bytes32Set
    // -------------------------------------------------------------------------

    function test_Bytes32Set_AddContainsLength() public {
        bytes32 v1 = bytes32(uint256(1));
        bytes32 v2 = bytes32(uint256(2));

        assertEq(harness.lengthBytes32(), 0);
        assertFalse(harness.containsBytes32(v1));

        harness.addBytes32(v1);
        assertEq(harness.lengthBytes32(), 1);
        assertTrue(harness.containsBytes32(v1));
        assertFalse(harness.containsBytes32(v2));

        harness.addBytes32(v1); // idempotent
        assertEq(harness.lengthBytes32(), 1);

        harness.addBytes32(v2);
        assertEq(harness.lengthBytes32(), 2);
        assertEq(harness.atBytes32(0), v1);
        assertEq(harness.atBytes32(1), v2);
    }

    function test_Bytes32Set_RemoveReorders() public {
        bytes32 v1 = bytes32(uint256(1));
        bytes32 v2 = bytes32(uint256(2));
        bytes32 v3 = bytes32(uint256(3));

        harness.addBytes32(v1);
        harness.addBytes32(v2);
        harness.addBytes32(v3);

        harness.removeBytes32(v2);
        assertEq(harness.lengthBytes32(), 2);
        assertFalse(harness.containsBytes32(v2));
        assertEq(harness.atBytes32(0), v1);
        assertEq(harness.atBytes32(1), v3);

        harness.removeBytes32(v1);
        assertEq(harness.lengthBytes32(), 1);
        assertFalse(harness.containsBytes32(v1));
        assertEq(harness.atBytes32(0), v3);

        harness.removeBytes32(v3);
        assertEq(harness.lengthBytes32(), 0);
    }

    function test_Bytes32Set_ReAddAfterRemove() public {
        bytes32 v = bytes32(uint256(1));
        harness.addBytes32(v);
        harness.removeBytes32(v);
        assertFalse(harness.containsBytes32(v));

        harness.addBytes32(v);
        assertTrue(harness.containsBytes32(v));
        assertEq(harness.lengthBytes32(), 1);
    }
}
