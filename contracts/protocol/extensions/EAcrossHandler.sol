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
import {IERC20} from "../interfaces/IERC20.sol";
import {ISmartPoolActions} from "../interfaces/v4/pool/ISmartPoolActions.sol";
import {ISmartPoolImmutable} from "../interfaces/v4/pool/ISmartPoolImmutable.sol";
import {ISmartPoolState} from "../interfaces/v4/pool/ISmartPoolState.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";
import {AddressSet, EnumerableSet} from "../libraries/EnumerableSet.sol";
import {SlotDerivation} from "../libraries/SlotDerivation.sol";
import {StorageLib} from "../libraries/StorageLib.sol";
import {VirtualBalanceLib} from "../libraries/VirtualBalanceLib.sol";
import {NavImpactLib} from "../libraries/NavImpactLib.sol";
import {OpType, DestinationMessage, SourceMessage} from "../types/Crosschain.sol";
import {IEOracle} from "./adapters/interfaces/IEOracle.sol";
import {IEAcrossHandler} from "./adapters/interfaces/IEAcrossHandler.sol";

/// @title EAcrossHandler - Handles incoming cross-chain transfers via Across Protocol.
/// @notice This extension manages NAV integrity when receiving cross-chain token transfers.
/// @dev Called via delegatecall from pool when Across SpokePool fills deposits.
/// @author Gabriele Rigo - <gab@rigoblock.com>
contract EAcrossHandler is IEAcrossHandler {
    using SafeCast for uint256;
    using SafeCast for int256;
    using SlotDerivation for bytes32;
    using EnumerableSet for AddressSet;
    using VirtualBalanceLib for address;

    /// @notice Address of the Across SpokePool contract
    address private immutable _acrossSpokePool;
    
    /// @dev Passed param is expected to be valid - skip validation
    constructor(address acrossSpokePool) {
        _acrossSpokePool = acrossSpokePool;
    }

    // TODO: if this modifies state, it must not be directly callable!
    /// @inheritdoc IEAcrossHandler
    function handleV3AcrossMessage(
        address tokenReceived,
        uint256 amount,
        bytes calldata message
    ) external override {
        // CRITICAL SECURITY CHECK: Verify caller is the Across SpokePool
        // Since this is called via delegatecall, msg.sender is preserved from the original call
        require(msg.sender == _acrossSpokePool, UnauthorizedCaller());

        // Decode the message - this is internal data, not external contract interaction
        DestinationMessage memory params = abi.decode(message, (DestinationMessage));

        // TODO: SECURITY VULNERABILITY - Pool operator could abuse opType designation:
        // 1. Declare Transfer operation on source (uses escrow as depositor for refunds)
        // 2. Inflate NAV on destination chain before this handler processes the message
        // 3. Virtual balance calculations could be manipulated
        // MITIGATION: Handler should validate opType behavior matches source declaration
        // and prevent NAV manipulation between cross-chain message initiation and processing.

        // TODO: all preconditions that could revert the transaction would trigger funds loss. Therefore, they should be
        // reduced to rogue inputs on the source chain. Also, we must verify what happens on the source chain then, as we
        // might simply decide to refund the sender on the source chain, instead of reverting, i.e. in all cases where
        // the nav might be incorrectly affected (virtual balances vs nav impact).
        // ensure token is active, otherwise won't be included in nav calculations
        AddressSet storage set = StorageLib.activeTokensSet();
        address baseToken = StorageLib.pool().baseToken;

        // Unwrap native if requested
        address wrappedNative = ISmartPoolImmutable(address(this)).wrappedNative();
        address effectiveToken = tokenReceived;
        if (params.shouldUnwrap && tokenReceived == wrappedNative) {
            // interaction with external contract should happen via AUniswap.withdrawWETH9?
            IWETH9(wrappedNative).withdraw(amount);
            effectiveToken = address(0); // ETH is represented as address(0)
        }

        // TODO: this method will revert, i.e. funds would be lost, or not accounted for? should not revert, and
        // peacefully add the token to the tracked tokens (should pass flag - revertIfNoPriceFeed ?). This means
        // we should add a price feed, because the transfer will use the price to create a virtual balance? or
        // should we simply use the virtual balances by token mapping, and the nav will only include the token if
        // it can calculate the value in base token? We'd have to handle less edge cases here, and more in the
        // nav estimate, which does that - and also we'd have to accept a higher gas overhead in calculating nav
        // because we would have an array of virtual balances.
        
        // For tokens without price feeds, we can revert since escrow setup on source handles refunds properly
        if (effectiveToken != baseToken && !set.isActive(effectiveToken)) {
            // Try to add token if it has a price feed
            if (IEOracle(address(this)).hasPriceFeed(effectiveToken)) {
                set.addUnique(IEOracle(address(this)), effectiveToken, baseToken);
            } else {
                // Token doesn't have price feed - can revert since escrow handles refunds
                revert TokenWithoutPriceFeed();
            }
        }
        
        if (params.opType == OpType.Transfer) {
            // Transfer is NAV-neutral: create negative virtual balance to offset NAV increase
            _handleTransferMode(effectiveToken, amount, params);
        } else if (params.opType == OpType.Sync) {
            // Sync impacts NAV: validate percentage impact using post-transfer pool state
            // Update NAV first to reflect current state (including received tokens)
            ISmartPoolActions(address(this)).updateUnitaryValue();
            NavImpactLib.validateNavImpactTolerance(effectiveToken, amount, params.navTolerance);
        } else {
            revert InvalidOpType();
        }
    }

    /// @dev Handles Transfer mode: creates negative virtual balance to offset NAV increase.
    /// @dev Transfer is NAV-neutral and uses sourceAmount for exact neutrality despite solver fees.
    function _handleTransferMode(
        address effectiveToken, 
        uint256 receivedAmount,
        DestinationMessage memory params
    ) private {
        // Sanity check: sourceAmount should be within 10% of received amount
        // This protects against bugs or misconfigurations in decimal conversion logic
        // TODO: hardcoded max tolerance should be defined as a constant
        uint256 tolerance = receivedAmount / 10; // 10% tolerance. for very small amounts, this test could fail.
        uint256 lowerBound = receivedAmount > tolerance ? receivedAmount - tolerance : 0;
        uint256 upperBound = receivedAmount + tolerance;
        
        require(
            params.sourceAmount >= lowerBound && params.sourceAmount <= upperBound,
            SourceAmountMismatch()
        );
        
        // For Transfer: use original source amount for exact NAV neutrality
        // Source handles all decimal conversions, so sourceAmount is in correct destination decimals
        uint256 virtualBalanceAmount = params.sourceAmount;
        
        // Create negative virtual balance for the effective token (ETH if unwrapped, otherwise received token)
        VirtualBalanceLib.adjustVirtualBalance(effectiveToken, -(virtualBalanceAmount.toInt256()));
    }

    /// @dev Normalizes NAV from source decimals to destination decimals for comparison
    /// @param sourceNav The NAV from source chain
    /// @param sourceDecimals Decimals of source chain pool
    /// @param destDecimals Decimals of destination chain pool 
    /// @return normalizedNav NAV adjusted to destination decimals
    function _normalizeNav(
        uint256 sourceNav,
        uint8 sourceDecimals,
        uint8 destDecimals
    ) private pure returns (uint256 normalizedNav) {
        if (sourceDecimals == destDecimals) {
            return sourceNav;
        } else if (sourceDecimals < destDecimals) {
            // Scale up: source has fewer decimals
            return sourceNav * (10 ** (destDecimals - sourceDecimals));
        } else {
            // Scale down: source has more decimals
            return sourceNav / (10 ** (sourceDecimals - destDecimals));
        }
    }
}
