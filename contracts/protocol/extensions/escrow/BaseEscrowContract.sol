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
import {ISmartPoolState} from "../../interfaces/v4/pool/ISmartPoolState.sol";
import {ISmartPoolOwnerActions} from "../../interfaces/v4/pool/ISmartPoolOwnerActions.sol";
import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";
import {VirtualBalanceLib} from "../../libraries/VirtualBalanceLib.sol";
import {OpType} from "../../types/Crosschain.sol";
import {IEscrowContract} from "./IEscrowContract.sol";

/// @title BaseEscrowContract - Base implementation for escrow contracts
/// @notice Handles refunds from failed cross-chain transfers with appropriate virtual balance management
/// @dev Abstract contract that must be inherited by specific operation type escrows
abstract contract BaseEscrowContract is IEscrowContract {
    using SafeTransferLib for address;
    using VirtualBalanceLib for address;

    /// @notice The pool this escrow is associated with
    address public immutable override pool;

    error UnauthorizedCaller();
    error TransferFailed();
    error InvalidAmount();

    modifier onlyPoolOwner() {
        ISmartPoolState.ReturnedPool memory poolInfo = ISmartPoolState(pool).getPool();
        require(msg.sender == poolInfo.owner, UnauthorizedCaller());
        _;
    }

    constructor(address _pool) {
        require(_pool != address(0), "Invalid pool address");
        pool = _pool;
    }

    /// @notice Receives tokens (typically from refunds)
    /// @dev Immediately forwards to vault to avoid manual claims for native tokens
    receive() external payable {
        if (msg.value > 0) {
            // Transfer immediately to vault to avoid stuck funds
            (bool success, ) = payable(pool).call{value: msg.value}("");
            require(success, TransferFailed());
            // Note: No event emission since we can't consistently do this for ERC20 refunds
        }
    }

    /// @inheritdoc IEscrowContract
    function claimRefund(address token) external override {
        uint256 balance;
        if (token == address(0)) {
            balance = address(this).balance;
        } else {
            balance = IERC20(token).balanceOf(address(this));
        }
        require(balance > 0, InvalidAmount());
        _donateToPool(token, balance);
    }

    /// @dev Internal function to donate tokens to pool - must be implemented by specific escrow types
    function _donateToPool(address token, uint256 amount) internal virtual;
}