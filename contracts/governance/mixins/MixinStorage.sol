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
        assert(_RECEIPT_SLOT == bytes32(uint256(keccak256("governance.proxy.user.receipt")) - 1));
        assert(_PROPOSALS_SLOT == bytes32(uint256(keccak256("governance.proxy.proposals")) - 1));
        assert(_PROPOSAL_COUNT_SLOT == bytes32(uint256(keccak256("governance.proxy.proposalscount")) - 1));
        assert(_STAKING_PROXY_SLOT == bytes32(uint256(keccak256("governance.proxy.stakingproxy")) - 1));
        assert(_TREASURY_PARAMS_SLOT == bytes32(uint256(keccak256("governance.proxy.treasuryparams")) - 1));
    }

    struct DomainSeparator {
        bytes32 value;
    }

    function _domainSeparator() internal pure returns (DomainSeparator storage s) {
        assembly {
            s.slot := _DOMAIN_SEPARATOR_SLOT
        }
    }

    struct StakingProxy {
        address value;
    }

    function _stakingProxy() internal pure returns (StakingProxy storage s) {
        assembly {
            s.slot := _STAKING_PROXY_SLOT
        }
    }

    struct ParamsWrapper {
        TreasuryParameters treasuryParameters;
    }

    function _paramsWrapper() internal pure returns (ParamsWrapper storage s) {
        assembly {
            s.slot := _TREASURY_PARAMS_SLOT
        }
    }

    struct ProposalCount {
        uint256 value;
    }

    function _proposalCount() internal pure returns (ProposalCount storage s) {
        assembly {
            s.slot := _PROPOSAL_COUNT_SLOT
        }
    }

    struct Proposals {
        mapping(uint256 => Proposal) value;
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
        mapping(uint256 => mapping(address => Receipt)) value;
    }

    function _receipt() internal pure returns (UserReceipt storage s) {
        assembly {
            s.slot := _RECEIPT_SLOT
        }
    }

    function _treasuryParameters() internal pure returns (TreasuryParameters storage s) {
        assembly {
            s.slot := _TREASURY_PARAMS_SLOT
        }
    }
}
