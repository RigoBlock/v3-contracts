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
import {ISmartPoolImmutable} from "../../interfaces/v4/pool/ISmartPoolImmutable.sol";
import {AddressSet, EnumerableSet} from "../../libraries/EnumerableSet.sol";
import {CrosschainLib} from "../../libraries/CrosschainLib.sol";
import {ReentrancyGuardTransient} from "../../libraries/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";
import {SlotDerivation} from "../../libraries/SlotDerivation.sol";
import {StorageLib} from "../../libraries/StorageLib.sol";
import {VirtualBalanceLib} from "../../libraries/VirtualBalanceLib.sol";
import {NavImpactLib} from "../../libraries/NavImpactLib.sol";
import {OpType, SourceMessageParams, Call, Instructions} from "../../types/Crosschain.sol";
import {EscrowFactory} from "../escrow/EscrowFactory.sol";
import {IEOracle} from "./interfaces/IEOracle.sol";
import {IAIntents} from "./interfaces/IAIntents.sol";
import {IEAcrossHandler} from "./interfaces/IEAcrossHandler.sol";
import {IMinimumVersion} from "./interfaces/IMinimumVersion.sol";

// TODO: move to an imported interface
interface IMulticallHandler {
    function drainLeftoverTokens(address token, address payable destination) external;
}

