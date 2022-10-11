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

import "../../interfaces/pool/IPoolStructs.sol";

pragma solidity >=0.8.0 <0.9.0;

/// @notice Storage slots must be preserved to prevent storage clashing.
/// @dev Pool storage is not sequential: each variable is wrapped into a struct which is assigned a storage slot.
// TODO: check if prev. IPoolStructs inheritance was creating issues with staking
abstract contract MixinStorage /*is IPoolStructs*/ {
    bytes32 private constant _POOL_INITIALIZATION_SLOT = 0xe48b9bb119adfc3bccddcc581484cc6725fe8d292ebfcec7d67b1f93138d8bd8;
    bytes32 private constant _POOL_VARIABLES_SLOT = 0xe3ed9e7d534645c345f2d15f0c405f8de0227b60eb37bbeb25b26db462415dec;
    bytes32 private constant _POOL_TOKENS_SLOT = 0xf46fb7ff9ff9a406787c810524417c818e45ab2f1997f38c2555c845d23bb9f6;
    bytes32 private constant _POOL_USER_ACCOUNTS_SLOT = 0xfd7547127f88410746fb7969b9adb4f9e9d8d2436aa2d2277b1103542deb7b8e;

    constructor() {
        assert(_POOL_INITIALIZATION_SLOT == bytes32(uint256(keccak256("pool.proxy.initialization")) - 1));
        assert(_POOL_VARIABLES_SLOT == bytes32(uint256(keccak256("pool.proxy.variables")) - 1));
        assert(_POOL_TOKENS_SLOT == bytes32(uint256(keccak256("pool.proxy.token")) - 1));
        assert(_POOL_USER_ACCOUNTS_SLOT == bytes32(uint256(keccak256("pool.proxy.user.accounts")) - 1));
    }

    function pool() internal pure returns(IPoolStructs.Pool storage s) {
        assembly {
            s.slot := _POOL_INITIALIZATION_SLOT
        }
    }

    /// @notice All new extensions/adapter should assert any storage slot they use is free.
    /// @dev Should be checked in the extension/adapter constructor.
    /// @param slot The storage slot declared by the extension.
    // TODO: modify adapters to assert slot is free
    function assertSlotNotReserved(bytes32 slot) external pure {
        assert(slot != _POOL_INITIALIZATION_SLOT & _POOL_VARIABLES_SLOT & _POOL_TOKENS_SLOT & _POOL_USER_ACCOUNTS_SLOT);
    } 

    //IPoolStructs.PoolParams internal poolParams;
    //IPoolStructs.PoolTokens internal poolTokens;
    //IPoolStructs.UserAccount internal userAccounts;
    //mapping(address => IPoolStructs.UserAccount) internal userAccounts;

    function poolParams() internal pure returns(IPoolStructs.PoolParams storage s) {
        assembly {
            s.slot := _POOL_VARIABLES_SLOT
        }
    }

    function poolTokens() internal pure returns(IPoolStructs.PoolTokens storage s) {
        assembly {
            s.slot := _POOL_TOKENS_SLOT
        }
    }

    function accounts() internal pure returns (IPoolStructs.Accounts storage s) {
        assembly {
            s.slot := _POOL_USER_ACCOUNTS_SLOT
        }
    }
}
