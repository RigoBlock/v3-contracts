// SPDX-License-Identifier: Apache-2.0-or-later
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
import {TransientSlot} from "../libraries/TransientSlot.sol";
import {TransientStorage} from "../libraries/TransientStorage.sol";
import {VirtualStorageLib} from "../libraries/VirtualStorageLib.sol";
import {NavImpactLib} from "../libraries/NavImpactLib.sol";
import {CrosschainLib} from "../libraries/CrosschainLib.sol";
import {DestinationMessageParams, OpType} from "../types/Crosschain.sol";
import {IEOracle} from "./adapters/interfaces/IEOracle.sol";
import {IEAcrossHandler} from "./adapters/interfaces/IEAcrossHandler.sol";

// TODO: rename in order to avoid confusing with across handler (this is called by the across multicall handler)
/// @title EAcrossHandler - Handles incoming cross-chain transfers via Across Protocol.
/// @notice This extension manages NAV integrity when receiving cross-chain token transfers.
/// @dev Called via delegatecall from pool when Across SpokePool or MulticallHandler delivers tokens.
/// @author Gabriele Rigo - <gab@rigoblock.com>
contract EAcrossHandler is IEAcrossHandler {
    using SafeCast for uint256;
    using SafeCast for int256;
    using SlotDerivation for bytes32;
    using EnumerableSet for AddressSet;
    using VirtualStorageLib for address;
    using VirtualStorageLib for int256;
    using TransientStorage for *;

    /// @notice Address of the Across SpokePool contract
    address private immutable _acrossSpokePool;

    /// @notice Across MulticallHandler addresses (for multicall-based transfers)
    address private immutable _acrossHandler;

    /// @dev Passed param is expected to be valid - skip validation
    constructor(address acrossSpokePool, address acrossMulticallHandler) {
        _acrossSpokePool = acrossSpokePool;
        _acrossHandler = acrossMulticallHandler;
    }

    error DonateTransferFromFailer();
    error TokenIsNotOwned();
    error IncorrectETHAmount();
    error NullAddresS();
    error CallerTransferAmount();

    /// @inheritdoc IEAcrossHandler
    function donate(address token, uint256 amount, DestinationMessageParams calldata params) external payable override {
        bool isLocked = TransientStorage.getDonationLock();
        uint256 balance = token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));

        // 1 is flag for initializing temp storage.
        if (amount == 1) {
            require(!isLocked, DonationLock(isLocked));
            token.setDonationLock(balance);

            // Update unitary value for both Sync and Transfer operations
            ISmartPoolActions(address(this)).updateUnitaryValue();

            // Store NAV for later manipulation check
            uint256 currentNav = ISmartPoolState(address(this)).getPoolTokens().unitaryValue;
            currentNav.storeNav();
            return;
        }

        // For actual donation processing
        require(isLocked, DonationLock(isLocked));

        (uint256 storedBalance, bool initialized) = token.getTemporaryBalance();
        require(initialized, TokenNotInitialized());

        // ensure balance didn't decrease
        require(balance >= storedBalance, BalanceUnderflow());

        uint256 amountDelta = balance - storedBalance;

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

        // If token not already owned, activate it (addUnique checks price feed requirement)
        if (!StorageLib.isOwnedToken(token)) {
            StorageLib.activeTokensSet().addUnique(IEOracle(address(this)), token, StorageLib.pool().baseToken);
        }

        if (params.opType == OpType.Transfer) {
            _handleTransferMode(token, amount, amountDelta);
        } else if (params.opType != OpType.Sync) {
            revert InvalidOpType();
        }

        // Unlock donation and clear all temporary storage atomically
        token.setDonationLock(0);
        uint256(0).storeNav();
    }

    function _handleTransferMode(address token, uint256 amount, uint256 amountDelta) private {
        // Use stored NAV from initialization for all calculations
        uint256 storedNav = TransientStorage.getStoredNav();

        uint8 poolDecimals = StorageLib.pool().decimals;
        address baseToken = StorageLib.pool().baseToken;

        // Check if positive virtual balances exist for this token
        int256 currentVirtualBalance = token.getVirtualBalance();
        uint256 remainingAmount = amount;

        if (currentVirtualBalance > 0) {
            // Reduce existing positive virtual balance (tokens coming back to this chain)
            uint256 virtualBalanceUint = currentVirtualBalance.toUint256();
            if (virtualBalanceUint >= remainingAmount) {
                // Sufficient virtual balance to cover net transfer amount
                token.updateVirtualBalance(-(remainingAmount.toInt256()));
                remainingAmount = 0; // No virtual supply increase needed
            } else {
                // Partial reduction of virtual balance, then increase virtual supply for remainder
                token.updateVirtualBalance(-currentVirtualBalance); // Zero it out
                remainingAmount = remainingAmount - virtualBalanceUint;
            }
        }

        // Increase virtual supply if there's remaining amount (cross-chain representation)
        if (remainingAmount > 0) {
            uint256 baseValue = IEOracle(address(this))
                .convertTokenAmount(token, remainingAmount.toInt256(), baseToken)
                .toUint256();

            // shares = baseValue / storedNav (in pool token units)
            uint256 virtualSupplyIncrease = (baseValue * (10 ** poolDecimals)) / storedNav;

            (virtualSupplyIncrease.toInt256()).updateVirtualSupply();
        }

        // Update NAV to reflect received tokens before validation
        ISmartPoolActions(address(this)).updateUnitaryValue();
        ISmartPoolState.PoolTokens memory poolTokens = ISmartPoolState(address(this)).getPoolTokens();
        uint256 finalNav = poolTokens.unitaryValue;
        uint256 expectedNav = storedNav;

        if (amountDelta > amount) {
            // Surplus exists (solver kept some value on destination) - this increases NAV
            uint256 surplusBaseValue = IEOracle(address(this))
                .convertTokenAmount(token, (amountDelta - amount).toInt256(), baseToken)
                .toUint256();

            // Calculate expected NAV increase: surplusValue / effectiveSupply
            poolTokens.totalSupply += VirtualStorageLib.getVirtualSupply().toUint256();

            // Safety check: Ensure total supply is not zero
            require(poolTokens.totalSupply > 0, "Effective total supply is zero - cannot calculate NAV increase");

            uint256 expectedNavIncrease = (surplusBaseValue * (10 ** poolDecimals)) / poolTokens.totalSupply;
            expectedNav = storedNav + expectedNavIncrease;
        }

        require(finalNav == expectedNav, NavManipulationDetected(expectedNav, finalNav));
    }
}
