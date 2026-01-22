// SPDX-License-Identifier: Apache-2.0-or-later
// solhint-disable-next-line
pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin-legacy/contracts/utils/math/SafeCast.sol";
import {IAcrossSpokePool} from "../../interfaces/IAcrossSpokePool.sol";
import {IMulticallHandler} from "../../interfaces/IMulticallHandler.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {ISmartPoolActions} from "../../interfaces/v4/pool/ISmartPoolActions.sol";
import {AddressSet, EnumerableSet} from "../../libraries/EnumerableSet.sol";
import {CrosschainLib} from "../../libraries/CrosschainLib.sol";
import {ReentrancyGuardTransient} from "../../libraries/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";
import {SlotDerivation} from "../../libraries/SlotDerivation.sol";
import {StorageLib} from "../../libraries/StorageLib.sol";
import {VirtualStorageLib} from "../../libraries/VirtualStorageLib.sol";
import {NavImpactLib} from "../../libraries/NavImpactLib.sol";
import {Call, DestinationMessageParams, Instructions, OpType, SourceMessageParams} from "../../types/Crosschain.sol";
import {EscrowFactory} from "../../libraries/EscrowFactory.sol";
import {NetAssetsValue} from "../../types/NavComponents.sol";
import {IEOracle} from "./interfaces/IEOracle.sol";
import {IAIntents} from "./interfaces/IAIntents.sol";
import {IECrosschain} from "./interfaces/IECrosschain.sol";
import {IMinimumVersion} from "./interfaces/IMinimumVersion.sol";

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
    using VirtualStorageLib for address;
    using VirtualStorageLib for int256;

    IAcrossSpokePool private immutable _acrossSpokePool;

    /// @notice Maximum allowed nav tolerance in basis points (100% = 10000 bps)
    uint256 private constant MAX_NAV_TOLERANCE_BPS = 10000;

    address private immutable _aIntents;

    error NavToleranceTooHigh();

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
        // Validate bridgeable token restriction - ensure input and output tokens are compatible
        // This also implicitly validates that neither inputToken nor outputToken is address(0)
        CrosschainLib.validateBridgeableTokenPair(params.inputToken, params.outputToken);

        // Validate exclusive relayer must be zero (we don't use exclusive relaying)
        require(params.exclusiveRelayer.isAddressZero(), NullAddress());

        // Prevent same-chain transfers (destination must be different chain)
        require(params.destinationChainId != block.chainid, SameChainTransfer());

        // Validate outputAmount is not zero or too small to prevent virtual supply calculation issues
        require(params.outputAmount > 0, InvalidAmount());

        // Validate source message parameters to prevent rogue input
        SourceMessageParams memory sourceParams = abi.decode(params.message, (SourceMessageParams));

        // Validate nav tolerance is within reasonable limits
        require(sourceParams.navTolerance <= MAX_NAV_TOLERANCE_BPS, NavToleranceTooHigh());

        // Ensure input token is active on source chain for cross-chain transfers
        // This simplifies logic and prevents manipulation via inactive tokens
        require(StorageLib.isOwnedToken(params.inputToken), TokenNotActive());

        _safeApproveToken(params.inputToken, sourceParams.sourceNativeAmount);

        // Always use multicall handler approach for robust pool existence checking
        Instructions memory instructions = _buildMulticallInstructions(params, sourceParams);
        _executeAcrossDeposit(params, sourceParams, instructions);

        _safeApproveToken(params.inputToken, sourceParams.sourceNativeAmount);
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
            callData: abi.encodeCall(IECrosschain.donate, (params.outputToken, 1, destParams)),
            value: 0
        });

        // 2. Transfer expected amount to pool (no approval needed)
        calls[1] = Call({
            target: params.outputToken,
            callData: abi.encodeCall(IERC20.transfer, (params.recipient, params.outputAmount)),
            value: 0
        });

        // 3. Drain any leftover tokens from MulticallHandler to pool before donating (need correct amount to unwrap)
        calls[2] = Call({
            target: CrosschainLib.getAcrossHandler(params.destinationChainId),
            callData: abi.encodeCall(
                IMulticallHandler.drainLeftoverTokens,
                (params.outputToken, payable(params.recipient))
            ),
            value: 0
        });

        // 4. Donate to pool with virtual supply management
        calls[3] = Call({
            target: address(this),
            callData: abi.encodeCall(IECrosschain.donate, (params.outputToken, params.outputAmount, destParams)),
            value: 0
        });

        return
            Instructions({
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
            _handleSourceTransfer(params);
            // Transfer mode: use escrow as depositor (for NAV-neutral refunds)
            params.depositor = EscrowFactory.deployEscrow(address(this), OpType.Transfer);
        } else if (sourceParams.opType == OpType.Sync) {
            NavImpactLib.validateNavImpact(params.inputToken, params.inputAmount, sourceParams.navTolerance);
            // Sync mode: NAV impacts both chains naturally (no VS offset on source)
            // Pool is depositor - failed intents return tokens directly, NAV restores naturally
            _handleSourceSync();
            params.depositor = address(this);
        } else {
            revert IECrosschain.InvalidOpType();
        }

        _acrossSpokePool.depositV3{value: sourceParams.sourceNativeAmount}(
            params.depositor,
            CrosschainLib.getAcrossHandler(params.destinationChainId),
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

        emit CrossChainTransferInitiated(
            msg.sender,
            params.destinationChainId,
            params.inputToken,
            params.inputAmount,
            uint8(sourceParams.opType),
            params.depositor // escrow address
        );
    }

    /// @dev Calculates the base token equivalent value of the output amount.
    /// @dev Handles BSC decimal conversion and oracle price lookup.
    /// @param params The across params containing token and amount info.
    /// @return outputValueInBase The output amount converted to base token value.
    /// @return baseToken The pool's base token address.
    function _getOutputValueInBase(AcrossParams memory params) private view returns (uint256 outputValueInBase, address baseToken) {
        // Scale outputAmount to inputToken decimals for proper comparison
        // (same token on different chains may have different decimals, e.g., BSC USDC)
        uint256 scaledOutputAmount = CrosschainLib.applyBscDecimalConversion(
            params.outputToken, // Amount is in this token's decimals
            params.inputToken, // Convert to this token's decimals
            params.outputAmount
        );

        // Convert output amount to base token value
        baseToken = StorageLib.pool().baseToken;
        outputValueInBase = IEOracle(address(this))
            .convertTokenAmount(params.inputToken, scaledOutputAmount.toInt256(), baseToken)
            .toUint256();
    }

    function _handleSourceTransfer(AcrossParams memory params) private {
        // VS-only model: Write negative VS on source (shares leaving this chain)
        // This reduces effective supply, keeping NAV unchanged

        // Get output value in base token terms
        (uint256 outputValueInBase, ) = _getOutputValueInBase(params);

        // Update NAV and get pool state for share calculation
        NetAssetsValue memory navParams = ISmartPoolActions(address(this)).updateUnitaryValue();
        uint8 poolDecimals = StorageLib.pool().decimals;

        // Calculate shares equivalent: outputValue / NAV = shares
        // shares = (outputValueInBase * 10^decimals) / unitaryValue
        int256 sharesLeaving = ((outputValueInBase * (10 ** poolDecimals)) / navParams.unitaryValue).toInt256();

        // Write negative VS (shares leaving this chain → reduces effective supply)
        (-sharesLeaving).updateVirtualSupply();
    }

    /// @dev Handles Sync mode: no virtual storage adjustments on source.
    /// @dev Sync is NAV-impacting on both chains - tokens leave source and arrive on destination.
    /// @dev No VS offset written, so NAV decreases on source and increases on destination.
    function _handleSourceSync() private pure {
        // Sync mode: no virtual storage adjustments on source
        // NAV impacts both chains naturally:
        // - Source: NAV decreases as tokens leave
        // - Destination: NAV increases as tokens arrive
        // This allows performance to flow correctly between chains.
    }

    /// @dev Approves or revokes token approval for SpokePool interaction.
    /// @dev Native ETH: When sourceNativeAmount > 0, ETH is sent via value parameter and WETH address is used as identifier.
    ///      In this case, skip approval since no ERC20 transfer occurs (only native value transfer).
    /// @dev ERC20: When sourceNativeAmount == 0, normal ERC20 approval flow (including WETH when used as ERC20).
    /// @param token The token address to approve (guaranteed non-zero by validateBridgeableTokenPair)
    /// @param sourceNativeAmount Native ETH amount being sent (0 for ERC20 transfers)
    function _safeApproveToken(address token, uint256 sourceNativeAmount) private {
        // Skip approval if sending native ETH with WETH wrapper (no ERC20 transfer)
        if (sourceNativeAmount > 0) return;

        if (IERC20(token).allowance(address(this), address(_acrossSpokePool)) > 0) {
            // Reset to 0 first for tokens that require it (like USDT)
            token.safeApprove(address(_acrossSpokePool), 0);
        } else {
            // Approve max amount
            token.safeApprove(address(_acrossSpokePool), type(uint256).max);
        }
    }

    // Note: acknowledgeVirtualBalanceLoss removed - VS-only model doesn't use VB
    // Failed Sync intents return tokens directly to pool (natural NAV restoration)
    // Failed Transfer intents go to escrow which refunds via ECrosschain (VS clearing)
}
