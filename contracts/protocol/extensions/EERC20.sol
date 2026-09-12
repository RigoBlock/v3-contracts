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

import {IEERC20} from "./adapters/interfaces/IEERC20.sol";

/// @title EERC20 - Exposes the disabled ERC20 methods of the pool.
/// @author Gabriele Rigo - <gab@rigoblock.com>
/// @notice Pool tokens are non-transferable: transfer methods revert, allowances are always null.
/// @dev Called via delegatecall from pool. Kept as an extension to keep the pool implementation
/// @dev within the contract size limit. Direct calls are harmless: mutating methods revert.
contract EERC20 is IEERC20 {
    error PoolTokenOperationNotAllowed();

    /// @inheritdoc IEERC20
    function transfer(address, uint256) external override returns (bool) {
        revert PoolTokenOperationNotAllowed();
    }

    /// @inheritdoc IEERC20
    function transferFrom(address, address, uint256) external override returns (bool) {
        revert PoolTokenOperationNotAllowed();
    }

    /// @inheritdoc IEERC20
    function approve(address, uint256) external override returns (bool) {
        revert PoolTokenOperationNotAllowed();
    }

    /// @inheritdoc IEERC20
    function allowance(address, address) external pure override returns (uint256) {
        return 0;
    }
}
