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

import "./MixinImmutables.sol";

abstract contract MixinStorage is MixinImmutables {
    // we use the constructor to assert that we are not using occupied storage slots
    constructor() {
        assert(_IMPLEMENTATION_SLOT == bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1));
        assert(_DOMAIN_SEPARATOR_SLOT == bytes32(uint256(keccak256("governance.proxy.domainseparator")) - 1));
        assert(_GOVERNANCE_PARAMS_SLOT == bytes32(uint256(keccak256("governance.proxy.treasuryparams")) - 1));
        assert(_NAME_SLOT == bytes32(uint256(keccak256("governance.proxy.name")) - 1));
        assert(_RECEIPT_SLOT == bytes32(uint256(keccak256("governance.proxy.user.receipt")) - 1));
        assert(_PROPOSALS_SLOT == bytes32(uint256(keccak256("governance.proxy.proposals")) - 1));
        assert(_PROPOSAL_COUNT_SLOT == bytes32(uint256(keccak256("governance.proxy.proposalscount")) - 1));
        assert(_STRATEGY_SLOT == bytes32(uint256(keccak256("governance.proxy.strategy")) - 1));
    }

    struct Bytes32Slot {
        bytes32 value;
    }

    // TODO: check if can write to storage with return bytes32
    function _domainSeparator() internal pure returns (Bytes32Slot storage s) {
        assembly {
            s.slot := _DOMAIN_SEPARATOR_SLOT
        }
    }

    function _governanceParameters() internal pure returns (GovernanceParameters storage s) {
        assembly {
            // TODO: update slot name
            s.slot := _GOVERNANCE_PARAMS_SLOT
        }
    }

    struct AddressSlot {
        address value;
    }

    function _governanceStrategy() internal pure returns (AddressSlot storage s) {
        assembly {
            s.slot := _STRATEGY_SLOT
        }
    }

    struct StringSlot {
        string value;
    }

    function _name() internal pure returns (StringSlot storage s) {
        assembly {
            // TODO: update slot name
            s.slot := _NAME_SLOT
        }
    }

    struct ParamsWrapper {
        GovernanceParameters governanceParameters;
    }

    function _paramsWrapper() internal pure returns (ParamsWrapper storage s) {
        assembly {
            s.slot := _GOVERNANCE_PARAMS_SLOT
        }
    }

    struct UintSlot {
        uint256 value;
    }

    function _proposalCount() internal pure returns (UintSlot storage s) {
        assembly {
            s.slot := _PROPOSAL_COUNT_SLOT
        }
    }

    struct Proposals {
        mapping(uint256 => Proposal) proposalById;
    }

    function _proposals() internal pure returns (Proposals storage s) {
        assembly {
            s.slot := _PROPOSALS_SLOT
        }
    }

    struct ActionByIndex {
        mapping(uint256 => mapping(uint256 => ProposedAction)) proposedActionbyIndex;
    }

    function _proposedAction() internal pure returns (ActionByIndex storage s) {
        assembly {
            // TODO: update slot name
            s.slot := _PROPOSALS_SLOT
        }
    }

    struct UserReceipt {
        mapping(uint256 => mapping(address => Receipt)) userReceiptByProposal;
    }

    function _receipt() internal pure returns (UserReceipt storage s) {
        assembly {
            s.slot := _RECEIPT_SLOT
        }
    }
}
