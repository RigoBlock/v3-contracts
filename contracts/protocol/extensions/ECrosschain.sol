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
        // We use amount for virtual supply (shares minted), but amountDelta for assets
        // This means surplus (amountDelta - amount) increases NAV for existing shareholders
        require(amountDelta >= amount, CallerTransferAmount());

        // Only allow tokens from our cross-chain whitelist (check before unwrapping)
        require(CrosschainLib.isAllowedCrosschainToken(token), CrosschainLib.UnsupportedCrossChainToken());

        address wrappedNative = ISmartPoolImmutable(address(this)).wrappedNative();

        if (token == wrappedNative && params.shouldUnwrapNative) {
            // amountDelta (actual balance delta) for unwrapping
            IWETH9(wrappedNative).withdraw(amountDelta);
            token = address(0);
        }

        // Single positions[token] read: returns whether token was already active AND adds it if not.
        bool previouslyActive = StorageLib.activeTokensSet().addAndCheckWasActive(
            IEOracle(address(this)),
            token,
            StorageLib.pool().baseToken
        );

        if (params.opType == OpType.Transfer) {
            // Update virtual supply with amount (expected value), surplus remains as NAV increase
            _updateVirtualSupply(token, amount);
        } else if (params.opType != OpType.Sync) {
            revert InvalidOpType();
        }

        // Validate NAV integrity (common to both Transfer and Sync modes)
        _validateNavIntegrity(token, amountDelta, storedBalance, previouslyActive);

        emit TokensReceived(msg.sender, token, amountDelta, uint8(params.opType));

        // Unlock donation and clear all temporary storage atomically
        token.setDonationLock(0);
        uint256(0).storeNav();
        uint256(0).storeAssets();
    }

    function _updateVirtualSupply(address token, uint256 amount) private {
        // This increases effective supply, keeping NAV unchanged
        address baseToken = StorageLib.pool().baseToken;

        // Convert amount to base token value for share calculation
        uint256 amountValueInBase = IEOracle(address(this))
            .convertTokenAmount(token, amount.toInt256(), baseToken)
            .toUint256();

        uint8 poolDecimals = StorageLib.pool().decimals;
        uint256 storedNav = TransientStorage.getStoredNav();

        // Calculate shares equivalent: amountValue / NAV = shares
        uint256 mintedAmount = ((amountValueInBase * (10 ** poolDecimals)) / storedNav);

        // Update virtual supply directly (works for both positive and negative current VS)
        mintedAmount.toInt256().updateVirtualSupply();
    }

    /// @dev Validates that NAV wasn't manipulated between the lock and finalize calls.
    /// @dev Ensures no internal transfers or unauthorized operations occurred during donation flow.
    /// @dev Updates state by calling `updateUnitaryValue` method in the pool proxy.
    function _validateNavIntegrity(
        address token,
        uint256 amountDelta,
        uint256 storedBalance,
        bool previouslyActive
    ) private {
        address baseToken = StorageLib.pool().baseToken;

        // Get current NAV state after the donation
        NetAssetsValue memory navParams = ISmartPoolActions(address(this)).updateUnitaryValue();

        // Calculate expected assets based on stored state + received amount
        uint256 expectedAssets = TransientStorage.getStoredAssets();

        if (!previouslyActive) {
            amountDelta += storedBalance;
        }

        if (amountDelta > 0) {
            expectedAssets += IEOracle(address(this))
                .convertTokenAmount(token, amountDelta.toInt256(), baseToken)
                .toUint256();
        }

        require(
            // slither-disable-next-line incorrect-equality
            navParams.netTotalValue == expectedAssets,
            NavManipulationDetected(expectedAssets, navParams.netTotalValue)
        );
    }
}