/// @title AIntents - Allows cross-chain token transfers via Across Protocol with adapter synchronization.
/// @notice This adapter enables Rigoblock smart pools to bridge tokens across chains while maintaining NAV integrity.
/// @dev Uses synchronized adapter deployment to ensure destination adapters exist before enabling cross-chain features.
/// @author Gabriele Rigo - <gab@rigoblock.com>
contract AIntents is IAIntents, IMinimumVersion, ReentrancyGuardTransient {
    using SafeTransferLib for address;
    using SafeCast for uint256;
    using SafeCast for int256;
    using EnumerableSet for AddressSet;
    using SlotDerivation for bytes32;
    using VirtualBalanceLib for address;

    IAcrossSpokePool private immutable _acrossSpokePool;
    
    /// @notice Maximum allowed nav tolerance in basis points (100% = 10000 bps)
    uint256 private constant MAX_NAV_TOLERANCE_BPS = 10000;
    
    /// @notice Across MulticallHandler addresses
    address internal constant DEFAULT_MULTICALL_HANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
    address internal constant BSC_MULTICALL_HANDLER = 0xAC537C12fE8f544D712d71ED4376a502EEa944d7;

    address private immutable _aIntents;
    
    // Custom errors (inherit UnauthorizedCaller from interface)
    error NavToleranceTooHigh();
    error AdapterNotDeployedOnDestination();
    error DestinationPoolNotFound(address poolAddress);
    error OutputAmountValidationFailed(uint256 expected, uint256 provided, uint256 tolerance);

    modifier onlyDelegateCall() {
        require(address(this) != _aIntents, DirectCallNotAllowed());
        _;
    }

    /// @inheritdoc IMinimumVersion
    function requiredVersion() external pure override returns (string memory) {
        return "4.1.0";
    }

    constructor(address acrossSpokePoolAddress) {
        _acrossSpokePool = IAcrossSpokePool(acrossSpokePoolAddress);
        _aIntents = address(this);
    }

    /// @inheritdoc IAIntents
    function depositV3(AcrossParams calldata params) external override nonReentrant onlyDelegateCall {
        // sanity checks
        require(!params.inputToken.isAddressZero(), NullAddress());
        require(params.exclusiveRelayer.isAddressZero(), NullAddress());

        // Prevent same-chain transfers (destination must be different chain)
        require(params.destinationChainId != block.chainid, SameChainTransfer());

        // TODO: could use bitmask to assert the destination chainId is supported, so we can revert on
        // source instead of on destination if it not? although the following token assertion will revert
        // if new chain's output tokens are not mapped.

        // Validate bridgeable token restriction - ensure input and output tokens are compatible
        CrosschainLib.validateBridgeableTokenPair(params.inputToken, params.outputToken);

        // Validate source message parameters to prevent rogue input
        SourceMessageParams memory sourceMsg = abi.decode(params.message, (SourceMessageParams));

        // Validate nav tolerance is within reasonable limits
        require(sourceMsg.navTolerance <= MAX_NAV_TOLERANCE_BPS, NavToleranceTooHigh());

        // Validate operation type
        require(sourceMsg.opType == OpType.Transfer || sourceMsg.opType == OpType.Sync, InvalidOpType());

        // TODO: is this sanity check necessary? this because the transferFrom called by across will revert anyway
        // if the pool doesn't hold, or if the token is not active, not sure it would be a problem (we allow that
        // for same chain swaps) - as we only call the inputToken.safeApprove() which does not have impact if it is
        // a rogue token (won't be able to reenter the call anyway)? Or do we to push the token to active instead?
        if (params.inputToken != StorageLib.pool().baseToken) {
            require(StorageLib.activeTokensSet().isActive(params.inputToken), TokenNotActive());
        }

        _validateTokenAmounts(params);

        _safeApproveToken(params.inputToken);

        // Always use multicall handler approach for robust pool existence checking
        Instructions memory instructions = _buildMulticallInstructions(params, sourceMsg);
        _executeAcrossDeposit(params, sourceMsg, instructions);

        _safeApproveToken(params.inputToken);
    }

    /// @inheritdoc IAIntents
    function getEscrowAddress(OpType opType) external view onlyDelegateCall returns (address escrowAddress) {
        return EscrowFactory.getEscrowAddress(address(this), opType);
    }

    /*
     * INTERNAL METHODS
     */

    /// @dev Validates token amounts on the source chain to ensure output amount matches expected conversion.
    /// Virtual balance adjustments are handled separately in _executeAcrossDeposit based on opType.
    function _validateTokenAmounts(AcrossParams calldata params) private pure {
        // Apply BSC decimal conversion to get exact amount expected on destination
        uint256 expectedOutputAmount = CrosschainLib.applyBscDecimalConversion(
            params.inputToken,
            params.outputToken,
            params.inputAmount
        );

        // Validate that provided output amount matches expected (within 1% tolerance)
        uint256 tolerance = expectedOutputAmount / 100; // 1% tolerance for Across quote differences
        
        require(
            params.outputAmount >= expectedOutputAmount - tolerance &&
            params.outputAmount <= expectedOutputAmount + tolerance,
            OutputAmountValidationFailed(expectedOutputAmount, params.outputAmount, tolerance)
        );
    }

    function _buildMulticallInstructions(
        AcrossParams memory params,
        SourceMessageParams memory sourceMsg
    ) private view returns (Instructions memory) {
        Call[] memory calls = new Call[](4);

        // 1. Store pool's current token balance (for delta calculation)
        calls[0] = Call({
            target: address(this),
            callData: abi.encodeWithSelector(
                IEAcrossHandler.donate.selector,
                params.outputToken,
                1, // flag for temporary storing pool balance
                sourceMsg
            ),
            value: 0
        });

        // 2. Transfer expected amount to pool (no approval needed)
        calls[1] = Call({
            target: params.outputToken,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, params.recipient, params.outputAmount),
            value: 0
        });

        // 3. Drain any leftover tokens from MulticallHandler to pool before donating (need correct amount to unwrap)
        calls[2] = Call({
            target: _getAcrossHandler(params.destinationChainId),
            callData: abi.encodeWithSelector(
                IMulticallHandler.drainLeftoverTokens.selector,
                params.outputToken,
                params.recipient
            ),
            value: 0
        });

        // 4. Donate to pool with virtual balance management
        calls[3] = Call({
            target: address(this),
            callData: abi.encodeWithSelector(
                IEAcrossHandler.donate.selector,
                params.outputToken,
                params.outputAmount,
                sourceMsg
            ),
            value: 0
        });
        
        return Instructions({
            calls: calls,
            fallbackRecipient: address(0) // Revert on failure
        });
    }

    /// @dev Executes deposit via multicall handler
    function _executeAcrossDeposit(
        AcrossParams memory params,
        SourceMessageParams memory sourceMsg,
        Instructions memory instructions
    ) private {
        // Handle source-side virtual balance adjustments
        if (sourceMsg.opType == OpType.Transfer) {
            EscrowFactory.deployEscrowIfNeeded(address(this), OpType.Transfer);
            VirtualBalanceLib.adjustVirtualBalance(params.inputToken, params.inputAmount.toInt256());
        } else if (sourceMsg.opType == OpType.Sync) {
            NavImpactLib.validateNavImpactTolerance(params.inputToken, params.inputAmount, sourceMsg.navTolerance);
        }

        _acrossSpokePool.depositV3{value: sourceMsg.sourceNativeAmount}(
            sourceMsg.opType == OpType.Transfer
                ? EscrowFactory.getEscrowAddress(address(this), OpType.Transfer)
                : address(this),
            _getAcrossHandler(params.destinationChainId), // recipient on destination chain
            params.inputToken,
            params.outputToken,
            params.inputAmount,
            params.outputAmount,
            params.destinationChainId,
            address(0),
            params.quoteTimestamp,
            uint32(block.timestamp + _acrossSpokePool.fillDeadlineBuffer()),
            params.exclusivityDeadline,
            abi.encode(instructions)
        );
    }

    /// @dev Approves or revokes token approval. If already approved, revokes; otherwise approves max.
    function _safeApproveToken(address token) private {
        if (token.isAddressZero()) return; // Skip if native currency

        if (IERC20(token).allowance(address(this), address(_acrossSpokePool)) > 0) {
            // Reset to 0 first for tokens that require it (like USDT)
            token.safeApprove(address(_acrossSpokePool), 0);
        } else {
            // Approve max amount
            token.safeApprove(address(_acrossSpokePool), type(uint256).max);
        }
    }

    /// @dev Returns multicall handler address for given chain
    /// @dev As we map source and destination token, we will not use a non-existing handler on new chains.
    // TODO: Requires careful handling when supporting new chains, should revert if chain is not supported.
    // Could use bitmask flags of supported chains to assert that, so that when we add new chains, this will
    // revert if we do not modify the bitmask, which will prompt updating this method with the newly supported chain.
    function _getAcrossHandler(uint256 chainId) private pure returns (address) {
        // BSC uses different multicall handler
        if (chainId == 56) { // BSC
            return BSC_MULTICALL_HANDLER;
        }

        // Most chains use the standard multicall handler
        return DEFAULT_MULTICALL_HANDLER;
    }
}
