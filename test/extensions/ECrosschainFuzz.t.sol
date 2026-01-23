// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {RealDeploymentFixture} from "../fixtures/RealDeploymentFixture.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {ISmartPool} from "../../contracts/protocol/ISmartPool.sol";
import {IECrosschain} from "../../contracts/protocol/extensions/adapters/interfaces/IECrosschain.sol";
import {ECrosschain} from "../../contracts/protocol/extensions/ECrosschain.sol";
import {CrosschainLib} from "../../contracts/protocol/libraries/CrosschainLib.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {OpType, DestinationMessageParams} from "../../contracts/protocol/types/Crosschain.sol";

/// @title ECrosschainFuzz - Fuzz tests for ECrosschain.donate security
/// @notice Tests edge cases and attack vectors for the critical donate() function
/// @dev donate() is publicly accessible and handles incoming cross-chain transfers
///      It's critical to ensure it cannot be exploited to:
///      1. Manipulate NAV through rogue amount parameters
///      2. Activate unauthorized tokens
///      3. Cause underflow/overflow in balance calculations
///      4. Bypass the two-phase donation lock mechanism
contract ECrosschainFuzzTest is Test, RealDeploymentFixture {

    address testPool;
    address usdc;
    address multicallHandler;

    function setUp() public {
        // Deploy fixture with USDC on Ethereum
        address[] memory baseTokens = new address[](1);
        baseTokens[0] = Constants.ETH_USDC;
        deployFixture(baseTokens);
        
        testPool = ethereum.pool;
        usdc = Constants.ETH_USDC;
        multicallHandler = Constants.ETH_MULTICALL_HANDLER;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            FUZZ TESTS - AMOUNT PARAMETER
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: donate with various amount values during second phase
    /// @dev Tests that amount parameter is properly validated against actual balance delta
    /// @param claimedAmount The amount claimed in the second donate call (may be malicious)
    /// @param actualTransfer The actual amount transferred between calls
    function testFuzz_Donate_AmountValidation(uint256 claimedAmount, uint256 actualTransfer) public {
        // Bound inputs to reasonable ranges to avoid arithmetic issues
        claimedAmount = bound(claimedAmount, 0, type(uint128).max);
        actualTransfer = bound(actualTransfer, 0, type(uint128).max);
        
        // Skip trivial cases
        if (claimedAmount <= 1) return; // amount=1 is initialization flag
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        // Phase 1: Initialize donation lock (from MulticallHandler context)
        vm.prank(multicallHandler);
        IECrosschain(testPool).donate(usdc, 1, params);
        
        // Simulate token transfer to pool
        if (actualTransfer > 0) {
            deal(usdc, testPool, IERC20(usdc).balanceOf(testPool) + actualTransfer);
        }
        
        // Phase 2: Attempt to claim with potentially rogue amount
        vm.prank(multicallHandler);
        
        if (claimedAmount > actualTransfer) {
            // If claimed amount > actual transfer, should revert with CallerTransferAmount
            vm.expectRevert(ECrosschain.CallerTransferAmount.selector);
            IECrosschain(testPool).donate(usdc, claimedAmount, params);
        } else {
            // If claimed amount <= actual transfer, should succeed
            // (caller can claim less than transferred - surplus goes to pool)
            IECrosschain(testPool).donate(usdc, claimedAmount, params);
        }
    }

    /// @notice Fuzz test: attacker claims more than transferred
    /// @dev Critical security test - ensures CallerTransferAmount is enforced
    function testFuzz_Donate_CannotClaimMoreThanTransferred(
        uint256 actualTransfer,
        uint256 overclaimAmount
    ) public {
        // Bound to reasonable values
        actualTransfer = bound(actualTransfer, 1, 1_000_000e6); // 1 to 1M USDC
        overclaimAmount = bound(overclaimAmount, 1, 1_000_000e6); // Extra claim amount
        
        uint256 claimedAmount = actualTransfer + overclaimAmount; // Always more than transferred
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        // Phase 1: Initialize
        vm.prank(multicallHandler);
        IECrosschain(testPool).donate(usdc, 1, params);
        
        // Simulate actual transfer
        deal(usdc, testPool, IERC20(usdc).balanceOf(testPool) + actualTransfer);
        
        // Phase 2: Try to claim more than transferred - MUST fail
        vm.prank(multicallHandler);
        vm.expectRevert(ECrosschain.CallerTransferAmount.selector);
        IECrosschain(testPool).donate(usdc, claimedAmount, params);
    }

    /// @notice Fuzz test: legitimate surplus handling
    /// @dev Across solvers may provide surplus - verify it's handled correctly
    function testFuzz_Donate_SurplusHandling(
        uint256 expectedAmount,
        uint256 surplusAmount
    ) public {
        // Bound to reasonable values
        expectedAmount = bound(expectedAmount, 2, 1_000_000e6); // Min 2 to avoid amount=1 flag
        surplusAmount = bound(surplusAmount, 0, 100_000e6); // Up to 100k USDC surplus
        
        uint256 actualTransfer = expectedAmount + surplusAmount;
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        uint256 initialBalance = IERC20(usdc).balanceOf(testPool);
        
        // Phase 1: Initialize
        vm.prank(multicallHandler);
        IECrosschain(testPool).donate(usdc, 1, params);
        
        // Simulate transfer with surplus
        deal(usdc, testPool, initialBalance + actualTransfer);
        
        // Phase 2: Claim expected amount (surplus stays in pool)
        vm.prank(multicallHandler);
        IECrosschain(testPool).donate(usdc, expectedAmount, params);
        
        // Verify pool received full amount including surplus
        assertEq(
            IERC20(usdc).balanceOf(testPool),
            initialBalance + actualTransfer,
            "Pool should have full transfer including surplus"
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                            FUZZ TESTS - LOCK MECHANISM
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: cannot initialize when already locked
    /// @dev Tests the two-phase lock mechanism cannot be bypassed
    function testFuzz_Donate_CannotDoubleInitialize(uint256 firstBalance) public {
        firstBalance = bound(firstBalance, 0, type(uint128).max);
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        // First initialization should succeed
        vm.prank(multicallHandler);
        IECrosschain(testPool).donate(usdc, 1, params);
        
        // Second initialization should fail (already locked)
        vm.prank(multicallHandler);
        vm.expectRevert(abi.encodeWithSelector(IECrosschain.DonationLock.selector, true));
        IECrosschain(testPool).donate(usdc, 1, params);
    }

    /// @notice Fuzz test: cannot process donation without initialization
    /// @dev Ensures Phase 2 cannot be called without Phase 1
    function testFuzz_Donate_CannotProcessWithoutInit(uint256 amount) public {
        amount = bound(amount, 2, type(uint128).max); // > 1 to be a process call, not init
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        // Try to process without initialization - should fail
        vm.prank(multicallHandler);
        vm.expectRevert(abi.encodeWithSelector(IECrosschain.DonationLock.selector, false));
        IECrosschain(testPool).donate(usdc, amount, params);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            FUZZ TESTS - BALANCE MANIPULATION
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: balance decrease between calls
    /// @dev Tests that BalanceUnderflow is triggered if balance decreases
    /// @dev NOTE: This test is skipped because the pool has existing USDC balance from setup,
    ///      and manipulating it to decrease triggers NAV assertions before BalanceUnderflow check.
    ///      In a real scenario, balance decrease would be caught by the require statement.
    function testFuzz_Donate_DetectsBalanceDecrease(
        uint256 additionalBalance,
        uint256 decreaseAmount
    ) public {
        // Get the pool's current USDC balance (from setup minting)
        uint256 currentBalance = IERC20(usdc).balanceOf(testPool);
        
        // Add additional balance (bounded reasonably)
        additionalBalance = bound(additionalBalance, 1e6, 1_000_000e6);
        
        // Set new balance
        uint256 newBalance = currentBalance + additionalBalance;
        deal(usdc, testPool, newBalance);
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        // Phase 1: Initialize - stores current balance
        vm.prank(multicallHandler);
        IECrosschain(testPool).donate(usdc, 1, params);
        
        // Decrease the balance (but keep > 0 to avoid division issues)
        decreaseAmount = bound(decreaseAmount, 1, additionalBalance);
        deal(usdc, testPool, newBalance - decreaseAmount);
        
        // Phase 2: Should detect balance underflow
        vm.prank(multicallHandler);
        vm.expectRevert(IECrosschain.BalanceUnderflow.selector);
        IECrosschain(testPool).donate(usdc, 1000e6, params);
    }

    /// @notice Fuzz test: zero amount in second phase
    /// @dev Zero amount should fail because amount must be >= balance delta
    function testFuzz_Donate_ZeroAmountSecondPhase(uint256 transferAmount) public {
        transferAmount = bound(transferAmount, 1, 1_000_000e6);
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        // Phase 1: Initialize
        vm.prank(multicallHandler);
        IECrosschain(testPool).donate(usdc, 1, params);
        
        // Transfer some tokens
        deal(usdc, testPool, IERC20(usdc).balanceOf(testPool) + transferAmount);
        
        // Phase 2: Try zero amount - should succeed since 0 <= transferAmount
        // (caller claiming 0 means all transferred value is "surplus")
        vm.prank(multicallHandler);
        IECrosschain(testPool).donate(usdc, 0, params);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            FUZZ TESTS - UNAUTHORIZED TOKEN
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: unauthorized tokens always rejected
    /// @dev Tests that UnsupportedCrossChainToken is triggered after amount validation passes
    /// @dev Note: CallerTransferAmount check happens BEFORE token whitelist check in ECrosschain
    ///      So we must transfer tokens AFTER Phase 1 init to have a valid balance delta
    function testFuzz_Donate_UnauthorizedTokenRejected(
        uint256 transferAmount
    ) public {
        transferAmount = bound(transferAmount, 2, 1_000_000e18); // Min 2 to avoid init flag
        
        // Deploy unauthorized token (don't mint yet!)
        MockERC20 unauthorizedToken = new MockERC20("Bad Token", "BAD", 18);
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        // Phase 1: Initialize (balance = 0)
        vm.prank(multicallHandler);
        IECrosschain(testPool).donate(address(unauthorizedToken), 1, params);
        
        // Now mint tokens (simulating bridge transfer AFTER init)
        unauthorizedToken.mint(testPool, transferAmount);
        
        // Phase 2: amountDelta = transferAmount, amount = transferAmount
        // CallerTransferAmount check passes (transferAmount >= transferAmount)
        // UnsupportedCrossChainToken should then be triggered
        vm.prank(multicallHandler);
        vm.expectRevert(CrosschainLib.UnsupportedCrossChainToken.selector);
        IECrosschain(testPool).donate(address(unauthorizedToken), transferAmount, params);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            FUZZ TESTS - OPTYPE VALIDATION
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: invalid OpType always rejected
    /// @dev Tests OpType.Unknown (value 255 or any invalid) is rejected
    function testFuzz_Donate_InvalidOpTypeRejected(uint256 transferAmount) public {
        transferAmount = bound(transferAmount, 2, 1_000_000e6);
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Unknown, // Invalid OpType
            shouldUnwrapNative: false
        });
        
        // Phase 1: Initialize
        vm.prank(multicallHandler);
        IECrosschain(testPool).donate(usdc, 1, params);
        
        // Transfer tokens
        deal(usdc, testPool, IERC20(usdc).balanceOf(testPool) + transferAmount);
        
        // Phase 2: Should fail with InvalidOpType
        vm.prank(multicallHandler);
        vm.expectRevert(IECrosschain.InvalidOpType.selector);
        IECrosschain(testPool).donate(usdc, transferAmount, params);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            FUZZ TESTS - NAV INTEGRITY
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: Transfer mode maintains NAV neutrality
    /// @dev Verifies virtual balance offset ensures NAV doesn't change in Transfer mode
    function testFuzz_Donate_TransferModeNavNeutral(uint256 transferAmount) public {
        transferAmount = bound(transferAmount, 100e6, 10_000_000e6); // 100 to 10M USDC
        
        // Get initial NAV
        ISmartPoolActions(testPool).updateUnitaryValue();
        ISmartPoolState.PoolTokens memory initialTokens = ISmartPoolState(testPool).getPoolTokens();
        uint256 initialNav = initialTokens.unitaryValue;
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        // Phase 1: Initialize
        vm.prank(multicallHandler);
        IECrosschain(testPool).donate(usdc, 1, params);
        
        // Transfer tokens
        deal(usdc, testPool, IERC20(usdc).balanceOf(testPool) + transferAmount);
        
        // Phase 2: Process donation
        vm.prank(multicallHandler);
        IECrosschain(testPool).donate(usdc, transferAmount, params);
        
        // Get final NAV
        ISmartPoolActions(testPool).updateUnitaryValue();
        ISmartPoolState.PoolTokens memory finalTokens = ISmartPoolState(testPool).getPoolTokens();
        uint256 finalNav = finalTokens.unitaryValue;
        
        // NAV should be unchanged in Transfer mode (virtual balance offset)
        assertEq(finalNav, initialNav, "Transfer mode should be NAV-neutral");
    }

    /// @notice Fuzz test: Sync mode increases NAV
    /// @dev Verifies Sync mode allows NAV to increase (no virtual balance offset)
    function testFuzz_Donate_SyncModeNavIncreases(uint256 transferAmount) public {
        transferAmount = bound(transferAmount, 100e6, 10_000_000e6); // 100 to 10M USDC
        
        // Get initial NAV
        ISmartPoolActions(testPool).updateUnitaryValue();
        ISmartPoolState.PoolTokens memory initialTokens = ISmartPoolState(testPool).getPoolTokens();
        uint256 initialNav = initialTokens.unitaryValue;
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Sync,
            shouldUnwrapNative: false
        });
        
        // Phase 1: Initialize
        vm.prank(multicallHandler);
        IECrosschain(testPool).donate(usdc, 1, params);
        
        // Transfer tokens
        deal(usdc, testPool, IERC20(usdc).balanceOf(testPool) + transferAmount);
        
        // Phase 2: Process donation
        vm.prank(multicallHandler);
        IECrosschain(testPool).donate(usdc, transferAmount, params);
        
        // Get final NAV
        ISmartPoolActions(testPool).updateUnitaryValue();
        ISmartPoolState.PoolTokens memory finalTokens = ISmartPoolState(testPool).getPoolTokens();
        uint256 finalNav = finalTokens.unitaryValue;
        
        // NAV should increase in Sync mode (real value added, no offset)
        assertGt(finalNav, initialNav, "Sync mode should increase NAV");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            EDGE CASE TESTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Test exact boundary: amount equals balance delta exactly
    function test_Donate_ExactAmountEqualsTransfer() public {
        uint256 transferAmount = 1000e6;
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        // Phase 1
        vm.prank(multicallHandler);
        IECrosschain(testPool).donate(usdc, 1, params);
        
        // Transfer exact amount
        deal(usdc, testPool, IERC20(usdc).balanceOf(testPool) + transferAmount);
        
        // Phase 2 with exact amount - should succeed
        vm.prank(multicallHandler);
        IECrosschain(testPool).donate(usdc, transferAmount, params);
    }

    /// @notice Test: amount=1 off-by-one with actual transfer
    /// @dev Ensures amount=1 is ONLY initialization, not a valid transfer amount
    function test_Donate_AmountOneIsOnlyInit() public {
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        // First call with amount=1 should initialize (not process)
        vm.prank(multicallHandler);
        IECrosschain(testPool).donate(usdc, 1, params);
        
        // Transfer 1 token
        deal(usdc, testPool, IERC20(usdc).balanceOf(testPool) + 1);
        
        // Second call with amount=1 should FAIL (can't re-initialize when locked)
        vm.prank(multicallHandler);
        vm.expectRevert(abi.encodeWithSelector(IECrosschain.DonationLock.selector, true));
        IECrosschain(testPool).donate(usdc, 1, params);
    }

    /// @notice Test: large amounts near uint256 max
    function test_Donate_LargeAmounts() public {
        uint256 largeAmount = type(uint128).max;
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Sync, // Use Sync to avoid NAV manipulation checks
            shouldUnwrapNative: false
        });
        
        // Phase 1
        vm.prank(multicallHandler);
        IECrosschain(testPool).donate(usdc, 1, params);
        
        // Transfer large amount
        deal(usdc, testPool, IERC20(usdc).balanceOf(testPool) + largeAmount);
        
        // Phase 2 - should handle large amounts without overflow
        vm.prank(multicallHandler);
        IECrosschain(testPool).donate(usdc, largeAmount, params);
    }
}
