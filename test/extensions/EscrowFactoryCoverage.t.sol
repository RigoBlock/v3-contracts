// SPDX-License-Identifier: Apache 2.0
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../contracts/protocol/libraries/EscrowFactory.sol";
import "../../contracts/protocol/deps/Escrow.sol";
import "../../contracts/protocol/types/Crosschain.sol";

// Test contract that uses EscrowFactory
contract TestEscrowUser {
    using EscrowFactory for *;
    
    function deployEscrow(address pool, OpType opType) external returns (address) {
        return EscrowFactory.deployEscrow(pool, opType);
    }
    
    function getEscrowAddress(address pool, OpType opType) external pure returns (address) {
        return EscrowFactory.getEscrowAddress(pool, opType);
    }
}

contract EscrowFactoryCoverageTest is Test {
    TestEscrowUser testContract;
    address mockPool;

    function setUp() public {
        testContract = new TestEscrowUser();
        // mockPool must be a contract (Escrow constructor requires code.length > 0)
        mockPool = address(testContract); // Use testContract as a mock pool with code
    }

    function test_CatchStatementCoverage() public {
        // Deploy an escrow once 
        address firstEscrow = testContract.deployEscrow(mockPool, OpType.Transfer);
        assertNotEq(firstEscrow, address(0));
        
        // Try to deploy the same escrow again - should hit catch statement and return existing
        address secondEscrow = testContract.deployEscrow(mockPool, OpType.Transfer);
        
        // Should be the same address (existing escrow returned by catch block)
        assertEq(firstEscrow, secondEscrow);
    }
    
    function test_DeployEscrow_Idempotent() public {
        // Deploy first escrow
        address escrowAddress = testContract.deployEscrow(mockPool, OpType.Transfer);
        
        // Deploy "again" - deployEscrow is idempotent, should return existing
        address sameEscrow = testContract.deployEscrow(mockPool, OpType.Transfer);
        
        assertEq(escrowAddress, sameEscrow);
    }

    function test_GetEscrowAddress() public view {
        // Test the getEscrowAddress function
        address predictedAddress = testContract.getEscrowAddress(mockPool, OpType.Transfer);
        assertNotEq(predictedAddress, address(0));
    }
}