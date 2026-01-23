// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

import {CrosschainTokens} from "../types/CrosschainTokens.sol";

/// @title CrosschainLib - Library for cross-chain token validation and conversion.
/// @notice Provides utilities for validating bridgeable token pairs, handling BSC decimal conversions, and resolving Across handler addresses.
/// @dev Used by cross-chain adapters to ensure token compatibility and proper decimal handling.
library CrosschainLib {
    // Import token addresses from shared constants
    using CrosschainTokens for address;

    // Custom errors
    error UnsupportedCrossChainToken();
    error WrongDestinationToken();

    /// @notice Across MulticallHandler addresses
    address internal constant DEFAULT_MULTICALL_HANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
    address internal constant BSC_MULTICALL_HANDLER = 0xAC537C12fE8f544D712d71ED4376a502EEa944d7;

    /// @notice Check if a token is allowed for cross-chain operations on the current chain.
    /// @param token The token address to check.
    /// @return True if the token is allowed for cross-chain operations.
    function isAllowedCrosschainToken(address token) internal view returns (bool) {
        if (block.chainid == 1) {
            // Ethereum
            return
                token == CrosschainTokens.ETH_USDC ||
                token == CrosschainTokens.ETH_USDT ||
                token == CrosschainTokens.ETH_WETH;
        } else if (block.chainid == 42161) {
            // Arbitrum
            return
                token == CrosschainTokens.ARB_USDC ||
                token == CrosschainTokens.ARB_USDT ||
                token == CrosschainTokens.ARB_WETH;
        } else if (block.chainid == 10) {
            // Optimism
            return
                token == CrosschainTokens.OPT_USDC ||
                token == CrosschainTokens.OPT_USDT ||
                token == CrosschainTokens.OPT_WETH;
        } else if (block.chainid == 8453) {
            // Base
            return token == CrosschainTokens.BASE_USDC || token == CrosschainTokens.BASE_WETH; // No USDT on Base
        } else if (block.chainid == 137) {
            // Polygon
            return
                token == CrosschainTokens.POLY_USDC ||
                token == CrosschainTokens.POLY_USDT ||
                token == CrosschainTokens.POLY_WETH;
        } else if (block.chainid == 56) {
            // BSC
            return
                token == CrosschainTokens.BSC_USDC ||
                token == CrosschainTokens.BSC_USDT ||
                token == CrosschainTokens.BSC_WETH;
        } else if (block.chainid == 1301) {
            // Unichain
            return token == CrosschainTokens.UNI_USDC || token == CrosschainTokens.UNI_WETH;
        }
        return false;
    }

    /// @notice Applies BSC decimal conversion for USDC/USDT (18 decimals on BSC vs 6 on other chains).
    /// @dev Handles bidirectional conversion to ensure exact cross-chain value calculation.
    /// @param inputToken Source token address.
    /// @param outputToken Destination token address.
    /// @param amount Original amount in source chain decimals.
    /// @return Normalized amount for correct cross-chain virtual supply calculation.
    function applyBscDecimalConversion(
        address inputToken,
        address outputToken,
        uint256 amount
    ) internal pure returns (uint256) {
        // From BSC (18 decimals) -> normalize to 6 decimals
        if (inputToken == CrosschainTokens.BSC_USDC || inputToken == CrosschainTokens.BSC_USDT) {
            return amount / 1e12; // Convert 18 decimals to 6 decimals
        }

        // To BSC (6 decimals) -> convert to 18 decimals
        if (outputToken == CrosschainTokens.BSC_USDC || outputToken == CrosschainTokens.BSC_USDT) {
            return amount * 1e12; // Convert 6 decimals to 18 decimals
        }

        // No BSC involved - no conversion needed
        return amount;
    }

    /// @notice Get the appropriate Across MulticallHandler address for a given chain.
    /// @dev BSC (chain ID 56) uses a different handler than other chains.
    /// @param chainId The destination chain ID.
    /// @return handler The MulticallHandler address for the specified chain.
    function getAcrossHandler(uint256 chainId) internal pure returns (address handler) {
        // BSC uses different multicall handler
        if (chainId == 56) {
            return BSC_MULTICALL_HANDLER;
        }

        // Most chains use the standard multicall handler
        return DEFAULT_MULTICALL_HANDLER;
    }

    /// @notice Validates that input and output tokens are compatible for cross-chain bridging.
    /// @dev Only allows bridging between tokens of the same type (USDC↔USDC, USDT↔USDT, etc.).
    /// @param inputToken Source token address.
    /// @param outputToken Destination token address.
    function validateBridgeableTokenPair(address inputToken, address outputToken) internal pure {
        // Allow same token addresses (e.g., WETH on Superchain has same address across chains)
        // Chain ID validation is handled separately in AIntents
        // Check USDC bridgeable tokens (includes BSC with 18vs6 decimal conversion)
        if (
            inputToken == CrosschainTokens.ETH_USDC ||
            inputToken == CrosschainTokens.ARB_USDC ||
            inputToken == CrosschainTokens.OPT_USDC ||
            inputToken == CrosschainTokens.BASE_USDC ||
            inputToken == CrosschainTokens.POLY_USDC ||
            inputToken == CrosschainTokens.BSC_USDC ||
            inputToken == CrosschainTokens.UNI_USDC
        ) {
            require(
                outputToken == CrosschainTokens.ETH_USDC ||
                    outputToken == CrosschainTokens.ARB_USDC ||
                    outputToken == CrosschainTokens.OPT_USDC ||
                    outputToken == CrosschainTokens.BASE_USDC ||
                    outputToken == CrosschainTokens.POLY_USDC ||
                    outputToken == CrosschainTokens.BSC_USDC ||
                    outputToken == CrosschainTokens.UNI_USDC,
                WrongDestinationToken()
            );
        } else if (
            inputToken == CrosschainTokens.ETH_USDT ||
            inputToken == CrosschainTokens.ARB_USDT ||
            inputToken == CrosschainTokens.OPT_USDT ||
            inputToken == CrosschainTokens.BASE_USDT ||
            inputToken == CrosschainTokens.POLY_USDT ||
            inputToken == CrosschainTokens.BSC_USDT
        ) {
            require(
                outputToken == CrosschainTokens.ETH_USDT ||
                    outputToken == CrosschainTokens.ARB_USDT ||
                    outputToken == CrosschainTokens.OPT_USDT ||
                    outputToken == CrosschainTokens.BASE_USDT ||
                    outputToken == CrosschainTokens.POLY_USDT ||
                    outputToken == CrosschainTokens.BSC_USDT,
                WrongDestinationToken()
            );
        } else if (
            inputToken == CrosschainTokens.ETH_WETH ||
            inputToken == CrosschainTokens.ARB_WETH ||
            inputToken == CrosschainTokens.OPT_WETH ||
            inputToken == CrosschainTokens.BASE_WETH ||
            inputToken == CrosschainTokens.POLY_WETH ||
            inputToken == CrosschainTokens.BSC_WETH ||
            inputToken == CrosschainTokens.UNI_WETH
        ) {
            require(
                outputToken == CrosschainTokens.ETH_WETH ||
                    outputToken == CrosschainTokens.ARB_WETH ||
                    outputToken == CrosschainTokens.OPT_WETH ||
                    outputToken == CrosschainTokens.BASE_WETH ||
                    outputToken == CrosschainTokens.POLY_WETH ||
                    outputToken == CrosschainTokens.BSC_WETH ||
                    outputToken == CrosschainTokens.UNI_WETH,
                WrongDestinationToken()
            );
        } else if (
            inputToken == CrosschainTokens.ETH_WBTC ||
            inputToken == CrosschainTokens.ARB_WBTC ||
            inputToken == CrosschainTokens.OPT_WBTC ||
            inputToken == CrosschainTokens.POLY_WBTC
        ) {
            require(
                outputToken == CrosschainTokens.ETH_WBTC ||
                    outputToken == CrosschainTokens.ARB_WBTC ||
                    outputToken == CrosschainTokens.OPT_WBTC ||
                    outputToken == CrosschainTokens.POLY_WBTC,
                WrongDestinationToken()
            );
        } else {
            revert UnsupportedCrossChainToken();
        }
    }
}
