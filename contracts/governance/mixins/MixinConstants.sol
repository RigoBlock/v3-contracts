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
    /// @notice Contract version
    string internal constant VERSION = "1.0.0";

    /// @notice Maximum operations per proposal
    uint256 internal constant PROPOSAL_MAX_OPERATIONS = 10;

    /// @notice The EIP-712 typehash for the contract's domain
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @notice The EIP-712 typehash for the vote struct
    bytes32 internal constant VOTE_TYPEHASH = keccak256("VoteEmitted(uint256 proposalId,enum supportType)");

    bytes32 internal constant _DOMAIN_SEPARATOR_SLOT =
        0xdb618ced4dd9b748cfec0043e87e7f7708f67fafafb1c3d0bfb6dc0f9c8bf72f;

    // implementation slot is same as declared in proxy
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0xc081ba77b34dd25ffc1c621425bbc52480b02e5d0249ce3831198d7e07603649;

    // TODO: update name slot
    bytes32 internal constant _NAME_SLOT = 0xc081ba77b34dd25ffc1c621425bbc52480b02e5d0249ce3831198d7e07603649;

    // TODO: update hash as name changed
    bytes32 internal constant _RECEIPT_SLOT = 0xc081ba77b34dd25ffc1c621425bbc52480b02e5d0249ce3831198d7e07603649;

    bytes32 internal constant _PROPOSALS_SLOT = 0x4c9446a18423f4548e2228ea960b1a789061f2812cf50d305d4527fdc4987578;

    // TODO: update hash as constant name changed
    bytes32 internal constant _PROPOSAL_COUNT_SLOT =
        0xbdd2133fac45cf26a03e03e13d846596b9d7940bbd32aef60e912772d175bb1d;

    // TODO: update hash
    bytes32 internal constant _STRATEGY_SLOT = 0xb82110679558db63b50a5551160e4d145a353af4b644d63bd4bdc975681fd945;

    bytes32 internal constant _GOVERNANCE_PARAMS_SLOT =
        0x068519504cb4b072099e717e67e4cccbcc86c6938d6975f9e669e006bd04c567;
}
