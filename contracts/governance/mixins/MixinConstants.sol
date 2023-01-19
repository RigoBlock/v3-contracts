// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2023 Rigo Intl.

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

import "../IRigoblockGovernance.sol";

/// @notice Constants are copied in the bytecode and not assigned a storage slot, can safely be added to this contract.
abstract contract MixinConstants is IRigoblockGovernance {
    /// Contract name
    string internal constant CONTRACT_NAME = "Rigoblock Governance";

    /// Contract version
    string internal constant CONTRACT_VERSION = "1.0.0";

    /// The EIP-712 typehash for the contract's domain
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// The EIP-712 typehash for the vote struct
    bytes32 internal constant VOTE_TYPEHASH =
        keccak256("VoteEmitted(uint256 proposalId,bool support)");

    bytes32 internal constant _DOMAIN_SEPARATOR_SLOT = 0xe48b9bb119adfc3bccddcc581484cc6725fe8d292ebfcec7d67b1f93138d8bd8;
    bytes32 internal constant _STAKING_PROXY_SLOT = 0xe48b9bb119adfc3bccddcc581484cc6725fe8d292ebfcec7d67b1f93138d8bd8;
    bytes32 internal constant _TREASURY_PARAMS_SLOT = 0xe48b9bb119adfc3bccddcc581484cc6725fe8d292ebfcec7d67b1f93138d8bd8;
    bytes32 internal constant _HAS_VOTED_SLOT = 0xe48b9bb119adfc3bccddcc581484cc6725fe8d292ebfcec7d67b1f93138d8bd8;
    bytes32 internal constant _PROPOSALS_SLOT = 0xe48b9bb119adfc3bccddcc581484cc6725fe8d292ebfcec7d67b1f93138d8bd8;
    bytes32 internal constant _PROPOSALS_COUNT_SLOT = 0xe48b9bb119adfc3bccddcc581484cc6725fe8d292ebfcec7d67b1f93138d8bd8;
}