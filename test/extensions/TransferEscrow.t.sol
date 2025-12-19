// SPDX-License-Identifier: Apache 2.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {SafeTransferLib} from "../../contracts/protocol/libraries/SafeTransferLib.sol";
import {EscrowFactory, OpType} from "../../contracts/protocol/extensions/escrow/EscrowFactory.sol";
import {TransferEscrow} from "../../contracts/protocol/extensions/escrow/TransferEscrow.sol";

/// @title MockERC20 - Simple ERC20 mock for testing
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    string public name = "Test Token";
    string public symbol = "TEST";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// @title TransferEscrowWorkingTest - Working tests for TransferEscrow refundVault functionality
/// @notice Tests escrow token claiming and donation to pool with proper mock implementations
contract TransferEscrowWorkingTest is Test {
    using SafeTransferLib for address;
    
    MockPoolForEscrow mockPool;
    address pool;
    MockERC20 testToken;
    address escrowAddress;
    TransferEscrow escrow;
    
    // Test actors
    address donor = makeAddr("donor");
    address randomUser = makeAddr("randomUser");
    
    // Test amounts
    uint256 constant TOKEN_AMOUNT = 1000e6;
    uint256 constant ETH_AMOUNT = 1 ether;

    function setUp() public {
        // Deploy mock pool
        mockPool = new MockPoolForEscrow();
        pool = address(mockPool);
        
        // Deploy mock ERC20 token
        testToken = new MockERC20();
        
        // Deploy escrow through EscrowFactory
        escrowAddress = EscrowFactory.deployEscrow(pool, OpType.Transfer);
        escrow = TransferEscrow(payable(escrowAddress));
        
        // Verify escrow was deployed correctly
        assertEq(escrow.pool(), pool, "Escrow should store correct pool address");
        assertTrue(escrowAddress.code.length > 0, "Escrow should be deployed");
        
        console2.log("Test setup complete:");
        console2.log("  Pool:", pool);
        console2.log("  Test Token:", address(testToken));
        console2.log("  Escrow:", escrowAddress);
    }
    
    /// @notice Test escrow deployment
    function test_EscrowDeployment() public view {
        assertTrue(escrowAddress != address(0), "Escrow should be deployed");
        assertEq(escrow.pool(), pool, "Escrow should reference correct pool");
        
        // Verify deployment is deterministic
        address predictedAddress = EscrowFactory.getEscrowAddress(pool, OpType.Transfer);
        assertEq(escrowAddress, predictedAddress, "Deployed address should match predicted");
    }
    
    /// @notice Test escrow constructor rejects invalid pool
    function test_EscrowConstructor_RejectsInvalidPool() public {
        vm.expectRevert(TransferEscrow.InvalidPool.selector);
        new TransferEscrow(address(0)); // Zero address should fail
        
        vm.expectRevert(TransferEscrow.InvalidPool.selector);
        new TransferEscrow(makeAddr("notAContract")); // EOA should fail
    }
    
    /// @notice Test refunding vault tokens to pool - ERC20
    function test_RefundVault_ERC20() public {
        // Give escrow some tokens
        testToken.mint(escrowAddress, TOKEN_AMOUNT);
        
        // Verify escrow has tokens initially
        assertEq(testToken.balanceOf(escrowAddress), TOKEN_AMOUNT, "Escrow should have tokens");
        
        // Call refundVault
        escrow.refundVault(address(testToken));
        
        // Verify tokens were transferred to pool
        assertEq(testToken.balanceOf(escrowAddress), 0, "Escrow should have no tokens after refund");
        assertEq(testToken.balanceOf(pool), TOKEN_AMOUNT, "Pool should receive the tokens");
    }
    
    /// @notice Test refunding vault tokens to pool - ETH
    function test_RefundVault_ETH() public {
        // Give escrow some ETH
        vm.deal(escrowAddress, ETH_AMOUNT);
        
        // Verify escrow has ETH initially
        assertEq(escrowAddress.balance, ETH_AMOUNT, "Escrow should have ETH");
        
        // Get initial pool ETH balance
        uint256 poolBalanceBefore = pool.balance;
        
        // Call refundVault for ETH (token = address(0))
        escrow.refundVault(address(0));
        
        // Verify ETH was transferred to pool
        assertEq(escrowAddress.balance, 0, "Escrow should have no ETH after refund");
        assertEq(pool.balance, poolBalanceBefore + ETH_AMOUNT, "Pool should receive the ETH");
    }
    
    /// @notice Test refunding multiple different tokens
    function test_RefundVault_MultipleTokens() public {
        MockERC20 secondToken = new MockERC20();
        uint256 secondAmount = 500e18;
        
        // Give escrow multiple tokens
        testToken.mint(escrowAddress, TOKEN_AMOUNT);
        secondToken.mint(escrowAddress, secondAmount);
        vm.deal(escrowAddress, ETH_AMOUNT);
        
        // Refund first token
        escrow.refundVault(address(testToken));
        assertEq(testToken.balanceOf(escrowAddress), 0, "First token should be refunded");
        assertEq(testToken.balanceOf(pool), TOKEN_AMOUNT, "Pool should receive first token");
        
        // Refund second token
        escrow.refundVault(address(secondToken));
        assertEq(secondToken.balanceOf(escrowAddress), 0, "Second token should be refunded");
        assertEq(secondToken.balanceOf(pool), secondAmount, "Pool should receive second token");
        
        // Refund ETH
        uint256 poolETHBefore = pool.balance;
        escrow.refundVault(address(0));
        assertEq(escrowAddress.balance, 0, "ETH should be refunded");
        assertEq(pool.balance, poolETHBefore + ETH_AMOUNT, "Pool should receive ETH");
    }
    
    /// @notice Test escrow can receive ETH
    function test_EscrowReceiveETH() public {
        uint256 sendAmount = 2 ether;
        
        // Send ETH to escrow
        vm.deal(address(this), sendAmount);
        (bool success,) = escrowAddress.call{value: sendAmount}("");
        assertTrue(success, "ETH transfer should succeed");
        
        // Verify escrow received ETH
        assertEq(escrowAddress.balance, sendAmount, "Escrow should receive ETH");
    }
    
    /// @notice Test edge case with zero amount of ERC20 - should revert
    function test_ZeroAmountERC20() external {
        // Test with zero balance - should revert with InvalidAmount
        vm.prank(randomUser);
        vm.expectRevert(TransferEscrow.InvalidAmount.selector);
        escrow.refundVault(address(testToken));
    }
    
    /// @notice Test edge case with zero amount of ETH - should revert
    function test_ZeroAmountETH() external {
        // Test with zero balance - should revert with InvalidAmount
        vm.prank(randomUser);
        vm.expectRevert(TransferEscrow.InvalidAmount.selector);
        escrow.refundVault(address(0));
    }
    
    /// @notice Test edge case: very small amounts
    function test_RefundVault_SmallAmounts() public {
        uint256 smallAmount = 1; // 1 wei
        
        // Test with 1 wei of token
        testToken.mint(escrowAddress, smallAmount);
        escrow.refundVault(address(testToken));
        assertEq(testToken.balanceOf(escrowAddress), 0, "Should handle small amounts");
        
        // Test with 1 wei of ETH
        vm.deal(escrowAddress, 1);
        escrow.refundVault(address(0));
        assertEq(escrowAddress.balance, 0, "Should handle small ETH amounts");
    }
    
    /// @notice Test that anyone can call refundVault
    function test_RefundVault_AnyoneCanCall() public {
        // Give escrow some tokens
        testToken.mint(escrowAddress, TOKEN_AMOUNT);
        
        // Random user can call refundVault
        vm.prank(randomUser);
        escrow.refundVault(address(testToken));
        
        // Verify refund worked
        assertEq(testToken.balanceOf(escrowAddress), 0, "Escrow should have no tokens after refund");
        assertEq(testToken.balanceOf(pool), TOKEN_AMOUNT, "Pool should receive the tokens");
    }
}

/// @title MockPoolForEscrow - Mock pool contract for testing escrow functionality
/// @notice Simulates pool contract with donate function that consumes tokens
contract MockPoolForEscrow {
    using SafeTransferLib for address;
    
    /// @notice Mock donate function that accepts tokens
    /// @param token Token to donate
    /// @param amount Amount to donate
    function donate(address token, uint256 amount) external payable {
        if (token == address(0)) {
            // For ETH donations, just accept the ETH
            require(msg.value == amount, "ETH amount mismatch");
        } else {
            // For ERC20 donations, transfer from sender
            token.safeTransferFrom(msg.sender, address(this), amount);
        }
    }
    
    /// @notice Allow contract to receive ETH
    receive() external payable {}
}