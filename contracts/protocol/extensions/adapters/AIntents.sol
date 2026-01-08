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
import {Call, DestinationMessageParams, Instructions, OpType, SourceMessageParams} from "../../types/Crosschain.sol";
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
        SourceMessageParams memory sourceParams = abi.decode(params.message, (SourceMessageParams));

        // Validate nav tolerance is within reasonable limits
        require(sourceParams.navTolerance <= MAX_NAV_TOLERANCE_BPS, NavToleranceTooHigh());

        // Ensure input token is active on source chain for cross-chain transfers
        // This simplifies logic and prevents manipulation via inactive tokens
        require(StorageLib.isOwnedToken(params.inputToken), TokenNotActive());

        _safeApproveToken(params.inputToken);

        // Always use multicall handler approach for robust pool existence checking
        Instructions memory instructions = _buildMulticallInstructions(params, sourceParams);
        _executeAcrossDeposit(params, sourceParams, instructions);

        _safeApproveToken(params.inputToken);
    }

    /// @inheritdoc IAIntents
    function getEscrowAddress(OpType opType) external view onlyDelegateCall returns (address escrowAddress) {
        return EscrowFactory.getEscrowAddress(address(this), opType);
    }

    /*
     * INTERNAL METHODS
     */
    function _buildMulticallInstructions(
        AcrossParams memory params,
        SourceMessageParams memory sourceParams
    ) private view returns (Instructions memory) {
        Call[] memory calls = new Call[](4);
        DestinationMessageParams memory destParams = DestinationMessageParams({
            opType: sourceParams.opType,
            shouldUnwrapNative: sourceParams.shouldUnwrapOnDestination
        });

        // 1. Store pool's current token balance (for delta calculation)
        calls[0] = Call({
            target: address(this),
            callData: abi.encodeWithSelector(
                IEAcrossHandler.donate.selector,
                params.outputToken,
                1, // flag for temporary storing pool balance
                destParams
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
                destParams
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
        SourceMessageParams memory sourceParams,
        Instructions memory instructions
    ) private {
        // Handle source-side adjustments based on operation type
        if (sourceParams.opType == OpType.Transfer) {
            EscrowFactory.deployEscrowIfNeeded(address(this), OpType.Transfer);
            params.depositor = EscrowFactory.getEscrowAddress(address(this), OpType.Transfer);
            _handleSourceTransfer(params);
        } else if (sourceParams.opType == OpType.Sync) {
            params.depositor = address(this);
            NavImpactLib.validateNavImpact(params.inputToken, params.inputAmount, sourceParams.navTolerance);
        } else {
            revert InvalidOpType();
        }

        _acrossSpokePool.depositV3{value: sourceParams.sourceNativeAmount}(
            params.depositor,
            _getAcrossHandler(params.destinationChainId),
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

    function _handleSourceTransfer(AcrossParams memory params) private {
        // Scale outputAmount to inputToken decimals for proper comparison
        // (same token on different chains may have different decimals, e.g., BSC USDC)
        uint256 scaledOutputAmount = CrosschainLib.applyBscDecimalConversion(
            params.outputToken, // Amount is in this token's decimals
            params.inputToken,  // Convert to this token's decimals
            params.outputAmount
        );
        
        // Convert to base token value for supply calculations
        address baseToken = StorageLib.pool().baseToken;
        int256 outputValueInBaseInt = IEOracle(address(this)).convertTokenAmount(
            params.inputToken,
            scaledOutputAmount.toInt256(),
            baseToken
        );
        uint256 outputValueInBase = outputValueInBaseInt.toUint256();
        
        // Update NAV and get pool state
        ISmartPoolActions(address(this)).updateUnitaryValue();
        ISmartPoolState.PoolTokens memory poolTokens = ISmartPoolState(address(this)).getPoolTokens();
        uint256 virtualSupply = VirtualBalanceLib.getVirtualSupply().toUint256();
        uint8 poolDecimals = StorageLib.pool().decimals;
        
        // Convert transfer value to shares using current NAV (same as mint/burn calculation)
        // shares = baseValue / unitaryValue (in pool token units)
        uint256 sharesToBurn = (outputValueInBase * (10 ** poolDecimals)) / poolTokens.unitaryValue;
        
        if (virtualSupply > 0) {
            if (virtualSupply >= sharesToBurn) {
                // Sufficient virtual supply - burn the exact share amount
                VirtualBalanceLib.adjustVirtualSupply(-(sharesToBurn.toInt256()));
            } else {
                // Insufficient virtual supply - burn all of it, use virtual balance for remainder
                VirtualBalanceLib.adjustVirtualSupply(-(virtualSupply.toInt256()));
                
                // Calculate remaining value that wasn't covered by burning virtual supply
                uint256 remainingValue = ((sharesToBurn - virtualSupply) * poolTokens.unitaryValue) / (10 ** poolDecimals);
                
                // Convert remaining base value back to input token units using oracle
                int256 remainingTokensInt = IEOracle(address(this)).convertTokenAmount(
                    baseToken,
                    remainingValue.toInt256(),
                    params.inputToken
                );
                VirtualBalanceLib.adjustVirtualBalance(params.inputToken, remainingTokensInt);
            }
        } else {
            // No virtual supply - use virtual balance entirely to offset the transfer
            VirtualBalanceLib.adjustVirtualBalance(params.inputToken, scaledOutputAmount.toInt256());
        }
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
