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

import "../../IRigoblockV3Pool.sol";

/// @notice Constants are not assigned a storage slot, can be safely added to this contract.
abstract contract MixinConstants is IRigoblockV3Pool {
    /// @inheritdoc IRigoblockV3PoolImmutable
    string public constant override VERSION = "HF 3.1.0";

    // TODO: we could probably reduce deploy size by declaring smaller constants as uint32
    uint256 internal constant FEE_BASE = 10000;

    uint16 internal constant INITIAL_SPREAD = 500; // +-5%, in basis points

    uint16 internal constant MAX_SPREAD = 1000; // +-10%, in basis points

    uint16 internal constant MAX_TRANSACTION_FEE = 100; // maximum 1%

    // minimum order size 1/1000th of base to avoid dust clogging things up
    uint256 internal constant MINIMUM_ORDER_DIVISOR = 1e3;

    uint16 internal constant SPREAD_BASE = 10000;

    uint48 internal constant MAX_LOCKUP = 30 days;

    uint48 internal constant MIN_LOCKUP = 2;

    bytes4 internal constant TRANSFER_FROM_SELECTOR = bytes4(keccak256(bytes("transferFrom(address,address,uint256)")));

    bytes4 internal constant TRANSFER_SELECTOR = bytes4(keccak256(bytes("transfer(address,uint256)")));
}
