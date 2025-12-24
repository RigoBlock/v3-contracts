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
import {ISmartPoolActions} from "../interfaces/v4/pool/ISmartPoolActions.sol";
import {ISmartPoolImmutable} from "../interfaces/v4/pool/ISmartPoolImmutable.sol";
import {ISmartPoolState} from "../interfaces/v4/pool/ISmartPoolState.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";
import {AddressSet, EnumerableSet} from "../libraries/EnumerableSet.sol";
import {SlotDerivation} from "../libraries/SlotDerivation.sol";
import {StorageLib} from "../libraries/StorageLib.sol";
import {TransientSlot} from "../libraries/TransientSlot.sol";
import {TransientStorage} from "../libraries/TransientStorage.sol";
import {VirtualBalanceLib} from "../libraries/VirtualBalanceLib.sol";
import {NavImpactLib} from "../libraries/NavImpactLib.sol";
import {OpType, SourceMessageParams} from "../types/Crosschain.sol";
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
    using TransientSlot for *;
    using EnumerableSet for AddressSet;
    using VirtualBalanceLib for address;

    /// @notice Address of the Across SpokePool contract
    address private immutable _acrossSpokePool;
    
    /// @notice Across MulticallHandler addresses (for multicall-based transfers)
    address private immutable _acrossHandler;
    
    /// @notice Storage slot for temporary balance tracking
    bytes32 private constant _TEMP_BALANCE_SLOT = bytes32(uint256(keccak256("eacross.temp.balance")) - 1);
    
    /// @notice Storage slot for donation lock tracking (boolean)
    bytes32 private constant _DONATION_LOCK_SLOT = bytes32(uint256(keccak256("eacross.donation.lock")) - 1);
    
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
    error DonationLock(bool locked);
    error BalanceUnderflow();
    error NavManipulationDetected(uint256 expectedNav, uint256 actualNav);

    /// @inheritdoc IEAcrossHandler
    function donate(address token, uint256 amount, SourceMessageParams calldata params) external payable override {
        bool isLocked = _getDonationLock(token);

        // 1 is flag for initializing temp storage.
        if (amount == 1) {
            require(!isLocked, DonationLock(isLocked));
            _setDonationLock(token, true);

            _storeTemporaryBalance(token);

            // Update unitary value for both Sync and Transfer operations
            ISmartPoolActions(address(this)).updateUnitaryValue();
            return;
        }

        // For actual donation processing
        require(isLocked, DonationLock(isLocked));

        uint256 currentBalance = token == address(0)
            ? address(this).balance
            : IERC20(token).balanceOf(address(this));
        uint256 storedBalance = _getTemporaryBalance(token);

        // Explicit check: ensure balance didn't decrease (clearer error than underflow)
        require(currentBalance >= storedBalance, BalanceUnderflow());

        uint256 amountDelta = currentBalance - storedBalance;

        // For bridge transactions, amountDelta will be >= amount due to solver surplus
        // We use amountDelta for virtual balance (captures full value) 
        // and amount for validation that we got at least what was expected
        require(amountDelta >= amount, CallerTransferAmount());

        _clearTemporaryBalance(token);
        _setDonationLock(token, false); // Reset lock

        address wrappedNative = ISmartPoolImmutable(address(this)).wrappedNative();

        if (token == wrappedNative && params.shouldUnwrapOnDestination) {
            // amountDelta (actual balance delta) for unwrapping
            IWETH9(wrappedNative).withdraw(amountDelta);
            token = address(0);
        }

        if (params.opType == OpType.Sync) {
            // validate nav impact on nav updated before the transfer, changing `token` context when unwrapping native
            require(_isOwnedToken(token), TokenIsNotOwned());
            NavImpactLib.validateNavImpactTolerance(token, amountDelta, params.navTolerance);
        } else {
            // For Transfer: Implement NAV integrity protection
            // Read NAV from permanent storage (updated in amount==1 call)
            uint256 expectedNav = ISmartPoolState(address(this)).getPoolTokens().unitaryValue;
            
            // Step 1: Apply virtual balance adjustment for full received amount
            VirtualBalanceLib.adjustVirtualBalance(token, -(amountDelta.toInt256()));
            
            // Step 2: Update NAV and assert unchanged - validates legitimate external transfer
            ISmartPoolActions(address(this)).updateUnitaryValue();
            uint256 currentNav = ISmartPoolState(address(this)).getPoolTokens().unitaryValue;
            require(currentNav == expectedNav, NavManipulationDetected(expectedNav, currentNav));
            
            // Step 3: Adjust back by expected amount, leaving only surplus offset
            VirtualBalanceLib.adjustVirtualBalance(token, (amountDelta - amount).toInt256());
        }
    }

    function _getDonationLock(address token) private view returns (bool) {
        bytes32 slot = _DONATION_LOCK_SLOT.deriveMapping(token);
        return slot.asBoolean().tload();
    }
    
    function _setDonationLock(address token, bool locked) private {
        bytes32 slot = _DONATION_LOCK_SLOT.deriveMapping(token);
        slot.asBoolean().tstore(locked);
    }

    function _storeTemporaryBalance(address token) private {
        uint256 currentBalance = token == address(0)
            ? address(this).balance
            : IERC20(token).balanceOf(address(this));
            
        bytes32 slot = _TEMP_BALANCE_SLOT.deriveMapping(token);
        slot.asUint256().tstore(currentBalance);
    }

    function _clearTemporaryBalance(address token) private {
        bytes32 slot = _TEMP_BALANCE_SLOT.deriveMapping(token);
        slot.asUint256().tstore(0);
    }

    function _getTemporaryBalance(address token) private view returns (uint256) {
        bytes32 slot = _TEMP_BALANCE_SLOT.deriveMapping(token);
        return slot.asUint256().tload();
    }

    /// @dev Checks if a token is owned by the pool.
    function _isOwnedToken(address token) private view returns (bool) {
        AddressSet storage activeTokens = StorageLib.activeTokensSet();
        address baseToken = StorageLib.pool().baseToken;
        
        // Base token is always owned
        if (token == baseToken) {
            return true;
        }
        
        // Check if token is in active tokens set
        return activeTokens.isActive(token);
    }
}
