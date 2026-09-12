// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2026 Rigo Intl.

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

/// @title IEERC20 - Disabled ERC20 token methods of the pool.
/// @author Gabriele Rigo - <gab@rigoblock.com>
/// @dev Pool shares are non-transferable: transfer methods always revert and no allowances exist.
/// @dev balanceOf, decimals, name, symbol and totalSupply are implemented by the pool implementation.
interface IEERC20 {
    /// @notice Transfers are not allowed on pool tokens.
    function transfer(address to, uint256 value) external returns (bool success);

    /// @notice Transfers are not allowed on pool tokens.
    function transferFrom(address from, address to, uint256 value) external returns (bool success);

    /// @notice Approvals are not allowed on pool tokens.
    function approve(address spender, uint256 value) external returns (bool success);

    /// @notice Pool tokens do not support allowances.
    /// @dev Always returns 0 by protocol invariant: approve and transferFrom revert, so no
    /// @dev allowance can exist for any (owner, spender) pair. If approvals are ever enabled,
    /// @dev allowance MUST be implemented in the pool implementation — a function implemented
    /// @dev there shadows this routing; leaving it here would silently keep returning 0.
    function allowance(address owner, address spender) external view returns (uint256);
}
