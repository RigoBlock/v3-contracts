// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2022-2025 Rigo Intl.

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

import {MixinImmutables} from "./MixinImmutables.sol";
import {AddressSet, Pool} from "../../libraries/EnumerableSet.sol";
import {ApplicationsSlot} from "../../libraries/ApplicationsLib.sol";

pragma solidity >=0.8.0 <0.9.0;

/// @notice Storage slots must be preserved to prevent storage clashing.
/// @dev Pool storage is not sequential: each variable is wrapped into a struct which is assigned a storage slot.
abstract contract MixinStorage is MixinImmutables {
    constructor() {
        // governance must always check that pool extensions are not using these storage slots (reserved for proxy storage)
        assert(_POOL_INIT_SLOT == bytes32(uint256(keccak256("pool.proxy.initialization")) - 1));
        assert(_POOL_VARIABLES_SLOT == bytes32(uint256(keccak256("pool.proxy.variables")) - 1));
        assert(_POOL_TOKENS_SLOT == bytes32(uint256(keccak256("pool.proxy.token")) - 1));
        assert(_POOL_ACCOUNTS_SLOT == bytes32(uint256(keccak256("pool.proxy.user.accounts")) - 1));
        assert(_TOKEN_REGISTRY_SLOT == bytes32(uint256(keccak256("pool.proxy.token.registry")) - 1));
        assert(_APPLICATIONS_SLOT == bytes32(uint256(keccak256("pool.proxy.applications")) - 1));
        assert(_OPERATOR_BOOLEAN_SLOT == bytes32(uint256(keccak256("pool.proxy.operator.boolean")) - 1));
    }

    // mappings slot kept empty and i.e. userBalance stored at location keccak256(address(msg.sender) . uint256(_POOL_USER_ACCOUNTS_SLOT))
    // activation stored at locantion keccak256(address(msg.sender) . uint256(_POOL_USER_ACCOUNTS_SLOT)) + 1
    struct Accounts {
        mapping(address => UserAccount) userAccounts;
    }

    function accounts() internal pure returns (Accounts storage s) {
        assembly {
            s.slot := _POOL_ACCOUNTS_SLOT
        }
    }

    function pool() internal pure returns (Pool storage s) {
        assembly {
            s.slot := _POOL_INIT_SLOT
        }
    }

    /// @notice Pool initialization struct wrapper.
    /// @dev Allows initializing pool as struct for better readability.
    /// @param pool The pool struct.
    struct PoolWrapper {
        Pool pool;
    }

    function poolWrapper() internal pure returns (PoolWrapper storage s) {
        assembly {
            s.slot := _POOL_INIT_SLOT
        }
    }

    function poolParams() internal pure returns (PoolParams storage s) {
        assembly {
            s.slot := _POOL_VARIABLES_SLOT
        }
    }

    function poolTokens() internal pure returns (PoolTokens storage s) {
        assembly {
            s.slot := _POOL_TOKENS_SLOT
        }
    }

    function activeTokensSet() internal pure returns (AddressSet storage s) {
        assembly {
            s.slot := _TOKEN_REGISTRY_SLOT
        }
    }

    function activeApplications() internal pure returns (ApplicationsSlot storage s) {
        assembly {
            s.slot := _APPLICATIONS_SLOT
        }
    }

    struct Operator {
        mapping(address holder => mapping(address operator => bool isApproved)) isApproved;
    }

    function operators() internal pure returns (Operator storage s) {
        assembly {
            s.slot := _OPERATOR_BOOLEAN_SLOT
        }
    }
}
