// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CrosschainLib} from "../../contracts/protocol/libraries/CrosschainLib.sol";
import {CrosschainTokens} from "../../contracts/protocol/types/CrosschainTokens.sol";

/// @title BSC Decimal Conversion Tests
/// @notice Test suite for BSC decimal conversion in CrosschainLib
contract BSCDecimalConversionTest is Test {
    
    /// @notice Test BSC USDC conversion (18 -> 6 decimals)
    function test_ApplyBscDecimalConversion_BSC_USDC_To_ETH_USDC() public pure {
        uint256 bscAmount = 1000 * 1e18; // 1000 USDC on BSC (18 decimals)
        uint256 expectedAmount = 1000 * 1e6; // 1000 USDC on Ethereum (6 decimals)
        
        uint256 converted = CrosschainLib.applyBscDecimalConversion(
            CrosschainTokens.BSC_USDC,
            CrosschainTokens.ETH_USDC,
            bscAmount
        );
        
        assertEq(converted, expectedAmount, "BSC USDC (18d) -> ETH USDC (6d) conversion failed");
    }
    
    /// @notice Test reverse BSC USDC conversion (6 -> 18 decimals)
    function test_ApplyBscDecimalConversion_ETH_USDC_To_BSC_USDC() public pure {
        uint256 ethAmount = 1000 * 1e6; // 1000 USDC on Ethereum (6 decimals)
        uint256 expectedAmount = 1000 * 1e18; // 1000 USDC on BSC (18 decimals)
        
        uint256 converted = CrosschainLib.applyBscDecimalConversion(
            CrosschainTokens.ETH_USDC,
            CrosschainTokens.BSC_USDC,
            ethAmount
        );
        
        assertEq(converted, expectedAmount, "ETH USDC (6d) -> BSC USDC (18d) conversion failed");
    }
    
    /// @notice Test BSC USDT conversion (18 -> 6 decimals)
    function test_ApplyBscDecimalConversion_BSC_USDT_To_ETH_USDT() public pure {
        uint256 bscAmount = 500 * 1e18; // 500 USDT on BSC (18 decimals)
        uint256 expectedAmount = 500 * 1e6; // 500 USDT on Ethereum (6 decimals)
        
        uint256 converted = CrosschainLib.applyBscDecimalConversion(
            CrosschainTokens.BSC_USDT,
            CrosschainTokens.ETH_USDT,
            bscAmount
        );
        
        assertEq(converted, expectedAmount, "BSC USDT (18d) -> ETH USDT (6d) conversion failed");
    }
    
    /// @notice Test no conversion needed (non-BSC tokens)
    function test_ApplyBscDecimalConversion_No_Conversion_Needed() public pure {
        uint256 amount = 1000 * 1e6; // 1000 USDC
        
        uint256 converted = CrosschainLib.applyBscDecimalConversion(
            CrosschainTokens.ETH_USDC,
            CrosschainTokens.ARB_USDC,
            amount
        );
        
        assertEq(converted, amount, "Non-BSC conversion should return same amount");
    }
    
    /// @notice Test edge case with small amounts
    function test_ApplyBscDecimalConversion_Small_Amount() public pure {
        uint256 bscAmount = 1e12; // Very small amount on BSC (18 decimals)
        uint256 expectedAmount = 1; // Should become 1 unit in 6 decimals
        
        uint256 converted = CrosschainLib.applyBscDecimalConversion(
            CrosschainTokens.BSC_USDC,
            CrosschainTokens.ETH_USDC,
            bscAmount
        );
        
        assertEq(converted, expectedAmount, "Small amount conversion failed");
    }
    
    /// @notice Test potential precision loss (amounts not divisible by 1e12)
    function test_ApplyBscDecimalConversion_Precision_Loss() public pure {
        uint256 bscAmount = 1000 * 1e18 + 5e11; // 1000.0005 USDC on BSC
        uint256 expectedAmount = 1000 * 1e6; // Should truncate to 1000 USDC
        
        uint256 converted = CrosschainLib.applyBscDecimalConversion(
            CrosschainTokens.BSC_USDC,
            CrosschainTokens.ETH_USDC,
            bscAmount
        );
        
        assertEq(converted, expectedAmount, "Precision loss handling failed");
    }
}