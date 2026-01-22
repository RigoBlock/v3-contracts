// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin-legacy/contracts/utils/math/SafeCast.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {ISmartPoolActions} from "../interfaces/v4/pool/ISmartPoolActions.sol";
import {ISmartPoolImmutable} from "../interfaces/v4/pool/ISmartPoolImmutable.sol";
import {ISmartPoolState} from "../interfaces/v4/pool/ISmartPoolState.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";
import {CrosschainLib} from "../libraries/CrosschainLib.sol";
import {AddressSet, EnumerableSet} from "../libraries/EnumerableSet.sol";
import {ReentrancyGuardTransient} from "../libraries/ReentrancyGuardTransient.sol";
import {SlotDerivation} from "../libraries/SlotDerivation.sol";
import {StorageLib} from "../libraries/StorageLib.sol";
import {TransientStorage} from "../libraries/TransientStorage.sol";
import {VirtualStorageLib} from "../libraries/VirtualStorageLib.sol";
import {DestinationMessageParams, OpType} from "../types/Crosschain.sol";
import {NetAssetsValue} from "../types/NavComponents.sol";
import {IEOracle} from "./adapters/interfaces/IEOracle.sol";
import {IECrosschain} from "./adapters/interfaces/IECrosschain.sol";

/// @title ECrosschain - Handles incoming cross-chain transfers and escrow refunds.
/// @notice This extension manages NAV integrity when receiving tokens from cross-chain sources.
/// @dev Called via delegatecall from pool. Can be called by Across messages, Escrow contracts, or anyone with tokens to donate.
/// @dev Direct calls will fail naturally because the contract does not implement `updateUnitaryValue`.
/// @author Gabriele Rigo - <gab@rigoblock.com>
contract ECrosschain is IECrosschain, ReentrancyGuardTransient {
    using SafeCast for uint256;
    using SafeCast for int256;
    using SlotDerivation for bytes32;
    using EnumerableSet for AddressSet;
    using VirtualStorageLib for address;
    using VirtualStorageLib for int256;
    using TransientStorage for *;

    error CallerTransferAmount();

    /// @inheritdoc IECrosschain
    function donate(
        address token,
        uint256 amount,
        DestinationMessageParams calldata params
    ) external override nonReentrant {
        bool isLocked = TransientStorage.getDonationLock();
        uint256 balance = token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));

        // 1 is flag for initializing temp storage.
        if (amount == 1) {
            require(!isLocked, DonationLock(isLocked));
            token.setDonationLock(balance);

            // If token has pre-existing balance but isn't active, it won't be in storedAssets
            NetAssetsValue memory navParams = ISmartPoolActions(address(this)).updateUnitaryValue();
            navParams.unitaryValue.storeNav();
            navParams.netTotalValue.storeAssets();
            return;
        }

        // For actual donation processing
        require(isLocked, DonationLock(isLocked));

        (uint256 storedBalance, bool initialized) = token.getTemporaryBalance();
        require(initialized, TokenNotInitialized());

        // ensure balance didn't decrease
        require(balance >= storedBalance, BalanceUnderflow());
        uint256 amountDelta;

        unchecked {
            amountDelta = balance - storedBalance;
        }

        // For bridge transactions, amountDelta will be >= amount due to solver surplus
        // We use amountDelta for virtual balance (captures full value)
        // and amount for validation that we got at least what was expected
        require(amountDelta >= amount, CallerTransferAmount());

        // Only allow tokens from our cross-chain whitelist (check before unwrapping)
        require(CrosschainLib.isAllowedCrosschainToken(token), CrosschainLib.UnsupportedCrossChainToken());

        address wrappedNative = ISmartPoolImmutable(address(this)).wrappedNative();

        if (token == wrappedNative && params.shouldUnwrapNative) {
            // amountDelta (actual balance delta) for unwrapping
            IWETH9(wrappedNative).withdraw(amountDelta);
            token = address(0);
        }

        // define a boolean to be used in nav manipulation assertion
        bool previouslyActive = StorageLib.isOwnedToken(token);

        // Only activate after token transfer. Token could be already active, but addUnique is idempotent.
        StorageLib.activeTokensSet().addUnique(IEOracle(address(this)), token, StorageLib.pool().baseToken);

        if (params.opType == OpType.Transfer) {
            _handleTransferMode(token, amount, amountDelta, storedBalance, previouslyActive);
        } else if (params.opType == OpType.Sync) {
            _handleSyncMode(token, amount, params.syncMultiplier);
        } else {
            // Only Transfer and Sync are valid - reject anything else
            revert InvalidOpType();
        }

        emit TokensReceived(
            msg.sender,
            token,
            amountDelta,
            uint8(params.opType)
        );

        // Unlock donation and clear all temporary storage atomically
        token.setDonationLock(0);
        uint256(0).storeNav();
        uint256(0).storeAssets();
    }

    function _handleTransferMode(
        address token,
        uint256 amount,
        uint256 amountDelta,
        uint256 storedBalance,
        bool previouslyActive
    ) private {
        address baseToken = StorageLib.pool().baseToken;

        // Convert amount to base token value - reuse 'amount' variable for amountValueInBase
        amount = IEOracle(address(this)).convertTokenAmount(token, amount.toInt256(), baseToken).toUint256();

        // Reuse 'storedBalance' for vbReductionValueInBase tracking
        // Save original storedBalance in amountDelta temporarily (we'll restore it later)
        if (!previouslyActive) {
            amountDelta += storedBalance;
        }
        storedBalance = 0; // Now use storedBalance for vbReductionValueInBase

        // Manage virtual balances - currentBaseTokenVB is reused later
        int256 currentBaseTokenVB = baseToken.getVirtualBalance();

        if (currentBaseTokenVB > 0) {
            // amount holds amountValueInBase, check against VB
            if (amount >= currentBaseTokenVB.toUint256()) {
                baseToken.updateVirtualBalance(-currentBaseTokenVB);
                storedBalance = currentBaseTokenVB.toUint256(); // vbReductionValueInBase
                amount -= storedBalance; // amount now holds remainingValueInBase
            } else {
                baseToken.updateVirtualBalance(-(amount.toInt256()));
                storedBalance = amount; // vbReductionValueInBase
                amount = 0; // remainingValueInBase is 0
            }
        }

        // If remaining value > 0, update virtual supply (amount holds remainingValueInBase)
        if (amount > 0) {
            // Reuse currentBaseTokenVB for virtualSupplyIncrease calculation
            currentBaseTokenVB = ((amount * (10 ** StorageLib.pool().decimals)) / TransientStorage.getStoredNav())
                .toInt256();
            currentBaseTokenVB.updateVirtualSupply();
        }

        NetAssetsValue memory navParams = ISmartPoolActions(address(this)).updateUnitaryValue();

        // Reuse 'amount' for storedAssets
        amount = TransientStorage.getStoredAssets();

        // Convert amountDelta to base and subtract VB reduction
        if (amountDelta > 0) {
            // Reuse currentBaseTokenVB for amountDeltaValueInBase
            currentBaseTokenVB = IEOracle(address(this)).convertTokenAmount(token, amountDelta.toInt256(), baseToken);

            // storedBalance holds vbReductionValueInBase
            amount += currentBaseTokenVB.toUint256() - storedBalance;
        }

        require(navParams.netTotalValue == amount, NavManipulationDetected(amount, navParams.netTotalValue));
    }

    /// @dev Handles Sync mode: clears positive VB up to the neutralized amount from source.
    /// @dev The neutralized amount (amount * syncMultiplier / 10000) can clear VB.
    /// @dev Any remaining received value (non-neutralized + VB not cleared) increases NAV naturally.
    /// @param token The token received.
    /// @param amount The received amount (in token units).
    /// @param syncMultiplier Percentage (0-10000 bps) that was neutralized on source via VB offset.
    function _handleSyncMode(address token, uint256 amount, uint256 syncMultiplier) private {
        // 0% multiplier = no VB clearing (legacy behavior: NAV increases by full received amount)
        if (syncMultiplier == 0) return;

        address baseToken = StorageLib.pool().baseToken;

        // Convert received amount to base token value
        uint256 amountInBase = IEOracle(address(this))
            .convertTokenAmount(token, amount.toInt256(), baseToken)
            .toUint256();

        // Calculate neutralized amount (same calculation as source)
        uint256 neutralizedAmount = (amountInBase * syncMultiplier) / 10000;

        // Clear positive VB up to neutralized amount
        // This allows NAV to increase by the received tokens minus VB cleared
        int256 currentVB = baseToken.getVirtualBalance();

        if (currentVB > 0 && neutralizedAmount > 0) {
            uint256 currentVBUint = currentVB.toUint256();
            uint256 vbToClear = neutralizedAmount > currentVBUint ? currentVBUint : neutralizedAmount;
            baseToken.updateVirtualBalance(-(vbToClear.toInt256()));
        }
        // Remaining value (received tokens - VB cleared) increases NAV naturally
        // No additional VS adjustment needed - performance flows correctly
    }
}
