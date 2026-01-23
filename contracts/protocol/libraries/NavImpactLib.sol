// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

import {SafeCast} from "@openzeppelin-legacy/contracts/utils/math/SafeCast.sol";
import {ISmartPoolState} from "../interfaces/v4/pool/ISmartPoolState.sol";
import {StorageLib} from "./StorageLib.sol";
import {VirtualStorageLib} from "./VirtualStorageLib.sol";
import {IEOracle} from "../extensions/adapters/interfaces/IEOracle.sol";

/// @title NavImpactLib - Library for validating NAV impact tolerance
/// @notice Provides percentage-based NAV impact validation for cross-chain transfers
/// @dev Used by both AIntents (source) and ECrosschain (destination) for consistent validation
/// @author Gabriele Rigo - <gab@rigoblock.com>
library NavImpactLib {
    using SafeCast for uint256;
    using SafeCast for int256;

    error EffectiveSupplyTooLow();

    /// @notice Thrown when transfer amount exceeds maximum allowed NAV impact
    /// @dev Impact is calculated as (transferValue * 10000) / totalAssetsValue in basis points
    error NavImpactTooHigh();

    /// @notice Minimum ratio of effective supply to total supply (1/8 = 12.5%)
    /// @dev When virtual supply is negative, effective supply must be at least totalSupply / MINIMUM_SUPPLY_RATIO
    uint256 internal constant MINIMUM_SUPPLY_RATIO = 8;

    /// @notice Validates that transfer amount doesn't exceed NAV impact tolerance
    /// @dev Calculates percentage impact: (transferValue * 10000) / totalAssetsValue vs toleranceBps
    /// @param token Token being transferred
    /// @param amount Amount being transferred
    /// @param toleranceBps Maximum allowed NAV impact in basis points (e.g., 1000 = 10%)
    function validateNavImpact(address token, uint256 amount, uint256 toleranceBps) internal view {
        // Get current pool state
        ISmartPoolState.PoolTokens memory poolTokens = ISmartPoolState(address(this)).getPoolTokens();
        uint8 poolDecimals = StorageLib.pool().decimals;
        address baseToken = StorageLib.pool().baseToken;

        // Calculate effective supply using signed arithmetic (VS can be negative)
        int256 virtualSupply = VirtualStorageLib.getVirtualSupply();
        int256 effectiveSupply = int256(poolTokens.totalSupply) + virtualSupply;
        if (effectiveSupply <= 0) {
            return; // No effective supply, allow any transfer
        }

        uint256 totalAssetsValue = (poolTokens.unitaryValue * uint256(effectiveSupply)) / (10 ** poolDecimals);

        // For empty pools (all supply burnt on all chains), allow any transfer. Handles edge case of receiving first tokens on a chain
        if (totalAssetsValue == 0) {
            return;
        }

        // Convert transfer amount to base token value for percentage calculation
        int256 transferValueInBase;
        if (token == baseToken) {
            transferValueInBase = amount.toInt256();
        } else {
            // Use convertTokenAmount for non-base tokens
            transferValueInBase = IEOracle(address(this)).convertTokenAmount(token, amount.toInt256(), baseToken);
        }

        // Calculate percentage impact in basis points: (transferValue * 10000) / totalAssetsValue
        uint256 transferValue = transferValueInBase.toUint256();
        uint256 impactBps = (transferValue * 10000) / totalAssetsValue;

        // Validate impact is within tolerance
        if (impactBps > toleranceBps) {
            revert NavImpactTooHigh();
        }
    }

    /// @notice Validates that effective supply meets minimum threshold when virtual supply is negative
    /// @dev Only reverts when:
    ///      - Virtual supply is negative AND effective supply < totalSupply / MINIMUM_SUPPLY_RATIO
    /// @param totalSupply The total token supply
    /// @param virtualSupply The virtual supply (can be negative)
    function validateEffectiveSupply(uint256 totalSupply, int256 virtualSupply) internal pure returns (int256) {
        int256 effectiveSupply = int256(totalSupply) + virtualSupply;

        // Safety check: when VS is negative, ensure at least MINIMUM_SUPPLY_RATIO of TS remains
        // This prevents extreme edge cases and ensures local redemptions can be honored
        if (virtualSupply < 0 && effectiveSupply < int256(totalSupply / MINIMUM_SUPPLY_RATIO)) {
            revert EffectiveSupplyTooLow();
        }

        return effectiveSupply;
    }
}
