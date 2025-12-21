// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

/// @title CrosschainTokens - Shared token address constants for cross-chain operations
/// @notice Centralized token addresses to prevent duplication and ensure consistency
/// @dev Used by CrosschainLib, tests, and other cross-chain components
library CrosschainTokens {
    // Ethereum mainnet
    address internal constant ETH_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
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
}