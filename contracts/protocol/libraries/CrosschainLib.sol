// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

/// @title CrosschainLib - Library for cross-chain token validation and conversion
/// @notice Provides utilities for validating bridgeable token pairs and handling BSC decimal conversions
/// @dev Used by cross-chain adapters to ensure token compatibility and proper decimal handling
library CrosschainLib {
    // Token address constants for validation
    // Ethereum mainnet
    address internal constant ETH_USDC = 0xa0b86a33E6441319A87aA51FBbcFa4De9A7A24c8;
    address internal constant ETH_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant ETH_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant ETH_WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    // Arbitrum
    address internal constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant ARB_USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address internal constant ARB_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant ARB_WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;

    // Optimism
    address internal constant OPT_USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address internal constant OPT_USDT = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;
    address internal constant OPT_WETH = 0x4200000000000000000000000000000000000006;
    address internal constant OPT_WBTC = 0x68f180fcCe6836688e9084f035309E29Bf0A2095;

    // Base
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant BASE_USDT = 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2;
    address internal constant BASE_WETH = 0x4200000000000000000000000000000000000006;

    // Polygon
    address internal constant POLY_USDC = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address internal constant POLY_USDT = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F;
    address internal constant POLY_WETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
    address internal constant POLY_WBTC = 0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6;

    // BSC
    address internal constant BSC_USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address internal constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant BSC_WETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;

    // Unichain
    address internal constant UNI_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant UNI_WETH = 0x4200000000000000000000000000000000000006;

    // Custom errors
    error UnsupportedCrossChainToken();

    /// @notice Validates that input and output tokens are compatible for cross-chain bridging
    /// @dev Only allows bridging between tokens of the same type (USDC↔USDC, USDT↔USDT, etc.)
    /// @param inputToken Source token address
    /// @param outputToken Destination token address
    function validateBridgeableTokenPair(address inputToken, address outputToken) internal pure {
        // Allow same token addresses (e.g., WETH on Superchain has same address across chains)
        // Chain ID validation is handled separately in AIntents
        
        // Check USDC bridgeable tokens (includes BSC with 18vs6 decimal conversion)
        if (inputToken == ETH_USDC || inputToken == ARB_USDC || inputToken == OPT_USDC || 
            inputToken == BASE_USDC || inputToken == POLY_USDC || inputToken == BSC_USDC || inputToken == UNI_USDC) {
            require(outputToken == ETH_USDC || outputToken == ARB_USDC || outputToken == OPT_USDC || 
                    outputToken == BASE_USDC || outputToken == POLY_USDC || outputToken == BSC_USDC || outputToken == UNI_USDC,
                    UnsupportedCrossChainToken());
            return;
        }
        
        // Check USDT bridgeable tokens (includes BSC with 18vs6 decimal conversion)
        if (inputToken == ETH_USDT || inputToken == ARB_USDT || inputToken == OPT_USDT || 
            inputToken == BASE_USDT || inputToken == POLY_USDT || inputToken == BSC_USDT) {
            require(outputToken == ETH_USDT || outputToken == ARB_USDT || outputToken == OPT_USDT || 
                    outputToken == BASE_USDT || outputToken == POLY_USDT || outputToken == BSC_USDT,
                    UnsupportedCrossChainToken());
            return;
        }
        
        // Check WETH bridgeable tokens  
        if (inputToken == ETH_WETH || inputToken == ARB_WETH || inputToken == OPT_WETH || 
            inputToken == BASE_WETH || inputToken == POLY_WETH || inputToken == BSC_WETH || inputToken == UNI_WETH) {
            require(outputToken == ETH_WETH || outputToken == ARB_WETH || outputToken == OPT_WETH || 
                    outputToken == BASE_WETH || outputToken == POLY_WETH || outputToken == BSC_WETH || outputToken == UNI_WETH,
                    UnsupportedCrossChainToken());
            return;
        }
        
        // Check WBTC bridgeable tokens (not available on Base, BSC, Unichain)
        if (inputToken == ETH_WBTC || inputToken == ARB_WBTC || inputToken == OPT_WBTC || inputToken == POLY_WBTC) {
            require(outputToken == ETH_WBTC || outputToken == ARB_WBTC || outputToken == OPT_WBTC || outputToken == POLY_WBTC,
                    UnsupportedCrossChainToken());
            return;
        }
        
        // If we get here, input token is not supported
        revert UnsupportedCrossChainToken();
    }

    /// @notice Applies BSC decimal conversion for USDC/USDT (18 decimals on BSC vs 6 on other chains)
    /// @dev Handles bidirectional conversion to ensure exact cross-chain virtual balance offsetting
    /// @param inputToken Source token address  
    /// @param outputToken Destination token address
    /// @param amount Original amount in source chain decimals
    /// @return Normalized amount for exact cross-chain virtual balance offsetting
    function applyBscDecimalConversion(
        address inputToken, 
        address outputToken, 
        uint256 amount
    ) internal pure returns (uint256) {
        // From BSC (18 decimals) -> normalize to 6 decimals
        if (inputToken == BSC_USDC || inputToken == BSC_USDT) {
            return amount / 1e12;  // Convert 18 decimals to 6 decimals
        }
        
        // To BSC (6 decimals) -> convert to 18 decimals  
        if (outputToken == BSC_USDC || outputToken == BSC_USDT) {
            return amount * 1e12;  // Convert 6 decimals to 18 decimals
        }
        
        // No BSC involved - no conversion needed
        return amount;
    }
}