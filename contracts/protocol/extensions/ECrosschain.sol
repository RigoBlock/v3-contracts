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
            (uint256 nav, uint256 currentAssets, ) = ISmartPoolActions(address(this)).updateUnitaryValue();
            nav.storeNav();
            currentAssets.storeAssets();
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

        // TODO: seems we could optimize, as we're going to read pool tokens slot twice, but probably out of scope for now
        // define a boolean to be used in nav manipulation assertion
        bool previouslyActive = StorageLib.isOwnedToken(token);

        // Only activate after token transfer. Token could be already active, but addUnique is idempotent.
        StorageLib.activeTokensSet().addUnique(IEOracle(address(this)), token, StorageLib.pool().baseToken);

        if (params.opType == OpType.Transfer) {
            _handleTransferMode(token, amount, amountDelta, storedBalance, previouslyActive);
        } else if (params.opType != OpType.Sync) {
            // Only Transfer and Sync are valid - reject anything else
            revert InvalidOpType();
        }
        // Sync mode: Token activated, NAV updated, but no virtual storage modification
        // Virtual storage only tracks cross-chain transfers (Transfer), not performance (Sync)

        emit TokensReceived(
            address(this), // pool
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
        
        // Use amount (donated) for virtual supply tracking
        uint256 amountValueInBase = IEOracle(address(this))
            .convertTokenAmount(token, amount.toInt256(), baseToken)
            .toUint256();
        
        // Track how much virtual balance was reduced (affects asset validation)
        uint256 vbReductionValueInBase = 0;
        
        // Manage virtual balances and supply with donated amount
        int256 currentBaseTokenVB = baseToken.getVirtualBalance();
        uint256 remainingValueInBase = amountValueInBase;

        if (currentBaseTokenVB > 0) {
            uint256 baseTokenVBUint = currentBaseTokenVB.toUint256();
            if (amountValueInBase >= baseTokenVBUint) {
                baseToken.updateVirtualBalance(-currentBaseTokenVB);
                remainingValueInBase = amountValueInBase - baseTokenVBUint;
                vbReductionValueInBase = baseTokenVBUint;
            } else {
                baseToken.updateVirtualBalance(-(amountValueInBase.toInt256()));
                remainingValueInBase = 0;
                vbReductionValueInBase = amountValueInBase;
            }
        }

        if (remainingValueInBase > 0) {
            uint256 storedNav = TransientStorage.getStoredNav();
            uint256 virtualSupplyIncrease = (remainingValueInBase * (10 ** StorageLib.pool().decimals)) / storedNav;
            (virtualSupplyIncrease.toInt256()).updateVirtualSupply();
        }

        (, uint256 finalAssets, ) = ISmartPoolActions(address(this)).updateUnitaryValue();

        uint256 storedAssets = TransientStorage.getStoredAssets();

        // Two cases:
        // 1. Token was already active → storedAssets includes storedBalance, only add amountDelta
        // 2. Token was NOT active → storedAssets excludes storedBalance, add full balance (storedBalance + amountDelta)
        if (!previouslyActive) {
            // Case 2: Add full current balance
            amountDelta += storedBalance;
        }

        // Convert the delta to base token and add to expected assets (skip oracle call if no change)
        // Subtract any VB reduction since that's already reflected in finalAssets via updateUnitaryValue
        if (amountDelta > 0) {
            uint256 amountDeltaValueInBase = IEOracle(address(this))
                .convertTokenAmount(token, amountDelta.toInt256(), baseToken)
                .toUint256();
            
            // VB reduction is already reflected in finalAssets, so don't double-count
            // Note: amountDeltaValueInBase >= vbReductionValueInBase is always true because:
            // - VB reduction is capped by amountValueInBase (converted from amount)
            // - We require amountDelta >= amount (line 75), so amountDeltaValueInBase >= vbReductionValueInBase
            storedAssets += amountDeltaValueInBase - vbReductionValueInBase;
        }

        require(finalAssets == storedAssets, NavManipulationDetected(storedAssets, finalAssets));
    }
}
