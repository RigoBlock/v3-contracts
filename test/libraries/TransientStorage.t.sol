// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransientStorage} from "../../contracts/protocol/libraries/TransientStorage.sol";
import {TransientSlot} from "../../contracts/protocol/libraries/TransientSlot.sol";
import {SlotDerivation} from "../../contracts/protocol/libraries/SlotDerivation.sol";

/// @title TransientStorage Unit Tests
/// @notice Comprehensive tests for TransientStorage library transient storage operations
/// @dev Tests all public functions and verifies transient storage slot updates
/// @dev Coverage: setDonationLock, getDonationLock, getTemporaryBalance, storeNav, getStoredNav
/// @dev These explicit unit tests help codecov understand coverage of transient storage operations
contract TransientStorageTest is Test {
    using TransientSlot for *;
    using SlotDerivation for bytes32;

    // Test addresses
    address constant TEST_TOKEN = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC
    address constant TEST_TOKEN_2 = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // USDT

    // Storage slot constants (must match TransientStorage.sol)
    bytes32 constant _STORED_NAV_SLOT = bytes32(uint256(keccak256("eacross.stored.nav")) - 1);
    bytes32 constant _TEMP_BALANCE_SLOT = bytes32(uint256(keccak256("eacross.temp.balance")) - 1);
    bytes32 constant _DONATION_LOCK_SLOT = bytes32(uint256(keccak256("eacross.donation.lock")) - 1);

    /*//////////////////////////////////////////////////////////////////////////
                            DONATION LOCK TESTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Test setDonationLock sets lock to true when currently unlocked
    function test_SetDonationLock_FromUnlockedToLocked() public {
        // Initial state: unlocked (false)
        bool initialLock = TransientStorage.getDonationLock();
        assertEq(initialLock, false, "Lock should initially be false");

        // Set donation lock with balance
        uint256 testBalance = 1000e6;
        TransientStorage.setDonationLock(TEST_TOKEN, testBalance);

        // Verify lock is now true
        bool finalLock = TransientStorage.getDonationLock();
        assertEq(finalLock, true, "Lock should be set to true");

        // Verify the lock slot directly
        bool directLockRead = _DONATION_LOCK_SLOT.asBoolean().tload();
        assertEq(directLockRead, true, "Direct slot read should confirm lock is true");

        // Verify temporary balance was stored with locked=true
        (uint256 storedBalance, bool locked) = TransientStorage.getTemporaryBalance(TEST_TOKEN);
        assertEq(storedBalance, testBalance, "Stored balance should match input");
        assertEq(locked, true, "Locked flag should be true");
    }

    /// @notice Test setDonationLock toggles back to false when currently locked
    function test_SetDonationLock_FromLockedToUnlocked() public {
        // First set to locked
        TransientStorage.setDonationLock(TEST_TOKEN, 500e6);
        assertTrue(TransientStorage.getDonationLock(), "Lock should be true after first call");

        // Call again to toggle back to unlocked
        uint256 newBalance = 750e6;
        TransientStorage.setDonationLock(TEST_TOKEN, newBalance);

        // Verify lock is now false
        bool finalLock = TransientStorage.getDonationLock();
        assertEq(finalLock, false, "Lock should toggle back to false");

        // Verify the lock slot directly
        bool directLockRead = _DONATION_LOCK_SLOT.asBoolean().tload();
        assertEq(directLockRead, false, "Direct slot read should confirm lock is false");

        // Verify temporary balance was stored with locked=false
        (uint256 storedBalance, bool locked) = TransientStorage.getTemporaryBalance(TEST_TOKEN);
        assertEq(storedBalance, newBalance, "Stored balance should match new input");
        assertEq(locked, false, "Locked flag should be false");
    }

    /// @notice Test setDonationLock three consecutive calls: lock -> unlock -> lock
    /// @dev This is relevant for contracts that might call setDonationLock multiple times
    /// Ensures the lock state cycles correctly through locked -> unlocked -> locked
    function test_SetDonationLock_ThreeCallCycle() public {
        uint256 balance1 = 100e6;
        uint256 balance2 = 200e6;
        uint256 balance3 = 300e6;

        // Call 1: Initial unlock (false) -> lock (true)
        TransientStorage.setDonationLock(TEST_TOKEN, balance1);
        assertTrue(TransientStorage.getDonationLock(), "After 1st call: should be locked");
        (uint256 stored1, bool locked1) = TransientStorage.getTemporaryBalance(TEST_TOKEN);
        assertEq(stored1, balance1, "After 1st call: balance should match");
        assertTrue(locked1, "After 1st call: stored locked flag should be true");

        // Call 2: Current lock (true) -> unlock (false)
        TransientStorage.setDonationLock(TEST_TOKEN, balance2);
        assertFalse(TransientStorage.getDonationLock(), "After 2nd call: should be unlocked");
        (uint256 stored2, bool locked2) = TransientStorage.getTemporaryBalance(TEST_TOKEN);
        assertEq(stored2, balance2, "After 2nd call: balance should match");
        assertFalse(locked2, "After 2nd call: stored locked flag should be false");

        // Call 3: Current unlock (false) -> lock (true)
        TransientStorage.setDonationLock(TEST_TOKEN, balance3);
        assertTrue(TransientStorage.getDonationLock(), "After 3rd call: should be locked again");
        (uint256 stored3, bool locked3) = TransientStorage.getTemporaryBalance(TEST_TOKEN);
        assertEq(stored3, balance3, "After 3rd call: balance should match");
        assertTrue(locked3, "After 3rd call: stored locked flag should be true");

        // Verify direct slot reads confirm the final state
        bool directLockRead = _DONATION_LOCK_SLOT.asBoolean().tload();
        assertTrue(directLockRead, "Direct slot read should confirm final locked state");
    }

    /// @notice Test getDonationLock returns correct initial state
    function test_GetDonationLock_InitialState() public view {
        bool lock = TransientStorage.getDonationLock();
        assertEq(lock, false, "Initial lock state should be false");
    }

    /// @notice Test getDonationLock reads from correct slot
    function test_GetDonationLock_CorrectSlot() public {
        // Manually set the lock slot to true
        _DONATION_LOCK_SLOT.asBoolean().tstore(true);

        // Verify getDonationLock reads it correctly
        bool lock = TransientStorage.getDonationLock();
        assertEq(lock, true, "getDonationLock should read the manually set value");

        // Reset to false
        _DONATION_LOCK_SLOT.asBoolean().tstore(false);
        lock = TransientStorage.getDonationLock();
        assertEq(lock, false, "getDonationLock should read the reset value");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            TEMPORARY BALANCE TESTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Test getTemporaryBalance returns correct values after setDonationLock
    function test_GetTemporaryBalance_AfterSetDonationLock() public {
        uint256 testBalance = 12345e6;

        // Set donation lock (which stores temporary balance)
        TransientStorage.setDonationLock(TEST_TOKEN, testBalance);

        // Get temporary balance
        (uint256 balance, bool locked) = TransientStorage.getTemporaryBalance(TEST_TOKEN);

        assertEq(balance, testBalance, "Balance should match stored value");
        assertEq(locked, true, "Locked should be true after setDonationLock");
    }

    /// @notice Test getTemporaryBalance returns zero for unset token
    function test_GetTemporaryBalance_UnsetToken() public view {
        (uint256 balance, bool locked) = TransientStorage.getTemporaryBalance(TEST_TOKEN_2);

        assertEq(balance, 0, "Balance should be zero for unset token");
        assertEq(locked, false, "Locked should be false for unset token");
    }

    /// @notice Test getTemporaryBalance reads from correct derived slot
    function test_GetTemporaryBalance_CorrectSlot() public {
        uint256 testBalance = 999e6;
        bool testLocked = true;

        // Manually store values in the derived slots
        bytes32 slot = _TEMP_BALANCE_SLOT.deriveMapping(TEST_TOKEN);
        slot.asUint256().tstore(testBalance);
        (bytes32(uint256(slot) + 1)).asBoolean().tstore(testLocked);

        // Verify getTemporaryBalance reads correctly
        (uint256 balance, bool locked) = TransientStorage.getTemporaryBalance(TEST_TOKEN);

        assertEq(balance, testBalance, "Balance should match manually stored value");
        assertEq(locked, testLocked, "Locked should match manually stored value");
    }

    /// @notice Test getTemporaryBalance with different tokens uses different slots
    /// @dev Note: The donation lock is global, but balances are per-token
    function test_GetTemporaryBalance_DifferentTokens() public {
        uint256 balance1 = 100e6;
        uint256 balance2 = 200e6;

        // Set first token (lock goes from false -> true)
        TransientStorage.setDonationLock(TEST_TOKEN, balance1);
        assertTrue(TransientStorage.getDonationLock(), "Lock should be true after first call");

        // Set second token (lock toggles from true -> false)
        TransientStorage.setDonationLock(TEST_TOKEN_2, balance2);
        assertFalse(TransientStorage.getDonationLock(), "Lock should toggle to false after second call");

        // Verify each token has its own balance storage (even though lock is global)
        (uint256 readBalance1, bool locked1) = TransientStorage.getTemporaryBalance(TEST_TOKEN);
        (uint256 readBalance2, bool locked2) = TransientStorage.getTemporaryBalance(TEST_TOKEN_2);

        assertEq(readBalance1, balance1, "Token 1 balance should be stored independently");
        assertEq(readBalance2, balance2, "Token 2 balance should be stored independently");
        
        // locked1 was stored with lock=true, locked2 was stored with lock=false (toggled)
        assertTrue(locked1, "Token 1 should have been stored with locked=true");
        assertFalse(locked2, "Token 2 should have been stored with locked=false (after toggle)");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            NAV STORAGE TESTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Test storeNav stores value correctly
    function test_StoreNav_SingleValue() public {
        uint256 testNav = 1000000; // 1.0 in 6 decimals

        TransientStorage.storeNav(testNav);

        // Verify via getStoredNav
        uint256 storedNav = TransientStorage.getStoredNav();
        assertEq(storedNav, testNav, "Stored NAV should match input");

        // Verify direct slot read
        uint256 directNav = _STORED_NAV_SLOT.asUint256().tload();
        assertEq(directNav, testNav, "Direct slot read should match input");
    }

    /// @notice Test storeNav overwrites previous value
    function test_StoreNav_OverwritePrevious() public {
        uint256 firstNav = 1000000;
        uint256 secondNav = 1500000;

        // Store first value
        TransientStorage.storeNav(firstNav);
        assertEq(TransientStorage.getStoredNav(), firstNav, "First NAV should be stored");

        // Store second value (overwrite)
        TransientStorage.storeNav(secondNav);
        assertEq(TransientStorage.getStoredNav(), secondNav, "Second NAV should overwrite first");

        // Verify direct slot read
        uint256 directNav = _STORED_NAV_SLOT.asUint256().tload();
        assertEq(directNav, secondNav, "Direct slot read should show overwritten value");
    }

    /// @notice Test storeNav with zero value
    function test_StoreNav_ZeroValue() public {
        // First store non-zero
        TransientStorage.storeNav(1000000);
        assertGt(TransientStorage.getStoredNav(), 0, "Initial NAV should be non-zero");

        // Store zero
        TransientStorage.storeNav(0);
        assertEq(TransientStorage.getStoredNav(), 0, "Zero NAV should be stored");
    }

    /// @notice Test storeNav with maximum uint256 value
    function test_StoreNav_MaxValue() public {
        uint256 maxNav = type(uint256).max;

        TransientStorage.storeNav(maxNav);

        uint256 storedNav = TransientStorage.getStoredNav();
        assertEq(storedNav, maxNav, "Max uint256 NAV should be stored correctly");
    }

    /// @notice Test getStoredNav returns zero initially
    function test_GetStoredNav_InitialState() public view {
        uint256 nav = TransientStorage.getStoredNav();
        assertEq(nav, 0, "Initial stored NAV should be zero");
    }

    /// @notice Test getStoredNav reads from correct slot
    function test_GetStoredNav_CorrectSlot() public {
        uint256 testNav = 2500000;

        // Manually set the NAV slot
        _STORED_NAV_SLOT.asUint256().tstore(testNav);

        // Verify getStoredNav reads it correctly
        uint256 nav = TransientStorage.getStoredNav();
        assertEq(nav, testNav, "getStoredNav should read manually set value");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            INTEGRATION TESTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Test complete donation flow: lock -> store nav -> get values
    function test_Integration_CompleteDonationFlow() public {
        address token = TEST_TOKEN;
        uint256 balance = 5000e6;
        uint256 nav = 1234567;

        // Step 1: Set donation lock (stores temporary balance)
        TransientStorage.setDonationLock(token, balance);

        // Step 2: Store NAV
        TransientStorage.storeNav(nav);

        // Step 3: Verify all values
        assertTrue(TransientStorage.getDonationLock(), "Lock should be set");

        (uint256 storedBalance, bool locked) = TransientStorage.getTemporaryBalance(token);
        assertEq(storedBalance, balance, "Balance should be stored");
        assertTrue(locked, "Balance should be locked");

        uint256 storedNav = TransientStorage.getStoredNav();
        assertEq(storedNav, nav, "NAV should be stored");

        // Step 4: Toggle lock back (simulate completion)
        TransientStorage.setDonationLock(token, 0);
        assertFalse(TransientStorage.getDonationLock(), "Lock should be cleared");
    }

    /// @notice Test multiple tokens can store temporary balances independently
    function test_Integration_MultipleTokensIndependent() public {
        address token1 = TEST_TOKEN;
        address token2 = TEST_TOKEN_2;
        uint256 balance1 = 1000e6;
        uint256 balance2 = 2000e6;

        // Store balances for both tokens
        TransientStorage.setDonationLock(token1, balance1);

        // Lock is now true, so this will toggle it back to false
        TransientStorage.setDonationLock(token2, balance2);

        // Verify both balances are stored correctly
        (uint256 stored1, bool locked1) = TransientStorage.getTemporaryBalance(token1);
        (uint256 stored2, bool locked2) = TransientStorage.getTemporaryBalance(token2);

        assertEq(stored1, balance1, "Token 1 balance should be independent");
        assertEq(stored2, balance2, "Token 2 balance should be independent");

        // First call locked, second call unlocked (toggle)
        assertTrue(locked1, "Token 1 should be locked");
        assertFalse(locked2, "Token 2 should be unlocked (toggled)");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            SLOT CALCULATION VERIFICATION TESTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Verify that storage slots match expected keccak256 calculations
    function test_SlotCalculations_MatchConstants() public pure {
        // Verify _STORED_NAV_SLOT
        bytes32 expectedNavSlot = bytes32(uint256(keccak256("eacross.stored.nav")) - 1);
        assertEq(_STORED_NAV_SLOT, expectedNavSlot, "NAV slot should match calculation");

        // Verify _TEMP_BALANCE_SLOT
        bytes32 expectedBalanceSlot = bytes32(uint256(keccak256("eacross.temp.balance")) - 1);
        assertEq(_TEMP_BALANCE_SLOT, expectedBalanceSlot, "Balance slot should match calculation");

        // Verify _DONATION_LOCK_SLOT
        bytes32 expectedLockSlot = bytes32(uint256(keccak256("eacross.donation.lock")) - 1);
        assertEq(_DONATION_LOCK_SLOT, expectedLockSlot, "Lock slot should match calculation");
    }

    /// @notice Verify slot derivation for mapping (used by temporary balance)
    function test_SlotDerivation_TemporaryBalance() public pure {
        bytes32 baseSlot = _TEMP_BALANCE_SLOT;
        address token = TEST_TOKEN;

        // Calculate expected derived slot
        bytes32 expectedSlot = keccak256(abi.encode(token, baseSlot));

        // Calculate using SlotDerivation library
        bytes32 derivedSlot = baseSlot.deriveMapping(token);

        assertEq(derivedSlot, expectedSlot, "Slot derivation should match expected calculation");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            EDGE CASE TESTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Test with zero address token
    function test_EdgeCase_ZeroAddressToken() public {
        address zeroToken = address(0);
        uint256 balance = 100e6;

        TransientStorage.setDonationLock(zeroToken, balance);

        (uint256 storedBalance, bool locked) = TransientStorage.getTemporaryBalance(zeroToken);
        assertEq(storedBalance, balance, "Zero address should work as a token");
        assertTrue(locked, "Zero address token should be lockable");
    }

    /// @notice Test with maximum address value
    function test_EdgeCase_MaxAddressToken() public {
        address maxToken = address(type(uint160).max);
        uint256 balance = 999e6;

        TransientStorage.setDonationLock(maxToken, balance);

        (uint256 storedBalance, bool locked) = TransientStorage.getTemporaryBalance(maxToken);
        assertEq(storedBalance, balance, "Max address should work as a token");
        assertTrue(locked, "Max address token should be lockable");
    }

    /// @notice Test rapid lock/unlock toggling
    /// @dev The global lock toggles on each call to setDonationLock
    function test_EdgeCase_RapidToggling() public {
        uint256 balance = 500e6;

        // Initial state: unlocked (false)
        assertFalse(TransientStorage.getDonationLock(), "Should start unlocked");

        // Toggle multiple times and verify the pattern
        for (uint i = 0; i < 5; i++) {
            bool beforeLock = TransientStorage.getDonationLock();
            TransientStorage.setDonationLock(TEST_TOKEN, balance);
            bool afterLock = TransientStorage.getDonationLock();
            
            // Each call toggles the lock
            assertEq(afterLock, !beforeLock, "Lock should toggle on each call");
        }
        
        // After 5 toggles from false, we should be at true
        assertTrue(TransientStorage.getDonationLock(), "After 5 toggles from false, should be true");
    }
}
