// SPDX-License-Identifier: Apache-2.0-or-later
/*

 Copyright 2025 Rigo Intl.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.

*/

pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin-legacy/contracts/utils/math/SafeCast.sol";
import {ISmartPoolState} from "../interfaces/v4/pool/ISmartPoolState.sol";
import {StorageLib} from "./StorageLib.sol";
import {VirtualBalanceLib} from "./VirtualBalanceLib.sol";
import {IEOracle} from "../extensions/adapters/interfaces/IEOracle.sol";

/// @title NavImpactLib - Library for validating NAV impact tolerance
/// @notice Provides percentage-based NAV impact validation for cross-chain transfers
/// @dev Used by both AIntents (source) and EAcrossHandler (destination) for consistent validation
/// @author Gabriele Rigo - <gab@rigoblock.com>
library NavImpactLib {
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @notice Thrown when transfer amount exceeds maximum allowed NAV impact
    /// @dev Impact is calculated as (transferValue * 10000) / totalAssetsValue in basis points
    error NavImpactTooHigh();

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
        poolTokens.totalSupply += VirtualBalanceLib.getVirtualSupply().toUint256();
        uint256 totalAssetsValue = (poolTokens.unitaryValue * poolTokens.totalSupply) / (10 ** poolDecimals);

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
        uint256 transferValueAbs = transferValueInBase >= 0
            ? uint256(transferValueInBase)
            : uint256(-transferValueInBase);
        uint256 impactBps = (transferValueAbs * 10000) / totalAssetsValue;

        // Validate impact is within tolerance
        if (impactBps > toleranceBps) {
            revert NavImpactTooHigh();
        }
    }
}
