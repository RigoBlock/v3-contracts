// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {PolygonDeploymentFixture} from "../fixtures/PolygonDeploymentFixture.sol";
import {ISmartPool} from "../../contracts/protocol/ISmartPool.sol";
import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";

/// @title PolygonFork - Tests for Rigoblock on Polygon PoS
/// @notice Tests basic pool operations on Polygon with POL as native currency
/// @dev Verifies that POL (address(0)) behaves like ETH on Ethereum
contract PolygonForkTest is Test, PolygonDeploymentFixture {

    function setUp() public {
        // Deploy with address(0) as base token (native POL)
        deployFixture(address(0));
        
        console2.log("=== Polygon Fork Test Setup Complete ===");
        console2.log("Pool address:", pool());
        console2.log("Base token (should be address(0)):", baseToken());
        console2.log("User POL balance:", user.balance);
    }

    /// @notice Test basic mint operation with native POL
    function test_PolygonNativeMint() public {
        console2.log("\n=== Testing Native POL Mint ===");
        
        uint256 mintAmount = 10 ether;
        
        vm.startPrank(user);
        
        uint256 userBalanceBefore = user.balance;
        uint256 poolTokenBalanceBefore = IERC20(pool()).balanceOf(user);
        
        console2.log("User POL balance before:", userBalanceBefore);
        console2.log("User pool token balance before:", poolTokenBalanceBefore);
        
        // Mint with native POL (address(0))
        uint256 poolTokensReceived = ISmartPool(payable(pool())).mint{value: mintAmount}(
            user,
            mintAmount,
            0 // amountOutMin
        );
        
        uint256 userBalanceAfter = user.balance;
        uint256 poolTokenBalanceAfter = IERC20(pool()).balanceOf(user);
        
        console2.log("User POL balance after:", userBalanceAfter);
        console2.log("User pool token balance after:", poolTokenBalanceAfter);
        console2.log("Pool tokens received:", poolTokensReceived);
        
        // Assertions
        assertLt(userBalanceAfter, userBalanceBefore, "User POL balance should decrease");
        assertGt(poolTokenBalanceAfter, poolTokenBalanceBefore, "Pool token balance should increase");
        assertGt(poolTokensReceived, 0, "Should receive pool tokens");
        
        vm.stopPrank();
        
        console2.log("Native POL mint successful");
    }

    /// @notice Test basic burn operation returning native POL
    function test_PolygonNativeBurn() public {
        console2.log("\n=== Testing Native POL Burn ===");
        
        // First mint some tokens
        uint256 mintAmount = 10 ether;
        vm.startPrank(user);
        
        uint256 poolTokensReceived = ISmartPool(payable(pool())).mint{value: mintAmount}(
            user,
            mintAmount,
            0
        );
        console2.log("Minted pool tokens:", poolTokensReceived);
        
        // Wait for minimum period (if any)
        vm.warp(block.timestamp + 30 days);
        
        // Now burn half
        uint256 burnAmount = poolTokensReceived / 2;
        uint256 userPolBalanceBefore = user.balance;
        uint256 userPoolTokenBalanceBefore = IERC20(pool()).balanceOf(user);
        
        console2.log("User POL balance before burn:", userPolBalanceBefore);
        console2.log("User pool token balance before burn:", userPoolTokenBalanceBefore);
        console2.log("Burning pool tokens:", burnAmount);
        
        uint256 polReceived = ISmartPool(payable(pool())).burn(
            burnAmount,
            0 // amountOutMin
        );
        
        uint256 userPolBalanceAfter = user.balance;
        uint256 userPoolTokenBalanceAfter = IERC20(pool()).balanceOf(user);
        
        console2.log("User POL balance after burn:", userPolBalanceAfter);
        console2.log("User pool token balance after burn:", userPoolTokenBalanceAfter);
        console2.log("POL received:", polReceived);
        
        // Assertions
        assertGt(userPolBalanceAfter, userPolBalanceBefore, "User should receive POL back");
        assertLt(userPoolTokenBalanceAfter, userPoolTokenBalanceBefore, "Pool tokens should decrease");
        assertGt(polReceived, 0, "Should receive POL");
        assertEq(userPoolTokenBalanceAfter, userPoolTokenBalanceBefore - burnAmount, "Pool token balance should match");
        
        vm.stopPrank();
        
        console2.log("Native POL burn successful");
    }

    /// @notice Test updateUnitaryValue with native POL
    function test_PolygonUpdateUnitaryValue() public {
        console2.log("\n=== Testing Update Unitary Value ===");
        
        // Get initial NAV
        ISmartPoolState.PoolTokens memory tokensBefore = ISmartPoolState(pool()).getPoolTokens();
        console2.log("Initial NAV:", tokensBefore.unitaryValue);
        console2.log("Initial total supply:", tokensBefore.totalSupply);
        
        // Update NAV
        vm.prank(user);
        ISmartPoolActions(pool()).updateUnitaryValue();
        
        // Get updated NAV
        ISmartPoolState.PoolTokens memory tokensAfter = ISmartPoolState(pool()).getPoolTokens();
        console2.log("Updated NAV:", tokensAfter.unitaryValue);
        console2.log("Updated total supply:", tokensAfter.totalSupply);
        
        // NAV should be greater than 0
        assertGt(tokensAfter.unitaryValue, 0, "NAV should be positive");
        
        console2.log("Update unitary value successful");
    }

    /// @notice Test complete flow: mint -> update NAV -> burn
    function test_PolygonCompleteFlow() public {
        console2.log("\n=== Testing Complete Flow: Mint -> Update NAV -> Burn ===");
        
        uint256 mintAmount = 50 ether;
        
        vm.startPrank(user);
        
        // Step 1: Mint
        console2.log("Step 1: Minting", mintAmount, "POL");
        uint256 poolTokensReceived = ISmartPool(payable(pool())).mint{value: mintAmount}(
            user,
            mintAmount,
            0
        );
        console2.log("Received pool tokens:", poolTokensReceived);
        
        // Step 2: Update NAV
        console2.log("Step 2: Updating NAV");
        ISmartPoolActions(pool()).updateUnitaryValue();
        ISmartPoolState.PoolTokens memory tokens = ISmartPoolState(pool()).getPoolTokens();
        console2.log("Current NAV:", tokens.unitaryValue);
        
        // Step 3: Wait for minimum period
        vm.warp(block.timestamp + 30 days);
        
        // Step 4: Burn all tokens
        console2.log("Step 3: Burning all pool tokens");
        uint256 burnAmount = IERC20(pool()).balanceOf(user);
        uint256 polReceived = ISmartPool(payable(pool())).burn(burnAmount, 0);
        console2.log("Received POL back:", polReceived);
        
        // Verify user has no more pool tokens
        uint256 remainingPoolTokens = IERC20(pool()).balanceOf(user);
        assertEq(remainingPoolTokens, 0, "User should have no pool tokens left");
        
        vm.stopPrank();
        
        console2.log("Complete flow successful");
    }

    /// @notice Test that pool correctly identifies POL as base token
    function test_PolygonBaseTokenIsNative() public view {
        console2.log("\n=== Verifying POL as Base Token ===");
        
        ISmartPoolState.ReturnedPool memory poolData = ISmartPoolState(pool()).getPool();
        
        console2.log("Pool base token:", poolData.baseToken);
        console2.log("Expected (address(0)):", address(0));
        
        assertEq(poolData.baseToken, address(0), "Base token should be address(0) for native POL");
        
        console2.log("Base token correctly set to address(0)");
    }

    /// @notice Test multiple sequential mints with native POL
    function test_PolygonSequentialMints() public {
        console2.log("\n=== Testing Sequential Mints ===");
        
        vm.startPrank(user);
        
        uint256 totalPoolTokens = 0;
        
        // Perform 3 mints
        for (uint256 i = 1; i <= 3; i++) {
            uint256 mintAmount = i * 5 ether;
            console2.log("Mint", i, "- Amount:", mintAmount);
            
            uint256 poolTokensReceived = ISmartPool(payable(pool())).mint{value: mintAmount}(
                user,
                mintAmount,
                0
            );
            
            totalPoolTokens += poolTokensReceived;
            console2.log("  Pool tokens received:", poolTokensReceived);
            console2.log("  Total pool tokens:", totalPoolTokens);
        }
        
        uint256 finalBalance = IERC20(pool()).balanceOf(user);
        console2.log("Final pool token balance:", finalBalance);
        
        // Should have accumulated tokens from all mints (minus fees)
        assertGt(finalBalance, 0, "Should have positive pool token balance");
        
        vm.stopPrank();
        
        console2.log("Sequential mints successful");
    }

    /// @notice Test that pool handles POL transfers correctly
    function test_PolygonPoolReceivesNativePOL() public {
        console2.log("\n=== Testing Pool Receives Native POL ===");
        
        uint256 poolBalanceBefore = pool().balance;
        console2.log("Pool POL balance before:", poolBalanceBefore);
        
        // Mint should increase pool's POL balance
        uint256 mintAmount = 25 ether;
        vm.prank(user);
        ISmartPool(payable(pool())).mint{value: mintAmount}(user, mintAmount, 0);
        
        uint256 poolBalanceAfter = pool().balance;
        console2.log("Pool POL balance after:", poolBalanceAfter);
        
        assertGt(poolBalanceAfter, poolBalanceBefore, "Pool should have received POL");
        
        console2.log("Pool correctly receives native POL");
    }
}
