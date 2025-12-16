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

import {OpType} from "../../types/Crosschain.sol";

/// @title IEscrowContract - Interface for escrow contracts handling refunds
/// @notice Escrow contracts manage refunds from failed cross-chain transfers
interface IEscrowContract {
    /// @notice Emitted when tokens are donated back to the pool
    event TokensDonated(address indexed token, uint256 amount);
    
    /// @notice Emitted when tokens are received as refund
    event RefundReceived(address indexed token, uint256 amount);
    
    /// @notice Returns the operation type this escrow handles
    function opType() external view returns (OpType);
    
    /// @notice Returns the pool this escrow is associated with
    function pool() external view returns (address);
    
    /// @notice Donates tokens back to the pool with appropriate virtual balance adjustment
    /// @param token The token to donate
    /// @param amount The amount to donate
    function donateToPool(address token, uint256 amount) external;
    
    /// @notice Allows anyone to claim refund tokens and send them to the pool vault
    /// @dev Claims the full balance of the token held by this escrow contract
    /// @param token The token address to claim (address(0) for native)
    function claimRefund(address token) external;
}