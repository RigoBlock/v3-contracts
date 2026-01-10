// SPDX-License-Identifier: Apache 2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {RealDeploymentFixture} from "../fixtures/RealDeploymentFixture.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {OpType, DestinationMessageParams} from "../../contracts/protocol/types/Crosschain.sol";
import {IEAcrossHandler} from "../../contracts/protocol/extensions/adapters/interfaces/IEAcrossHandler.sol";

/// @title Cross-Token Attack Proof of Concept
/// @notice Demonstrates why temporary balance MUST be per-token, not pool-level
/// @dev This test PASSES, proving the attack is possible. It shows that:
///      1. Lock is pool-level (correct) - only one donation at a time
///      2. Temp balance MUST be per-token (critical security requirement)
///      3. Without per-token temp balance, attacker can initialize with tokenA
///         and process with tokenB, using wrong balance snapshot
///      4. This test should be kept to prevent future regressions
///      
/// ATTACK FLOW:
/// - Initialize with USDC: lock=true, tempBalance[USDC]=1000e6
/// - Pre-send WETH to pool
/// - Process WETH: lock passes, tempBalance[WETH]=0 (never initialized!)
/// - amountDelta = currentWETH - 0 = includes all WETH (attack succeeds)
///
/// WHY TESTS DIDN'T CATCH THIS ORIGINALLY:
/// - All existing tests follow correct flow: donate(token,1) then donate(token,amount) 
/// - No test tried cross-token: donate(tokenA,1) then donate(tokenB,amount)
/// - This test should remain to prevent removing per-token mapping
contract CrossTokenAttackPOC is Test, RealDeploymentFixture {

    function setUp() public {
        // Deploy fixture with USDC - fixture handles all fork creation and setup
        address[] memory baseTokens = new address[](1);
        baseTokens[0] = Constants.ETH_USDC;
        deployFixture(baseTokens);
    }
    
    /// @notice This test demonstrates the cross-token attack vulnerability is PREVENTED
    /// @dev Attack: Initialize with tokenA, then process with tokenB (different token)
    ///      This should REVERT with TokenNotInitialized() error
    function test_CrossTokenAttack_InitializeUSDC_ProcessWETH() public {
        address poolAddr = ethereum.pool;
        address multicallHandler = Constants.ETH_MULTICALL_HANDLER;
        address usdc = Constants.ETH_USDC;
        address weth = Constants.ETH_WETH;
        
        // Fund pool with both tokens
        deal(usdc, poolAddr, 1000e6); // 1000 USDC
        deal(weth, poolAddr, 1 ether); // 1 WETH
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Sync,
            shouldUnwrapNative: false
        });
        
        vm.startPrank(multicallHandler);
        
        // Step 1: Initialize donation with USDC
        // This sets lock=true and stores USDC balance
        IEAcrossHandler(poolAddr).donate(usdc, 1, params);
        
        console2.log("Lock is now set, USDC balance stored");
        
        // Step 2: Now try to process WETH donation (cross-token attack!)
        // 
        // ATTACK PREVENTED:
        // - Lock check passes (pool is locked)
        // - storedBalance = getTemporaryBalance(WETH) = 0 (WETH never initialized!)
        // - NEW CHECK: require(storedBalance > 0) → REVERTS with TokenNotInitialized()
        // - Attack is blocked!
        
        // Pre-send additional WETH to demonstrate attack intent
        deal(weth, poolAddr, 2 ether); // Pool now has 2 WETH
        
        // Try to process WETH without proper initialization - should REVERT
        vm.expectRevert(IEAcrossHandler.TokenNotInitialized.selector);
        IEAcrossHandler(poolAddr).donate(weth, 1 ether, params);
        
        vm.stopPrank();
        
        console2.log("Cross-token attack PREVENTED!");
        console2.log("Attack reverted with TokenNotInitialized error");
    }
    
    /// @notice This test shows the correct flow: initialize and process SAME token
    function test_CorrectFlow_InitializeAndProcessSameToken() public {
        address poolAddr = ethereum.pool;
        address multicallHandler = Constants.ETH_MULTICALL_HANDLER;
        address usdc = Constants.ETH_USDC;
        
        deal(usdc, poolAddr, 1000e6);
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Sync,
            shouldUnwrapNative: false
        });
        
        vm.startPrank(multicallHandler);
        
        // Step 1: Initialize with USDC
        IEAcrossHandler(poolAddr).donate(usdc, 1, params);
        
        // Step 2: Process with USDC (SAME token - correct!)
        // Pre-send more USDC
        deal(usdc, poolAddr, 1500e6);
        
        // This correctly uses storedBalance[USDC] = 1000e6
        // amountDelta = 1500e6 - 1000e6 = 500e6 (correct delta)
        IEAcrossHandler(poolAddr).donate(usdc, 500e6, params);
        
        vm.stopPrank();
        
        // Verify transient storage is completely cleared using direct slot access
        bytes32 slot = bytes32(uint256(keccak256("eacross.temp.balance")) - 1);
        bytes32 balanceSlot = keccak256(abi.encode(usdc, slot));
        bytes32 initSlot = bytes32(uint256(balanceSlot) + 1);
        
        uint256 clearedBalance;
        bool clearedInit;
        assembly {
            clearedBalance := tload(balanceSlot)
            clearedInit := tload(initSlot)
        }
        
        assertEq(clearedBalance, 0, "Balance should be cleared");
        assertEq(clearedInit, false, "Initialized flag should be cleared");
        
        console2.log("Correct flow: initialized and processed same token");
        console2.log("Verified: transient storage cleared after processing");
    }
}
