// SPDX-License-Identifier: Apache 2.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {SafeTransferLib} from "../../contracts/protocol/libraries/SafeTransferLib.sol";
import {EscrowFactory, OpType} from "../../contracts/protocol/libraries/EscrowFactory.sol";
import {Escrow} from "../../contracts/protocol/deps/Escrow.sol";
import {DestinationMessageParams} from "../../contracts/protocol/types/Crosschain.sol";

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

/// @title EscrowWorkingTest - Working tests for Escrow refundVault functionality
/// @notice Tests escrow token claiming and donation to pool with proper mock implementations
/// @dev Uses fork testing to access real Across-whitelisted tokens (USDC, WETH, etc.)
contract EscrowWorkingTest is Test {
    using SafeTransferLib for address;
    
    MockPoolForEscrow mockPool;
    address pool;
    address testToken; // Use real token from fork
    address escrowAddress;
    Escrow escrow;
    
    // Test actors
    address donor = makeAddr("donor");
    address randomUser = makeAddr("randomUser");
    
    // Test amounts
    uint256 constant TOKEN_AMOUNT = 1000e6;
    uint256 constant ETH_AMOUNT = 1 ether;

    function setUp() public {
        // Use Ethereum mainnet fork to access real USDC
        vm.createSelectFork("mainnet");
        
        // Use real USDC (whitelisted on Across)
        testToken = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // ETH_USDC
        
        // Deploy mock pool
        mockPool = new MockPoolForEscrow();
        pool = address(mockPool);
        
        // Deploy escrow through EscrowFactory - must be called FROM the pool context
        // to match production delegatecall behavior where pool is deployer
        vm.prank(pool);
        escrowAddress = EscrowFactory.deployEscrow(pool, OpType.Transfer);
        escrow = Escrow(payable(escrowAddress));
        
        // Verify escrow was deployed correctly
        assertEq(escrow.pool(), pool, "Escrow should store correct pool address");
        assertTrue(escrowAddress.code.length > 0, "Escrow should be deployed");
        
        console2.log("Test setup complete:");
        console2.log("  Pool:", pool);
        console2.log("  Test Token (USDC):", testToken);
        console2.log("  Escrow:", escrowAddress);
    }
    
    /// @dev Helper to fund escrow with USDC using deal (works on forks)
    function _fundEscrowWithUsdc(uint256 amount) internal {
        deal(testToken, escrowAddress, amount);
    }
    
    /// @notice Test escrow deployment and CREATE2 determinism
    function test_EscrowDeployment() public {
        assertTrue(escrowAddress != address(0), "Escrow should be deployed");
        assertEq(escrow.pool(), pool, "Escrow should reference correct pool");
        
        // Verify deployment is deterministic - address depends on pool parameter
        address predictedAddress = EscrowFactory.getEscrowAddress(pool, OpType.Transfer);
        assertEq(escrowAddress, predictedAddress, "Deployed address should match predicted");
        
        // Note: External call test (via IAIntents interface) is in AIntentsRealFork.t.sol
        // where we have a real pool with adapter mappings set up
        
        // Verify CREATE2 formula uses pool parameter (not address(this) in delegatecall context)
        // Salt is based on opType only, pool is used as deployer and in constructor
        bytes32 salt = keccak256(abi.encodePacked(uint8(OpType.Transfer)));
        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(type(Escrow).creationCode, abi.encode(pool, OpType.Transfer))
        );
        address expectedAddress = address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), pool, salt, bytecodeHash))
                )
            )
        );
        assertEq(escrowAddress, expectedAddress, "CREATE2 address must use explicit pool parameter as deployer");
    }
    
    /// @notice Test escrow constructor rejects invalid pool
    function test_EscrowConstructor_RejectsInvalidPool() public {
        vm.expectRevert(Escrow.InvalidPool.selector);
        new Escrow(address(0), OpType.Transfer); // Zero address should fail
        
        vm.expectRevert(Escrow.InvalidPool.selector);
        new Escrow(makeAddr("notAContract"), OpType.Transfer); // EOA should fail
    }
    
    /// @notice Test refunding vault tokens to pool - ERC20 (USDC)
    function test_RefundVault_ERC20() public {
        // Give escrow some USDC
        _fundEscrowWithUsdc(TOKEN_AMOUNT);
        
        // Verify escrow has tokens initially
        assertEq(IERC20(testToken).balanceOf(escrowAddress), TOKEN_AMOUNT, "Escrow should have USDC");
        
        // Call refundVault
        escrow.refundVault(testToken);
        
        // Verify tokens were transferred to pool
        assertEq(IERC20(testToken).balanceOf(escrowAddress), 0, "Escrow should have no tokens after refund");
        assertEq(IERC20(testToken).balanceOf(pool), TOKEN_AMOUNT, "Pool should receive the tokens");
    }
    
    /// @notice Test that native ETH refunds are rejected
    /// @dev ECrosschain.donate() rejects native ETH, so Escrow must reject it too
    function test_RefundVault_Native_Reverts() public {
        // Give escrow some ETH
        vm.deal(escrowAddress, ETH_AMOUNT);
        
        // Verify escrow has ETH initially
        assertEq(escrowAddress.balance, ETH_AMOUNT, "Escrow should have ETH");
        
        // Should revert with UnsupportedToken (native not in Across whitelist)
        vm.expectRevert(Escrow.UnsupportedToken.selector);
        escrow.refundVault(address(0));
        
        // Verify ETH remains in escrow
        assertEq(escrowAddress.balance, ETH_AMOUNT, "ETH should remain in escrow after revert");
    }
    
    /// @notice Test refunding multiple sequential refunds with whitelisted tokens
    function test_RefundVault_MultipleSequentialRefunds() public {
        uint256 halfUsdc = TOKEN_AMOUNT / 2;
        
        // Give escrow USDC twice
        _fundEscrowWithUsdc(halfUsdc);
        
        // Refund first batch
        escrow.refundVault(testToken);
        assertEq(IERC20(testToken).balanceOf(escrowAddress), 0, "USDC should be refunded");
        assertEq(IERC20(testToken).balanceOf(pool), halfUsdc, "Pool should receive first USDC");
        
        // Give escrow more USDC
        _fundEscrowWithUsdc(halfUsdc);
        
        // Refund second batch
        escrow.refundVault(testToken);
        assertEq(IERC20(testToken).balanceOf(escrowAddress), 0, "USDC should be refunded again");
        assertEq(IERC20(testToken).balanceOf(pool), halfUsdc * 2, "Pool should receive both batches");
    }
    
    /// @notice Test escrow rejects native ETH (no receive() function)
    /// @dev Since Across refunds WETH (not native ETH), escrow should not accept native ETH
    function test_EscrowRejectsNativeETH() public {
        uint256 sendAmount = 2 ether;
        
        // Try to send ETH to escrow - should fail (no receive() or fallback())
        vm.deal(address(this), sendAmount);
        (bool success,) = escrowAddress.call{value: sendAmount}("");
        assertFalse(success, "ETH transfer should fail - escrow has no receive()");
        
        // Verify escrow did not receive ETH
        assertEq(escrowAddress.balance, 0, "Escrow should not receive ETH");
    }
    
    /// @notice Test edge case with zero amount of ERC20 - should revert
    function test_ZeroAmountERC20() external {
        // Don't fund escrow - balance is 0
        // Should revert with InvalidAmount (balance check happens after token whitelist check)
        vm.prank(randomUser);
        vm.expectRevert(Escrow.InvalidAmount.selector);
        escrow.refundVault(testToken);
    }
    
    /// @notice Test edge case with zero amount of ETH - should revert with UnsupportedToken
    function test_ZeroAmountETH() external {
        // Native ETH is not supported (ECrosschain rejects it)
        vm.prank(randomUser);
        vm.expectRevert(Escrow.UnsupportedToken.selector);
        escrow.refundVault(address(0));
    }
    
    /// @notice Test edge case: very small amounts
    function test_RefundVault_SmallAmounts() public {
        uint256 smallAmount = 1; // 1 USDC base unit (1e-6 USDC)
        
        // Test with 1 base unit of USDC
        deal(testToken, escrowAddress, smallAmount);
        escrow.refundVault(testToken);
        assertEq(IERC20(testToken).balanceOf(escrowAddress), 0, "Should handle small amounts");
    }
    
    /// @notice Test that anyone can call refundVault
    function test_RefundVault_AnyoneCanCall() public {
        // Give escrow some USDC
        _fundEscrowWithUsdc(TOKEN_AMOUNT);
        
        // Random user can call refundVault
        vm.prank(randomUser);
        escrow.refundVault(testToken);
        
        // Verify refund worked
        assertEq(IERC20(testToken).balanceOf(escrowAddress), 0, "Escrow should have no tokens after refund");
        assertEq(IERC20(testToken).balanceOf(pool), TOKEN_AMOUNT, "Pool should receive the tokens");
    }
    
    /// @notice Test that unauthorized tokens cannot be refunded (prevents token activation griefing)
    /// @dev This prevents attackers from:
    ///      1. Auto-activating tokens via donation (if they have price feeds)
    ///      2. Filling up the 128 token limit with junk tokens
    ///      3. Increasing NAV calculation gas costs
    function test_RefundVault_RejectsUnauthorizedTokens() public {
        // Create a random token not on Across whitelist
        MockERC20 unauthorizedToken = new MockERC20();
        unauthorizedToken.mint(escrowAddress, TOKEN_AMOUNT);
        
        // Should revert with UnsupportedToken error
        vm.expectRevert(Escrow.UnsupportedToken.selector);
        escrow.refundVault(address(unauthorizedToken));
        
        // Verify tokens are still in escrow (not transferred)
        assertEq(unauthorizedToken.balanceOf(escrowAddress), TOKEN_AMOUNT, "Unauthorized tokens should remain in escrow");
        assertEq(unauthorizedToken.balanceOf(pool), 0, "Pool should not receive unauthorized tokens");
    }
    
    /// @notice Test that native currency (address(0)) is rejected
    /// @dev ECrosschain.donate() rejects native ETH, so Escrow must reject it too
    function test_RefundVault_NativeRejected() public {
        uint256 nativeAmount = 1 ether;
        
        vm.deal(escrowAddress, nativeAmount);
        
        // Should revert with UnsupportedToken
        vm.expectRevert(Escrow.UnsupportedToken.selector);
        escrow.refundVault(address(0));
        
        // Verify ETH remains in escrow
        assertEq(escrowAddress.balance, nativeAmount, "ETH should remain in escrow");
    }
}

/// @title MockPoolForEscrow - Mock pool contract for testing escrow functionality
/// @notice Simulates pool contract with donate function that consumes tokens
contract MockPoolForEscrow {
    using SafeTransferLib for address;
    
    /// @notice Mock donate function that accepts tokens - updated to match ECrosschain interface
    /// @param token Token to donate
    /// @param amount Amount to donate
    /// @param params Destination message parameters (ignored in mock)
    function donate(address token, uint256 amount, DestinationMessageParams calldata params) external payable {
        // In the real ECrosschain, donate just updates NAV accounting
        // It doesn't transfer tokens - they are already transferred separately
        // So this mock just accepts the call without doing any token transfers
        
        // The real Escrow flow:
        // 1. donate(token, 1, params) - pre-donation NAV update
        // 2. token.safeTransfer(pool, balance) - actual token transfer
        // 3. donate(token, balance, params) - post-donation NAV update
        
        // Mock just accepts the donation call
        (token, amount, params); // Silence unused parameter warnings
    }
    
    /// @notice Allow contract to receive ETH
    receive() external payable {}
}