// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CrosschainLib} from "../../contracts/protocol/libraries/CrosschainLib.sol";
import {CrosschainTokens} from "../../contracts/protocol/types/CrosschainTokens.sol";

/// @title CrosschainLib Unit Tests
/// @notice Comprehensive tests for CrosschainLib token validation
contract CrosschainLibTest is Test {
    
    /// @notice Test USDC token validation - all valid pairs should pass
    function test_ValidateBridgeableTokenPair_USDC_AllValid() public pure {
        // Test all USDC pairs - should not revert
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_USDC, CrosschainTokens.ARB_USDC);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_USDC, CrosschainTokens.OPT_USDC);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_USDC, CrosschainTokens.BASE_USDC);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_USDC, CrosschainTokens.POLY_USDC);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_USDC, CrosschainTokens.BSC_USDC);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_USDC, CrosschainTokens.UNI_USDC);
        
        // Test reverse direction
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.BASE_USDC, CrosschainTokens.ETH_USDC);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ARB_USDC, CrosschainTokens.OPT_USDC);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.BSC_USDC, CrosschainTokens.UNI_USDC);
        
        // Test same token (valid case)
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_USDC, CrosschainTokens.ETH_USDC);
    }
    
    /// @notice Test USDT token validation - all valid pairs should pass  
    function test_ValidateBridgeableTokenPair_USDT_AllValid() public pure {
        // Test all USDT pairs - should not revert
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_USDT, CrosschainTokens.ARB_USDT);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_USDT, CrosschainTokens.OPT_USDT);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_USDT, CrosschainTokens.BASE_USDT);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_USDT, CrosschainTokens.POLY_USDT);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_USDT, CrosschainTokens.BSC_USDT);
        
        // Test reverse direction
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.BASE_USDT, CrosschainTokens.ETH_USDT);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ARB_USDT, CrosschainTokens.POLY_USDT);
        
        // Test same token
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_USDT, CrosschainTokens.ETH_USDT);
    }
    
    /// @notice Test WBTC token validation - all valid pairs should pass
    function test_ValidateBridgeableTokenPair_WBTC_AllValid() public pure {
        // Test all WBTC pairs - should not revert
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_WBTC, CrosschainTokens.ARB_WBTC);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_WBTC, CrosschainTokens.OPT_WBTC);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_WBTC, CrosschainTokens.POLY_WBTC);
        
        // Test reverse direction
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ARB_WBTC, CrosschainTokens.ETH_WBTC);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.OPT_WBTC, CrosschainTokens.POLY_WBTC);
        
        // Test same token
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_WBTC, CrosschainTokens.ETH_WBTC);
    }
    
    /// @notice Test WETH token validation - all valid pairs should pass
    function test_ValidateBridgeableTokenPair_WETH_AllValid() public pure {
        // Test all WETH pairs - should not revert
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_WETH, CrosschainTokens.ARB_WETH);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_WETH, CrosschainTokens.OPT_WETH);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_WETH, CrosschainTokens.BASE_WETH);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_WETH, CrosschainTokens.POLY_WETH);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_WETH, CrosschainTokens.BSC_WETH);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_WETH, CrosschainTokens.UNI_WETH);
        
        // Test reverse direction
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.BASE_WETH, CrosschainTokens.ETH_WETH);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.UNI_WETH, CrosschainTokens.ARB_WETH);
        
        // Test same token
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_WETH, CrosschainTokens.ETH_WETH);
    }
    
    /// forge-config: default.allow_internal_expect_revert = true
    /// @notice Test mixed token type validation - these should revert when run individually
    function test_ValidateBridgeableTokenPair_MixedTypes_USDC_to_USDT() public {
        // USDC -> USDT should revert (inputToken=USDC matches USDC category, but outputToken=USDT not in USDC list)
        vm.expectRevert(CrosschainLib.UnsupportedCrossChainToken.selector);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_USDC, CrosschainTokens.ETH_USDT);
    }
    
    /// forge-config: default.allow_internal_expect_revert = true
    function test_ValidateBridgeableTokenPair_MixedTypes_USDC_to_WETH() public {
        // USDC -> WETH should revert
        vm.expectRevert(CrosschainLib.UnsupportedCrossChainToken.selector);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.BASE_USDC, CrosschainTokens.BASE_WETH);
    }
    
    /// forge-config: default.allow_internal_expect_revert = true
    function test_ValidateBridgeableTokenPair_MixedTypes_USDT_to_WETH() public {
        // USDT -> WETH should revert
        vm.expectRevert(CrosschainLib.UnsupportedCrossChainToken.selector);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ARB_USDT, CrosschainTokens.ARB_WETH);
    }
    
    /// forge-config: default.allow_internal_expect_revert = true
    function test_ValidateBridgeableTokenPair_MixedTypes_USDC_to_WBTC() public {
        // USDC -> WBTC should revert
        vm.expectRevert(CrosschainLib.UnsupportedCrossChainToken.selector);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_USDC, CrosschainTokens.ETH_WBTC);
    }

    /// forge-config: default.allow_internal_expect_revert = true  
    /// @notice Test specific require() statements in each validation block - these are the missed lines
    function test_ValidateBridgeableTokenPair_USDC_InputToken_InvalidOutput() public {
        // USDC inputToken but non-USDC outputToken -> should hit require() at line 28-35
        vm.expectRevert(CrosschainLib.UnsupportedCrossChainToken.selector);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_USDC, CrosschainTokens.ETH_USDT);
        
        vm.expectRevert(CrosschainLib.UnsupportedCrossChainToken.selector);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ARB_USDC, CrosschainTokens.ARB_WETH);
        
        vm.expectRevert(CrosschainLib.UnsupportedCrossChainToken.selector);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.BASE_USDC, CrosschainTokens.ETH_WBTC);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_ValidateBridgeableTokenPair_USDT_InputToken_InvalidOutput() public {
        // USDT inputToken but non-USDT outputToken -> should hit require() at line 49-55
        vm.expectRevert(CrosschainLib.UnsupportedCrossChainToken.selector);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_USDT, CrosschainTokens.ETH_USDC);
        
        vm.expectRevert(CrosschainLib.UnsupportedCrossChainToken.selector);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ARB_USDT, CrosschainTokens.ARB_WETH);
        
        vm.expectRevert(CrosschainLib.UnsupportedCrossChainToken.selector);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.POLY_USDT, CrosschainTokens.POLY_WBTC);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_ValidateBridgeableTokenPair_WETH_InputToken_InvalidOutput() public {
        // WETH inputToken but non-WETH outputToken -> should hit require() at line 70-76
        vm.expectRevert(CrosschainLib.UnsupportedCrossChainToken.selector);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_WETH, CrosschainTokens.ETH_USDC);
        
        vm.expectRevert(CrosschainLib.UnsupportedCrossChainToken.selector);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ARB_WETH, CrosschainTokens.ARB_USDT);
        
        vm.expectRevert(CrosschainLib.UnsupportedCrossChainToken.selector);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.BASE_WETH, CrosschainTokens.ETH_WBTC);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_ValidateBridgeableTokenPair_WBTC_InputToken_InvalidOutput() public {
        // WBTC inputToken but non-WBTC outputToken -> should hit require() at line 88-92
        vm.expectRevert(CrosschainLib.UnsupportedCrossChainToken.selector);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_WBTC, CrosschainTokens.ETH_USDC);
        
        vm.expectRevert(CrosschainLib.UnsupportedCrossChainToken.selector);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ARB_WBTC, CrosschainTokens.ARB_USDT);
        
        vm.expectRevert(CrosschainLib.UnsupportedCrossChainToken.selector);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.OPT_WBTC, CrosschainTokens.OPT_WETH);
        
        vm.expectRevert(CrosschainLib.UnsupportedCrossChainToken.selector);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.POLY_WBTC, CrosschainTokens.BASE_USDC);
    }
    
    /// forge-config: default.allow_internal_expect_revert = true
    /// @notice Test completely unsupported token addresses - these should revert
    function test_ValidateBridgeableTokenPair_UnsupportedToken_Random() public {
        address randomToken = address(0x1234567890123456789012345678901234567890);
        
        // Random token as input should revert (inputToken not in any category)
        vm.expectRevert(CrosschainLib.UnsupportedCrossChainToken.selector);
        CrosschainLib.validateBridgeableTokenPair(randomToken, CrosschainTokens.ETH_USDC);
    }
    
    /// forge-config: default.allow_internal_expect_revert = true
    function test_ValidateBridgeableTokenPair_UnsupportedToken_Zero() public {
        // Zero address should revert (inputToken not in any category)
        vm.expectRevert(CrosschainLib.UnsupportedCrossChainToken.selector);
        CrosschainLib.validateBridgeableTokenPair(address(0), CrosschainTokens.ETH_USDC);
    }
    
    /// forge-config: default.allow_internal_expect_revert = true
    /// @notice Test edge case with well-known but unsupported token addresses
    function test_ValidateBridgeableTokenPair_WellKnownUnsupportedToken_DAI() public {
        // Use well-known token addresses that aren't in CrosschainTokens
        address daiToken = 0x6B175474E89094C44Da98b954EedeAC495271d0F; // DAI on Ethereum
        
        // Should revert for unsupported inputToken (DAI not in any category)
        vm.expectRevert(CrosschainLib.UnsupportedCrossChainToken.selector);
        CrosschainLib.validateBridgeableTokenPair(daiToken, CrosschainTokens.ETH_USDC);
    }
    
    /// @notice Test that same-address tokens pass validation (Superchain case)
    function test_ValidateBridgeableTokenPair_SameAddress_ShouldPass() public pure {
        // Same address tokens should always pass (e.g., WETH has same address across Superchain)
        address sameAddress = 0x4200000000000000000000000000000000000006; // WETH on Superchain
        
        // This should not revert - same addresses are allowed
        CrosschainLib.validateBridgeableTokenPair(sameAddress, sameAddress);
    }
    
    /// @notice Test comprehensive coverage of all token combinations
    function test_ValidateBridgeableTokenPair_ComprehensiveCoverage() public pure {
        // Test that each supported token can bridge to others of same type
        address[] memory usdcTokens = new address[](7);
        usdcTokens[0] = CrosschainTokens.ETH_USDC;
        usdcTokens[1] = CrosschainTokens.ARB_USDC;
        usdcTokens[2] = CrosschainTokens.OPT_USDC;
        usdcTokens[3] = CrosschainTokens.BASE_USDC;
        usdcTokens[4] = CrosschainTokens.POLY_USDC;
        usdcTokens[5] = CrosschainTokens.BSC_USDC;
        usdcTokens[6] = CrosschainTokens.UNI_USDC;
        
        // Test all USDC combinations
        for (uint i = 0; i < usdcTokens.length; i++) {
            for (uint j = 0; j < usdcTokens.length; j++) {
                CrosschainLib.validateBridgeableTokenPair(usdcTokens[i], usdcTokens[j]);
            }
        }
        
        address[] memory usdtTokens = new address[](6);
        usdtTokens[0] = CrosschainTokens.ETH_USDT;
        usdtTokens[1] = CrosschainTokens.ARB_USDT;
        usdtTokens[2] = CrosschainTokens.OPT_USDT;
        usdtTokens[3] = CrosschainTokens.BASE_USDT;
        usdtTokens[4] = CrosschainTokens.POLY_USDT;
        usdtTokens[5] = CrosschainTokens.BSC_USDT;
        
        // Test all USDT combinations
        for (uint i = 0; i < usdtTokens.length; i++) {
            for (uint j = 0; j < usdtTokens.length; j++) {
                CrosschainLib.validateBridgeableTokenPair(usdtTokens[i], usdtTokens[j]);
            }
        }
        
        address[] memory wethTokens = new address[](7);
        wethTokens[0] = CrosschainTokens.ETH_WETH;
        wethTokens[1] = CrosschainTokens.ARB_WETH;
        wethTokens[2] = CrosschainTokens.OPT_WETH;
        wethTokens[3] = CrosschainTokens.BASE_WETH;
        wethTokens[4] = CrosschainTokens.POLY_WETH;
        wethTokens[5] = CrosschainTokens.BSC_WETH;
        wethTokens[6] = CrosschainTokens.UNI_WETH;
        
        // Test all WETH combinations
        for (uint i = 0; i < wethTokens.length; i++) {
            for (uint j = 0; j < wethTokens.length; j++) {
                CrosschainLib.validateBridgeableTokenPair(wethTokens[i], wethTokens[j]);
            }
        }
        
        address[] memory wbtcTokens = new address[](4);
        wbtcTokens[0] = CrosschainTokens.ETH_WBTC;
        wbtcTokens[1] = CrosschainTokens.ARB_WBTC;
        wbtcTokens[2] = CrosschainTokens.OPT_WBTC;
        wbtcTokens[3] = CrosschainTokens.POLY_WBTC;
        
        // Test all WBTC combinations
        for (uint i = 0; i < wbtcTokens.length; i++) {
            for (uint j = 0; j < wbtcTokens.length; j++) {
                CrosschainLib.validateBridgeableTokenPair(wbtcTokens[i], wbtcTokens[j]);
            }
        }
    }
    
    // ====================================================================
    // BSC DECIMAL CONVERSION TESTS (Lines 94-104)
    // ====================================================================
    
    /// @notice Test BSC USDC decimal conversion: BSC (18 decimals) -> other chains (6 decimals)
    function test_ApplyBscDecimalConversion_FromBscUsdc() public pure {
        uint256 amount18Decimals = 1000e18; // 1000 USDC with 18 decimals on BSC
        uint256 expected6Decimals = 1000e6;  // Should be 1000 USDC with 6 decimals
        
        // Test BSC USDC -> ETH USDC (18 decimals -> 6 decimals)
        uint256 converted = CrosschainLib.applyBscDecimalConversion(
            CrosschainTokens.BSC_USDC,
            CrosschainTokens.ETH_USDC,
            amount18Decimals
        );
        assertEq(converted, expected6Decimals, "BSC USDC should convert from 18 to 6 decimals");
        
        // Test BSC USDC -> ARB USDC
        converted = CrosschainLib.applyBscDecimalConversion(
            CrosschainTokens.BSC_USDC,
            CrosschainTokens.ARB_USDC,
            amount18Decimals
        );
        assertEq(converted, expected6Decimals, "BSC USDC -> ARB USDC conversion");
        
        // Test BSC USDC -> BASE USDC
        converted = CrosschainLib.applyBscDecimalConversion(
            CrosschainTokens.BSC_USDC,
            CrosschainTokens.BASE_USDC,
            amount18Decimals
        );
        assertEq(converted, expected6Decimals, "BSC USDC -> BASE USDC conversion");
    }
    
    /// @notice Test BSC USDT decimal conversion: BSC (18 decimals) -> other chains (6 decimals)
    function test_ApplyBscDecimalConversion_FromBscUsdt() public pure {
        uint256 amount18Decimals = 500e18; // 500 USDT with 18 decimals on BSC
        uint256 expected6Decimals = 500e6;  // Should be 500 USDT with 6 decimals
        
        // Test BSC USDT -> ETH USDT (18 decimals -> 6 decimals)
        uint256 converted = CrosschainLib.applyBscDecimalConversion(
            CrosschainTokens.BSC_USDT,
            CrosschainTokens.ETH_USDT,
            amount18Decimals
        );
        assertEq(converted, expected6Decimals, "BSC USDT should convert from 18 to 6 decimals");
        
        // Test BSC USDT -> OPT USDT
        converted = CrosschainLib.applyBscDecimalConversion(
            CrosschainTokens.BSC_USDT,
            CrosschainTokens.OPT_USDT,
            amount18Decimals
        );
        assertEq(converted, expected6Decimals, "BSC USDT -> OPT USDT conversion");
    }
    
    /// @notice Test decimal conversion: Other chains (6 decimals) -> BSC (18 decimals)
    function test_ApplyBscDecimalConversion_ToBscUsdc() public pure {
        uint256 amount6Decimals = 2000e6;   // 2000 USDC with 6 decimals
        uint256 expected18Decimals = 2000e18; // Should be 2000 USDC with 18 decimals
        
        // Test ETH USDC -> BSC USDC (6 decimals -> 18 decimals)
        uint256 converted = CrosschainLib.applyBscDecimalConversion(
            CrosschainTokens.ETH_USDC,
            CrosschainTokens.BSC_USDC,
            amount6Decimals
        );
        assertEq(converted, expected18Decimals, "ETH USDC should convert from 6 to 18 decimals for BSC");
        
        // Test ARB USDC -> BSC USDC
        converted = CrosschainLib.applyBscDecimalConversion(
            CrosschainTokens.ARB_USDC,
            CrosschainTokens.BSC_USDC,
            amount6Decimals
        );
        assertEq(converted, expected18Decimals, "ARB USDC -> BSC USDC conversion");
        
        // Test POLY USDC -> BSC USDC
        converted = CrosschainLib.applyBscDecimalConversion(
            CrosschainTokens.POLY_USDC,
            CrosschainTokens.BSC_USDC,
            amount6Decimals
        );
        assertEq(converted, expected18Decimals, "POLY USDC -> BSC USDC conversion");
    }
    
    /// @notice Test decimal conversion: Other chains (6 decimals) -> BSC USDT (18 decimals)
    function test_ApplyBscDecimalConversion_ToBscUsdt() public pure {
        uint256 amount6Decimals = 750e6;    // 750 USDT with 6 decimals
        uint256 expected18Decimals = 750e18; // Should be 750 USDT with 18 decimals
        
        // Test ETH USDT -> BSC USDT (6 decimals -> 18 decimals)
        uint256 converted = CrosschainLib.applyBscDecimalConversion(
            CrosschainTokens.ETH_USDT,
            CrosschainTokens.BSC_USDT,
            amount6Decimals
        );
        assertEq(converted, expected18Decimals, "ETH USDT should convert from 6 to 18 decimals for BSC");
        
        // Test BASE USDT -> BSC USDT
        converted = CrosschainLib.applyBscDecimalConversion(
            CrosschainTokens.BASE_USDT,
            CrosschainTokens.BSC_USDT,
            amount6Decimals
        );
        assertEq(converted, expected18Decimals, "BASE USDT -> BSC USDT conversion");
    }
    
    /// @notice Test no conversion when BSC not involved (line 104)
    function test_ApplyBscDecimalConversion_NoBscInvolved() public pure {
        uint256 amount = 1000e6; // 1000 USDC with 6 decimals
        
        // Test ETH USDC -> ARB USDC (no BSC, no conversion)
        uint256 converted = CrosschainLib.applyBscDecimalConversion(
            CrosschainTokens.ETH_USDC,
            CrosschainTokens.ARB_USDC,
            amount
        );
        assertEq(converted, amount, "No conversion when BSC not involved");
        
        // Test ARB USDT -> BASE USDT (no BSC, no conversion)
        converted = CrosschainLib.applyBscDecimalConversion(
            CrosschainTokens.ARB_USDT,
            CrosschainTokens.BASE_USDT,
            amount
        );
        assertEq(converted, amount, "ARB USDT -> BASE USDT no conversion");
        
        // Test WETH transfers (no BSC, no conversion for WETH)
        uint256 wethAmount = 1e18;
        converted = CrosschainLib.applyBscDecimalConversion(
            CrosschainTokens.ETH_WETH,
            CrosschainTokens.BASE_WETH,
            wethAmount
        );
        assertEq(converted, wethAmount, "WETH transfers have no conversion");
        
        // Test BSC WETH (no conversion, WETH is 18 decimals everywhere)
        converted = CrosschainLib.applyBscDecimalConversion(
            CrosschainTokens.BSC_WETH,
            CrosschainTokens.ETH_WETH,
            wethAmount
        );
        assertEq(converted, wethAmount, "BSC WETH has no conversion (already 18 decimals)");
    }
    
    /// @notice Test edge cases for BSC decimal conversion
    function test_ApplyBscDecimalConversion_EdgeCases() public pure {
        // Test very small amount from BSC
        uint256 smallAmount = 1e12; // Minimum amount that converts to 1 (6 decimals)
        uint256 converted = CrosschainLib.applyBscDecimalConversion(
            CrosschainTokens.BSC_USDC,
            CrosschainTokens.ETH_USDC,
            smallAmount
        );
        assertEq(converted, 1, "Small amount converts to 1");
        
        // Test very large amount from BSC
        uint256 largeAmount = 1_000_000e18; // 1 million USDC on BSC
        converted = CrosschainLib.applyBscDecimalConversion(
            CrosschainTokens.BSC_USDC,
            CrosschainTokens.ETH_USDC,
            largeAmount
        );
        assertEq(converted, 1_000_000e6, "Large amount converts correctly");
        
        // Test very large amount to BSC
        converted = CrosschainLib.applyBscDecimalConversion(
            CrosschainTokens.ETH_USDC,
            CrosschainTokens.BSC_USDC,
            1_000_000e6
        );
        assertEq(converted, 1_000_000e18, "Large amount to BSC converts correctly");
    }
    
    /// @notice Test round-trip conversion (BSC -> other -> BSC)
    function test_ApplyBscDecimalConversion_RoundTrip() public pure {
        uint256 originalAmount = 1000e18; // Start with BSC amount
        
        // BSC -> ETH
        uint256 ethAmount = CrosschainLib.applyBscDecimalConversion(
            CrosschainTokens.BSC_USDC,
            CrosschainTokens.ETH_USDC,
            originalAmount
        );
        assertEq(ethAmount, 1000e6, "BSC to ETH conversion");
        
        // ETH -> BSC (round trip)
        uint256 backToBsc = CrosschainLib.applyBscDecimalConversion(
            CrosschainTokens.ETH_USDC,
            CrosschainTokens.BSC_USDC,
            ethAmount
        );
        assertEq(backToBsc, originalAmount, "Round trip should restore original amount");
    }
    
    // ====================================================================
    // isAllowedCrosschainToken TESTS (Lines 106-118)
    // ====================================================================
    
    /// @notice Test allowed crosschain tokens on Ethereum (chainId 1)
    function test_IsAllowedCrosschainToken_Ethereum() public {
        vm.chainId(1); // Set chainId to Ethereum
        
        // Allowed tokens on Ethereum
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.ETH_USDC), "ETH_USDC should be allowed");
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.ETH_USDT), "ETH_USDT should be allowed");
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.ETH_WETH), "ETH_WETH should be allowed");
        
        // Not allowed tokens on Ethereum (other chain tokens)
        assertFalse(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.ARB_USDC), "ARB_USDC not allowed on Ethereum");
        assertFalse(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.BASE_USDC), "BASE_USDC not allowed on Ethereum");
        assertFalse(CrosschainLib.isAllowedCrosschainToken(address(0)), "Zero address not allowed");
        assertFalse(CrosschainLib.isAllowedCrosschainToken(address(0x1234)), "Random address not allowed");
    }
    
    /// @notice Test allowed crosschain tokens on Arbitrum (chainId 42161)
    function test_IsAllowedCrosschainToken_Arbitrum() public {
        vm.chainId(42161); // Set chainId to Arbitrum
        
        // Allowed tokens on Arbitrum
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.ARB_USDC), "ARB_USDC should be allowed");
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.ARB_USDT), "ARB_USDT should be allowed");
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.ARB_WETH), "ARB_WETH should be allowed");
        
        // Not allowed tokens on Arbitrum
        assertFalse(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.ETH_USDC), "ETH_USDC not allowed on Arbitrum");
        assertFalse(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.BASE_USDC), "BASE_USDC not allowed on Arbitrum");
    }
    
    /// @notice Test allowed crosschain tokens on Optimism (chainId 10)
    function test_IsAllowedCrosschainToken_Optimism() public {
        vm.chainId(10); // Set chainId to Optimism
        
        // Allowed tokens on Optimism
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.OPT_USDC), "OPT_USDC should be allowed");
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.OPT_USDT), "OPT_USDT should be allowed");
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.OPT_WETH), "OPT_WETH should be allowed");
        
        // Not allowed tokens on Optimism
        assertFalse(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.ARB_USDC), "ARB_USDC not allowed on Optimism");
        assertFalse(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.ETH_WBTC), "ETH_WBTC not allowed on Optimism");
    }
    
    /// @notice Test allowed crosschain tokens on Base (chainId 8453)
    function test_IsAllowedCrosschainToken_Base() public {
        vm.chainId(8453); // Set chainId to Base
        
        // Allowed tokens on Base (NOTE: No USDT on Base)
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.BASE_USDC), "BASE_USDC should be allowed");
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.BASE_WETH), "BASE_WETH should be allowed");
        
        // Not allowed tokens on Base
        assertFalse(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.BASE_USDT), "BASE_USDT not allowed (doesn't exist)");
        assertFalse(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.ETH_USDC), "ETH_USDC not allowed on Base");
    }
    
    /// @notice Test allowed crosschain tokens on Polygon (chainId 137)
    function test_IsAllowedCrosschainToken_Polygon() public {
        vm.chainId(137); // Set chainId to Polygon
        
        // Allowed tokens on Polygon
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.POLY_USDC), "POLY_USDC should be allowed");
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.POLY_USDT), "POLY_USDT should be allowed");
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.POLY_WETH), "POLY_WETH should be allowed");
        
        // Not allowed tokens on Polygon
        assertFalse(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.ETH_USDC), "ETH_USDC not allowed on Polygon");
    }
    
    /// @notice Test allowed crosschain tokens on BSC (chainId 56)
    function test_IsAllowedCrosschainToken_BSC() public {
        vm.chainId(56); // Set chainId to BSC
        
        // Allowed tokens on BSC
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.BSC_USDC), "BSC_USDC should be allowed");
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.BSC_USDT), "BSC_USDT should be allowed");
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.BSC_WETH), "BSC_WETH should be allowed");
        
        // Not allowed tokens on BSC
        assertFalse(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.ETH_USDC), "ETH_USDC not allowed on BSC");
    }
    
    /// @notice Test allowed crosschain tokens on Unichain (chainId 1301)
    function test_IsAllowedCrosschainToken_Unichain() public {
        vm.chainId(1301); // Set chainId to Unichain
        
        // Allowed tokens on Unichain (NOTE: No USDT on Unichain)
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.UNI_USDC), "UNI_USDC should be allowed");
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.UNI_WETH), "UNI_WETH should be allowed");
        
        // Not allowed tokens on Unichain
        assertFalse(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.ETH_USDC), "ETH_USDC not allowed on Unichain");
        assertFalse(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.ARB_USDC), "ARB_USDC not allowed on Unichain");
    }
    
    /// @notice Test unsupported chain (should return false for all tokens)
    function test_IsAllowedCrosschainToken_UnsupportedChain() public {
        vm.chainId(999); // Unsupported chain
        
        // All tokens should be disallowed on unsupported chain
        assertFalse(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.ETH_USDC), "ETH_USDC not allowed on unsupported chain");
        assertFalse(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.ARB_USDC), "ARB_USDC not allowed on unsupported chain");
        assertFalse(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.BSC_USDC), "BSC_USDC not allowed on unsupported chain");
        assertFalse(CrosschainLib.isAllowedCrosschainToken(address(0)), "Zero address not allowed");
        assertFalse(CrosschainLib.isAllowedCrosschainToken(address(0x1234)), "Random address not allowed");
    }
    
    /// @notice Test comprehensive coverage across all supported chains
    function test_IsAllowedCrosschainToken_ComprehensiveCoverage() public {
        // Test each chain systematically
        uint256[] memory chainIds = new uint256[](7);
        chainIds[0] = 1;     // Ethereum
        chainIds[1] = 42161; // Arbitrum
        chainIds[2] = 10;    // Optimism
        chainIds[3] = 8453;  // Base
        chainIds[4] = 137;   // Polygon
        chainIds[5] = 56;    // BSC
        chainIds[6] = 1301;  // Unichain
        
        for (uint i = 0; i < chainIds.length; i++) {
            vm.chainId(chainIds[i]);
            
            // Each chain should allow at least 2 tokens (USDC and WETH at minimum)
            bool hasAllowedToken = false;
            
            // Try common tokens
            if (CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.ETH_USDC) ||
                CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.ARB_USDC) ||
                CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.OPT_USDC) ||
                CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.BASE_USDC) ||
                CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.POLY_USDC) ||
                CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.BSC_USDC) ||
                CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.UNI_USDC)) {
                hasAllowedToken = true;
            }
            
            assertTrue(hasAllowedToken, "Each supported chain should allow at least one token");
        }
    }

    /// @notice Test missing branch coverage - WBTC validation edge cases
    function test_ValidateBridgeableTokenPair_WBTC_EdgeCases() public pure {
        // Test all WBTC tokens systematically to cover all branches
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_WBTC, CrosschainTokens.ARB_WBTC);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_WBTC, CrosschainTokens.OPT_WBTC);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_WBTC, CrosschainTokens.POLY_WBTC);
        
        // All WBTC tokens with each other
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ARB_WBTC, CrosschainTokens.ETH_WBTC);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.OPT_WBTC, CrosschainTokens.POLY_WBTC);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.POLY_WBTC, CrosschainTokens.ARB_WBTC);
        
        // Same token pairs
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ETH_WBTC, CrosschainTokens.ETH_WBTC);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.ARB_WBTC, CrosschainTokens.ARB_WBTC);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.OPT_WBTC, CrosschainTokens.OPT_WBTC);
        CrosschainLib.validateBridgeableTokenPair(CrosschainTokens.POLY_WBTC, CrosschainTokens.POLY_WBTC);
    }

    /// @notice Test specific chain conditions that might be missed 
    function test_IsAllowedCrosschainToken_SpecificChainEdgeCases() public {
        // Test Ethereum with all its supported tokens
        vm.chainId(1);
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.ETH_USDC), "ETH_USDC on Ethereum");
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.ETH_USDT), "ETH_USDT on Ethereum");
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.ETH_WETH), "ETH_WETH on Ethereum");
        assertFalse(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.ARB_USDC), "ARB_USDC not on Ethereum");
        
        // Test Base specifically (no USDT)
        vm.chainId(8453);
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.BASE_USDC), "BASE_USDC on Base");
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.BASE_WETH), "BASE_WETH on Base");
        assertFalse(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.BASE_USDT), "BASE_USDT not supported");
        assertFalse(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.ETH_USDC), "ETH_USDC not on Base");
        
        // Test BSC specifically
        vm.chainId(56);
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.BSC_USDC), "BSC_USDC on BSC");
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.BSC_USDT), "BSC_USDT on BSC");
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.BSC_WETH), "BSC_WETH on BSC");
        assertFalse(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.ETH_USDC), "ETH_USDC not on BSC");

        // Test Unichain specifically (no USDT)
        vm.chainId(1301);
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.UNI_USDC), "UNI_USDC on Unichain");
        assertTrue(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.UNI_WETH), "UNI_WETH on Unichain");
        assertFalse(CrosschainLib.isAllowedCrosschainToken(CrosschainTokens.ETH_USDC), "ETH_USDC not on Unichain");
        assertFalse(CrosschainLib.isAllowedCrosschainToken(address(0x1234)), "Random token not on Unichain");
    }
}