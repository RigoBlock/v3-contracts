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

// solhint-disable-next-line
pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin-legacy/contracts/utils/math/SafeCast.sol";
import {IAcrossSpokePool} from "../../interfaces/IAcrossSpokePool.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {IWETH9} from "../../interfaces/IWETH9.sol";
import {ISmartPoolActions} from "../../interfaces/v4/pool/ISmartPoolActions.sol";
import {ISmartPoolState} from "../../interfaces/v4/pool/ISmartPoolState.sol";
import {AddressSet, EnumerableSet} from "../../libraries/EnumerableSet.sol";
import {CrosschainLib} from "../../libraries/CrosschainLib.sol";
import {ReentrancyGuardTransient} from "../../libraries/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";
import {SlotDerivation} from "../../libraries/SlotDerivation.sol";
import {StorageLib} from "../../libraries/StorageLib.sol";
import {VirtualBalanceLib} from "../../libraries/VirtualBalanceLib.sol";
import {OpType, DestinationMessage, SourceMessage} from "../../types/Crosschain.sol";
import {EscrowFactory} from "../escrow/EscrowFactory.sol";
import {IEOracle} from "./interfaces/IEOracle.sol";
import {IAIntents} from "./interfaces/IAIntents.sol";
import {IMinimumVersion} from "./interfaces/IMinimumVersion.sol";

