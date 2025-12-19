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
import {ISmartPoolImmutable} from "../interfaces/v4/pool/ISmartPoolImmutable.sol";
import {ISmartPoolState} from "../interfaces/v4/pool/ISmartPoolState.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";
import {AddressSet, EnumerableSet} from "../libraries/EnumerableSet.sol";
import {SlotDerivation} from "../libraries/SlotDerivation.sol";
import {StorageLib} from "../libraries/StorageLib.sol";
import {VirtualBalanceLib} from "../libraries/VirtualBalanceLib.sol";
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
    /// @dev Immutable to save gas on verification
    address public immutable acrossSpokePool;
    
    constructor(address _acrossSpokePool) {
        // TODO: use custom errors! Also constructor args are assumed to be valid, no validation should be needed
        require(_acrossSpokePool != address(0), "INVALID_SPOKE_POOL");
        acrossSpokePool = _acrossSpokePool;
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
        require(msg.sender == acrossSpokePool, UnauthorizedCaller());

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

        // TODO: this method will revert, i.e. funds would be lost, or not accounted for? should not revert, and
        // peacefully add the token to the tracked tokens (should pass flag - revertIfNoPriceFeed ?). This means
        // we should add a price feed, because the transfer will use the price to create a virtual balance? or
        // should we simply use the virtual balances by token mapping, and the nav will only include the token if
        // it can calculate the value in base token? We'd have to handle less edge cases here, and more in the
        // nav estimate, which does that - and also we'd have to accept a higher gas overhead in calculating nav
        // because we would have an array of virtual balances.
        
        // For tokens without price feeds, we can revert since escrow setup on source handles refunds properly
        if (tokenReceived != baseToken && !set.isActive(tokenReceived)) {
            // Try to add token if it has a price feed
            if (IEOracle(address(this)).hasPriceFeed(tokenReceived)) {
                set.addUnique(IEOracle(address(this)), tokenReceived, baseToken);
            } else {
                // Token doesn't have price feed - can revert since escrow handles refunds
                revert TokenWithoutPriceFeed();
            }
        }
        
        // Unwrap native if requested
        address wrappedNative = ISmartPoolImmutable(address(this)).wrappedNative();
        if (params.shouldUnwrap && tokenReceived == wrappedNative) {
            // interaction with external contract should happen via AUniswap.withdrawWETH9?
            IWETH9(wrappedNative).withdraw(amount);
        }
        
        if (params.opType == OpType.Transfer || params.opType == OpType.Sync) {
            // Both Transfer and Sync create virtual balances
            _handleTransferMode(tokenReceived, amount, params);
        } else {
            revert InvalidOpType();
        }
    }

    /// @dev Handles Transfer and Sync modes: creates negative virtual balance to offset NAV increase.
    /// @dev For Transfer mode, uses sourceAmount to ensure exact NAV neutrality despite solver fees.
    /// @dev For Sync mode, uses received amount since NAV changes are intended.
    function _handleTransferMode(
        address tokenReceived, 
        uint256 receivedAmount,
        DestinationMessage memory params
    ) private {
        uint256 virtualBalanceAmount;
        
        if (params.opType == OpType.Transfer) {
            // Sanity check: sourceAmount should be within 10% of received amount
            // This protects against bugs or misconfigurations in decimal conversion logic
            uint256 tolerance = receivedAmount / 10; // 10% tolerance
            uint256 lowerBound = receivedAmount > tolerance ? receivedAmount - tolerance : 0;
            uint256 upperBound = receivedAmount + tolerance;
            
            require(
                params.sourceAmount >= lowerBound && params.sourceAmount <= upperBound,
                SourceAmountMismatch()
            );
            
            // For Transfer: use original source amount for exact NAV neutrality
            // Source handles all decimal conversions, so sourceAmount is in correct destination decimals
            virtualBalanceAmount = params.sourceAmount;
        } else {
            // For Sync: use actual received amount (NAV changes intended)
            virtualBalanceAmount = receivedAmount;
        }
        
        // Create negative virtual balance for the received token
        VirtualBalanceLib.adjustVirtualBalance(tokenReceived, -(virtualBalanceAmount.toInt256()));
    }

    /// @dev Normalizes NAV from source decimals to destination decimals.
    /// @dev This is critical for cross-chain NAV comparisons where vault decimals may differ
    function _normalizeNav(
        uint256 nav,
        uint8 sourceDecimals,
        uint8 destDecimals
    ) private pure returns (uint256) {
        if (sourceDecimals == destDecimals) {
            return nav;
        } else if (sourceDecimals > destDecimals) {
            return nav / (10 ** (sourceDecimals - destDecimals));
        } else {
            return nav * (10 ** (destDecimals - sourceDecimals));
        }
    }
}
