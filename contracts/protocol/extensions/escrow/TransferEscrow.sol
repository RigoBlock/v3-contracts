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

import {IERC20} from "../../interfaces/IERC20.sol";
import {ISmartPoolActions} from "../../interfaces/v4/pool/ISmartPoolActions.sol";
import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";
import {VirtualBalanceLib} from "../../libraries/VirtualBalanceLib.sol";
import {OpType} from "../../types/Crosschain.sol";

/// @title TransferEscrow - Escrow contract for Transfer and Sync operation refunds
/// @notice Manages refunds from failed Transfer/Sync operations with NAV-neutral donations
/// @dev Combined escrow contract that handles both receive() and claimRefund() functionality
contract TransferEscrow {
    using SafeTransferLib for address;

    /// @notice Emitted when tokens are donated back to the pool
    event TokensDonated(address indexed token, uint256 amount);
    
    /// @notice The pool this escrow is associated with
    address public immutable pool;

    error TransferFailed();
    error InvalidAmount();

    constructor(address _pool) {
        require(_pool != address(0), "Invalid pool address");
        pool = _pool;
    }

    /// @notice Returns the operation type this escrow handles
    function opType() external pure returns (OpType) {
        return OpType.Transfer;
    }

    /// @notice Receives tokens (typically from refunds) and donates immediately
    receive() external payable {
        if (msg.value > 0) {
            // Donate immediately to pool to ensure proper virtual balance management
            ISmartPoolActions(pool).donate{value: msg.value}(address(0), msg.value);
            emit TokensDonated(address(0), msg.value);
        }
    }

    /// @notice Allows anyone to claim refund tokens and send them to the pool
    /// @param token The token address to claim (address(0) for native)
    function claimRefund(address token) external {
        uint256 balance;
        if (token == address(0)) {
            balance = address(this).balance;
        } else {
            balance = IERC20(token).balanceOf(address(this));
        }
        require(balance > 0, InvalidAmount());
        
        if (token == address(0)) {
            // For native currency, use the pool's donate function directly
            ISmartPoolActions(pool).donate{value: balance}(address(0), balance);
        } else {
            // Approve the pool to spend the tokens
            token.safeApprove(pool, balance);
            
            // Call the pool's donate function which handles NAV neutrality
            ISmartPoolActions(pool).donate(token, balance);
        }

        emit TokensDonated(token, balance);
    }
}