/// @title AIntents - Allows cross-chain token transfers via Across Protocol.
/// @notice This adapter enables Rigoblock smart pools to bridge tokens across chains while maintaining NAV integrity.
/// @dev This contract ensures virtual balances are managed to offset NAV changes from cross-chain transfers.
/// @author Gabriele Rigo - <gab@rigoblock.com>
contract AIntents is IAIntents, IMinimumVersion, ReentrancyGuardTransient {
    using SafeTransferLib for address;
    using SafeCast for uint256;
    using SafeCast for int256;
    using EnumerableSet for AddressSet;
    using SlotDerivation for bytes32;
    using VirtualBalanceLib for address;

    IAcrossSpokePool public immutable override acrossSpokePool;

    address private immutable _IMPLEMENTATION;

    modifier onlyDelegateCall() {
        require(address(this) != _IMPLEMENTATION, DirectCallNotAllowed());
        _;
    }

    /// @inheritdoc IMinimumVersion
    function requiredVersion() external pure override returns (string memory) {
        return "HF_4.1.0";
    }

    constructor(address acrossSpokePoolAddress) {
        acrossSpokePool = IAcrossSpokePool(acrossSpokePoolAddress);
        _IMPLEMENTATION = address(this);
    }

    /// @inheritdoc IAIntents
    function depositV3(AcrossParams calldata params) external override nonReentrant onlyDelegateCall {
        // sanity checks
        // TODO: check if we can safely skip this check. Also maybe use unified error + condition
        require(!params.inputToken.isAddressZero(), NullAddress());
        require(params.exclusiveRelayer.isAddressZero(), NullAddress());
        
        // Prevent same-chain transfers (destination must be different chain)
        require(params.destinationChainId != block.chainid, SameChainTransfer());

        // Validate bridgeable token restriction - ensure input and output tokens are compatible
        CrosschainLib.validateBridgeableTokenPair(params.inputToken, params.outputToken);

        // TODO: validate source message to make sure the params are properly formatted, otherwise we could end up
        // in a scenario where the destination message is not correctly formatted, and the transaction reverts on the
        // dest chain, while it should have reverted on the source chain (i.e. potential loss of funds).
        // { opType, navTolerance, sourceNativeAmount, shouldUnwrapOnDestination }
        SourceMessage memory sourceMsg = abi.decode(params.message, (SourceMessage));

        // TODO: check if we can query tokens + base token in 1 call and reading only exact slots, as we're not writing to storage
        if (params.inputToken != StorageLib.pool().baseToken) {
            require(StorageLib.activeTokensSet().isActive(params.inputToken), TokenNotActive());
        }

        // Process message and get encoded result
        DestinationMessage memory destMsg = _processMessage(
            params.inputToken,
            params.outputToken,
            params.inputAmount,
            sourceMsg
        );
        
        _safeApproveToken(params.inputToken);
        
        _executeDeposit(params, sourceMsg, destMsg);
        
        _safeApproveToken(params.inputToken);
    }
    
    /*
     * INTERNAL METHODS
     */
    /// @dev Executes the depositV3 call to avoid stack too deep issues in main function
    function _executeDeposit(
        AcrossParams calldata params,
        SourceMessage memory sourceMsg,
        DestinationMessage memory destMsg
    ) private {
        acrossSpokePool.depositV3{value: sourceMsg.sourceNativeAmount}(
            sourceMsg.opType == OpType.Transfer 
                ? EscrowFactory.getEscrowAddress(address(this), OpType.Transfer)
                : address(this), // depositor for refunds
            address(this),          // recipient - destination chain recipient (always pool)
            params.inputToken,
            params.outputToken,
            params.inputAmount,
            params.outputAmount,
            params.destinationChainId,
            params.exclusiveRelayer,
            params.quoteTimestamp,
            uint32(block.timestamp + acrossSpokePool.fillDeadlineBuffer()),
            params.exclusivityDeadline,
            abi.encode(destMsg)
        );
    }
    
    function _processMessage(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        SourceMessage memory message
    ) private returns (DestinationMessage memory) {
        // Deploy Transfer escrow if needed
        if (message.opType == OpType.Transfer) {
            // Deploy escrow in delegatecall context (address(this) = pool)
            EscrowFactory.deployEscrowIfNeeded(address(this), OpType.Transfer);
            // Only adjust virtual balance for Transfer operations (NAV neutral)
            _adjustVirtualBalanceForTransfer(inputToken, inputAmount);
        } else if (message.opType == OpType.Sync) {
            // Sync operations don't adjust virtual balance (NAV changes expected)
            // TODO: SECURITY CONCERN - Operator could abuse by declaring Transfer operation
            // on source (uses escrow) but inflating NAV on destination before handler processes.
            // Handler must validate opType matches expected behavior and prevent NAV manipulation.
        } else {
            revert InvalidOpType();
        }

        ISmartPoolActions(address(this)).updateUnitaryValue();

        // Apply BSC decimal conversion for USDC/USDT if needed (both directions)
        inputAmount = CrosschainLib.applyBscDecimalConversion(inputToken, outputToken, inputAmount);

        // navTolerance in a client-side input
        return DestinationMessage({
            opType: message.opType,
            sourceChainId: block.chainid,
            sourceNav: ISmartPoolState(address(this)).getPoolTokens().unitaryValue,
            sourceDecimals: StorageLib.pool().decimals,
            navTolerance: message.navTolerance > 1000 ? 1000 : message.navTolerance, // reasonable 10% max tolerance
            shouldUnwrap: message.shouldUnwrapOnDestination,
            sourceAmount: inputAmount  // Decimal-adjusted amount for exact cross-chain offsetting
        });
    }
    
    // TODO: check if should create virtual balance for actual token instead instead of base token
    /// @dev Adjusts virtual balance for Transfer mode only - uses per-token virtual balances.
    /// @dev Only called for Transfer operations to maintain NAV neutrality.
    /// @dev Source adds positive virtual balance, destination subtracts same amount for exact NAV neutrality.
    function _adjustVirtualBalanceForTransfer(address inputToken, uint256 inputAmount) private {
        // Create virtual balance for the actual token being transferred
        // This amount is passed to destination via sourceAmount field for exact offsetting
        VirtualBalanceLib.adjustVirtualBalance(inputToken, inputAmount.toInt256());
    }

    /*
     * INTERNAL METHODS
     */
    /// @dev Approves or revokes token approval. If already approved, revokes; otherwise approves max.
    function _safeApproveToken(address token) private {
        if (token.isAddressZero()) return; // Skip if native currency
        
        // TODO: can this fail silently, and are there side effects?
        if (IERC20(token).allowance(address(this), address(acrossSpokePool)) > 0) {
            // Reset to 0 first for tokens that require it (like USDT)
            token.safeApprove(address(acrossSpokePool), 0);
        } else {
            // Approve max amount
            token.safeApprove(address(acrossSpokePool), type(uint256).max);
        }
    }
}
