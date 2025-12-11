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
import {ReentrancyGuardTransient} from "../../libraries/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";
import {SlotDerivation} from "../../libraries/SlotDerivation.sol";
import {StorageLib} from "../../libraries/StorageLib.sol";
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

    IAcrossSpokePool public immutable override acrossSpokePool;
    
    // Re-export types from interface for external use
    enum MessageType {
        Transfer,
        Rebalance
    }
    
    struct CrossChainMessage {
        MessageType messageType;
        uint256 sourceNav;
        uint8 sourceDecimals;
        uint256 navTolerance;
        bool unwrapNative;
    }

    // Storage slot constants from MixinConstants
    bytes32 private constant _POOL_INIT_SLOT = 0xe48b9bb119adfc3bccddcc581484cc6725fe8d292ebfcec7d67b1f93138d8bd8;
    bytes32 private constant _TOKEN_REGISTRY_SLOT = 0x3dcde6752c7421366e48f002bbf8d6493462e0e43af349bebb99f0470a12300d;
    bytes32 private constant _VIRTUAL_BALANCES_SLOT = 0x19797d8be84f650fe18ebccb97578c2adb7abe9b7c86852694a3ceb69073d1d1;
    address private constant _ZERO_ADDRESS = address(0);

    address private immutable _wrappedNative;
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
        _wrappedNative = acrossSpokePool.wrappedNativeToken();
        _IMPLEMENTATION = address(this);
    }

    /// @inheritdoc IAIntents
    function depositV3(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes memory message
    ) external payable nonReentrant onlyDelegateCall {
        // Ignore some parameters as we enforce our own values for security
        depositor; recipient; exclusiveRelayer; quoteTimestamp; exclusivityDeadline;
        
        require(_isOwnedToken(inputToken), TokenIsNotOwned());
        
        // Calculate fillDeadlineBuffer from fillDeadline
        uint32 fillDeadlineBuffer = fillDeadline > uint32(block.timestamp) 
            ? fillDeadline - uint32(block.timestamp) 
            : 300; // Default 5 minutes
        
        // Prepare input token and handle wrapping
        (address token, uint256 msgValue) = _prepareInputToken(inputToken, inputAmount);
        
        // Process message and virtual balances
        message = _processMessage(message, token, inputAmount);
        
        // Execute deposit
        _executeDeposit(token, outputToken, inputAmount, outputAmount, destinationChainId, fillDeadlineBuffer, message, msgValue);
    }
    
    /// @dev Prepares input token (handles wrapping) and returns token address and msg.value.
    function _prepareInputToken(address inputToken, uint256 amount) private returns (address, uint256) {
        bool isSendNative = inputToken == _ZERO_ADDRESS;
        if (isSendNative) {
            _wrapNativeIfNeeded(amount);
            return (_wrappedNative, amount);
        }
        return (inputToken, 0);
    }
    
    /// @dev Executes the actual Across deposit.
    function _executeDeposit(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        uint32 fillDeadlineBuffer,
        bytes memory messageData,
        uint256 msgValue
    ) private {
        _safeApproveToken(inputToken, address(acrossSpokePool));
        
        acrossSpokePool.depositV3{value: msgValue}(
            address(this),
            address(this),
            inputToken,
            outputToken,
            inputAmount,
            outputAmount,
            destinationChainId,
            _ZERO_ADDRESS,
            uint32(block.timestamp),
            uint32(block.timestamp + fillDeadlineBuffer),
            0,
            messageData
        );
        
        _safeApproveToken(inputToken, address(acrossSpokePool));
    }
    
    /// @dev Processes message and adjusts virtual balances if needed.
    function _processMessage(
        bytes memory messageData,
        address inputToken,
        uint256 inputAmount
    ) private returns (bytes memory) {
        CrossChainMessage memory params = abi.decode(messageData, (CrossChainMessage));
        
        if (params.messageType == MessageType.Transfer) {
            _adjustVirtualBalanceForTransfer(inputToken, inputAmount);
            return messageData;
        }
        
        return _updateMessageForRebalance(params);
    }
    
    /// @dev Adjusts virtual balance for Transfer mode.
    function _adjustVirtualBalanceForTransfer(address inputToken, uint256 inputAmount) private {
        address baseToken = StorageLib.pool().baseToken;
        int256 baseTokenAmount = IEOracle(address(this)).convertTokenAmount(
            inputToken,
            inputAmount.toInt256(),
            baseToken
        );
        _setVirtualBalance(baseToken, _getVirtualBalance(baseToken) + baseTokenAmount);
    }
    
    /// @dev Updates message with NAV for Rebalance mode.
    function _updateMessageForRebalance(CrossChainMessage memory params) private returns (bytes memory) {
        // Update NAV first to get current value (not stale storage value)
        ISmartPoolActions(address(this)).updateUnitaryValue();
        
        // Now read the updated NAV from storage
        ISmartPoolState.PoolTokens memory poolTokens = ISmartPoolState(address(this)).getPoolTokens();
        params.sourceNav = poolTokens.unitaryValue;
        params.sourceDecimals = StorageLib.pool().decimals;
        return abi.encode(params);
    }
    
    /*
     * KNOWN LIMITATION: Token Recovery
     * 
     * Across Protocol V3 does not provide a direct method to reclaim tokens from unfilled deposits.
     * The speedUpV3Deposit method can update parameters but has a critical limitation:
     * "If a deposit has been completed already, this function will not revert but it won't be able 
     * to be filled anymore with the updated params."
     * 
     * This creates a NAV inflation risk:
     * 1. Pool owner creates deposit with very short deadline (e.g., 1 second)
     * 2. Deposit likely remains unfilled
     * 3. Owner calls speedUpV3Deposit, modifying virtual balances
     * 4. If deposit was already filled, tokens don't return but virtual balances are adjusted
     * 5. Result: NAV is artificially inflated
     * 
     * MITIGATION:
     * - We intentionally DO NOT implement token recovery via speedUpV3Deposit
     * - Pool operators should set reasonable fillDeadline values (recommended: 5-30 minutes)
     * - With proper parameters, Across fills deposits within seconds to minutes
     * - If a deposit fails, the locked tokens are effectively lost (extremely rare with correct setup)
     * 
     * FUTURE IMPROVEMENT:
     * - Monitor Across Protocol for native recovery mechanisms
     * - Consider implementing recovery if Across adds safe claim-back functionality
     * - Could implement recovery with additional safeguards (e.g., require proof deposit wasn't filled)
     */

    /*
     * INTERNAL METHODS
     */

    /// @dev Wraps native currency into wrapped native if pool doesn't have enough balance.
    function _wrapNativeIfNeeded(uint256 amount) private {
        uint256 balance = IERC20(_wrappedNative).balanceOf(address(this));
        if (balance < amount) {
            uint256 toWrap = amount - balance;
            require(address(this).balance >= toWrap, InsufficientWrappedNativeBalance());
            IWETH9(_wrappedNative).deposit{value: toWrap}();
        }
    }

    /// @dev Approves or revokes token approval. If already approved, revokes; otherwise approves max.
    function _safeApproveToken(address token, address spender) private {
        uint256 currentAllowance = IERC20(token).allowance(address(this), spender);
        if (currentAllowance > 0) {
            // Reset to 0 first for tokens that require it
            token.safeApprove(spender, 0);
        } else {
            // Approve max amount
            token.safeApprove(spender, type(uint256).max);
        }
    }

    /// @dev Gets the virtual balance for a token from storage.
    function _getVirtualBalance(address token) private view returns (int256 value) {
        bytes32 slot = _VIRTUAL_BALANCES_SLOT.deriveMapping(token);
        assembly {
            value := sload(slot)
        }
    }

    /// @dev Sets the virtual balance for a token.
    function _setVirtualBalance(address token, int256 value) private {
        bytes32 slot = _VIRTUAL_BALANCES_SLOT.deriveMapping(token);
        assembly {
            sstore(slot, value)
        }
    }

    /// @dev Checks if a token is owned by the pool.
    function _isOwnedToken(address token) private view returns (bool) {
        AddressSet storage activeTokens = StorageLib.activeTokensSet();
        address baseToken = StorageLib.pool().baseToken;
        
        // Base token and native currency are always owned
        if (token == baseToken || token == _ZERO_ADDRESS || token == _wrappedNative) {
            return true;
        }
        
        return activeTokens.isActive(token);
    }
}
