// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin-legacy/contracts/utils/math/SafeCast.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {ISmartPoolActions} from "../interfaces/v4/pool/ISmartPoolActions.sol";
import {ISmartPoolImmutable} from "../interfaces/v4/pool/ISmartPoolImmutable.sol";
import {ISmartPoolState} from "../interfaces/v4/pool/ISmartPoolState.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";
import {AddressSet, EnumerableSet} from "../libraries/EnumerableSet.sol";
import {ReentrancyGuardTransient} from "../libraries/ReentrancyGuardTransient.sol";
import {SlotDerivation} from "../libraries/SlotDerivation.sol";
import {StorageLib} from "../libraries/StorageLib.sol";
import {TransientStorage} from "../libraries/TransientStorage.sol";
import {VirtualStorageLib} from "../libraries/VirtualStorageLib.sol";
import {CrosschainLib} from "../libraries/CrosschainLib.sol";
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
            uint256 currentNav;
            // TODO: check if should pass slot as first param (although will need to define extra using lib for)
            (currentNav, balance) = CrosschainLib.checkAndUpdateUnitaryValue(token, balance, StorageLib.POOL_TOKENS_SLOT);
            token.setDonationLock(balance);
            currentNav.storeNav();
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

        // Activate token (addUnique checks price feed requirement and skips if already added)
        StorageLib.activeTokensSet().addUnique(IEOracle(address(this)), token, StorageLib.pool().baseToken);

        if (params.opType == OpType.Transfer) {
            _handleTransferMode(token, amount, amountDelta);
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
    }

    function _handleTransferMode(address token, uint256 amount, uint256 amountDelta) private {
        // Use stored NAV from initialization for all calculations
        uint256 storedNav = TransientStorage.getStoredNav();

        uint8 poolDecimals = StorageLib.pool().decimals;
        address baseToken = StorageLib.pool().baseToken;

        // Convert amount to base token units once at the start to avoid repeated conversions
        uint256 amountValueInBase = IEOracle(address(this))
            .convertTokenAmount(token, amount.toInt256(), baseToken)
            .toUint256();

        // This represents tokens previously transferred OUT from this chain
        int256 currentBaseTokenVB = baseToken.getVirtualBalance();
        uint256 remainingValueInBase = amountValueInBase;

        if (currentBaseTokenVB > 0) {
            uint256 baseTokenVBUint = currentBaseTokenVB.toUint256();

            if (amountValueInBase >= baseTokenVBUint) {
                // Sufficient value to fully clear base token VB
                baseToken.updateVirtualBalance(-currentBaseTokenVB);
                // Calculate remaining value after clearing VB (already in base token units)
                remainingValueInBase = amountValueInBase - baseTokenVBUint;
            } else {
                // Partial reduction of base token VB
                baseToken.updateVirtualBalance(-(amountValueInBase.toInt256()));
                remainingValueInBase = 0; // No virtual supply increase needed
            }
        }

        // Increase virtual supply if there's remaining value
        if (remainingValueInBase > 0) {
            uint256 virtualSupplyIncrease = (remainingValueInBase * (10 ** poolDecimals)) / storedNav;
            (virtualSupplyIncrease.toInt256()).updateVirtualSupply();
        }

        // Update NAV to reflect received tokens before validation
        uint256 finalNav = ISmartPoolActions(address(this)).updateUnitaryValue();

        // Get effective supply for validation (real + virtual)
        ISmartPoolState.PoolTokens memory poolTokens = ISmartPoolState(address(this)).getPoolTokens();
        poolTokens.totalSupply += VirtualStorageLib.getVirtualSupply().toUint256();

        // TODO: this should always be true by design, because we add virtual supply. Verify if the require is necessary (could be simple assert)
        // Safety check: Ensure total supply is not zero for NAV calculations
        require(poolTokens.totalSupply > 0, EffectiveSupplyZero());

        if (amountDelta > amount) {
            uint256 surplusBaseValue = IEOracle(address(this))
                .convertTokenAmount(token, (amountDelta - amount).toInt256(), baseToken)
                .toUint256();
            storedNav += (surplusBaseValue * (10 ** poolDecimals)) / poolTokens.totalSupply;
        }

        require(finalNav == storedNav, NavManipulationDetected(storedNav, finalNav));
    }
}
