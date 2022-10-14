// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2022 Rigo Intl.

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

pragma solidity >=0.8.0 <0.9.0;

/// @title Rigoblock V3 Pool Initializer Interface - Allows initializing a pool contract.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
interface IRigoblockV3PoolInitializer {
    /// @notice Pool initialization parameters.
    /// @params name String of the name (max 31 characters).
    /// @params symbol bytes8 symbol.
    /// @params owner Address of the owner.
    /// @params baseToken Address of the base token.
    struct Parameters {
        string name;
        bytes8 symbol;
        address owner;
        address baseToken;
    }

    /// @notice Initializes to pool storage.
    /// @dev Pool can only be initialized at creation, meaning this method cannot be called directly to implementation.
    /// @param initParams Initialization parameters tuple.
    function initializePool(
        Parameters calldata initParams
    ) external;
}
