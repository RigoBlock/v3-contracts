// SPDX-License-Identifier: Apache 2.0
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../contracts/protocol/extensions/escrow/EscrowFactory.sol";
import "../../contracts/protocol/extensions/escrow/TransferEscrow.sol";
import "../../contracts/protocol/types/Crosschain.sol";

// Test contract that uses EscrowFactory
contract TestEscrowUser {
    using EscrowFactory for *;
    
    function deployEscrow(address pool, OpType opType) external returns (address) {
        return EscrowFactory.deployEscrow(pool, opType);
    }
    
    function deployEscrowIfNeeded(address pool, OpType opType) external returns (address) {
        return EscrowFactory.deployEscrowIfNeeded(pool, opType);
    }
    
    function getEscrowAddress(address pool, OpType opType) external view returns (address) {
        return EscrowFactory.getEscrowAddress(pool, opType);
    }
}

contract EscrowFactoryCoverageTest is Test {
    TestEscrowUser testContract;
    address mockPool = address(0x1234);

    function setUp() public {
        testContract = new TestEscrowUser();
    }

    function test_CatchStatementCoverage() public {
        // Deploy an escrow once 
        address firstEscrow = testContract.deployEscrow(mockPool, OpType.Transfer);
        assertNotEq(firstEscrow, address(0));
        
        // Try to deploy the same escrow again - should hit catch statement on line 62
        address secondEscrow = testContract.deployEscrow(mockPool, OpType.Transfer);
        
        // Should be the same address (existing escrow returned by catch block)
        assertEq(firstEscrow, secondEscrow);
    }
    
    function test_DeployEscrowIfNeeded_AlreadyExists() public {
        // Deploy first escrow
        address escrowAddress = testContract.deployEscrowIfNeeded(mockPool, OpType.Transfer);
        
        // Deploy "again" - should return existing
        address sameEscrow = testContract.deployEscrowIfNeeded(mockPool, OpType.Transfer);
        
        assertEq(escrowAddress, sameEscrow);
    }

    function test_GetEscrowAddress() public view {
        // Test the getEscrowAddress function
        address predictedAddress = testContract.getEscrowAddress(mockPool, OpType.Transfer);
        assertNotEq(predictedAddress, address(0));
    }
}