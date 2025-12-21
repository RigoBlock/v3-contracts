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
}