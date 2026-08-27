// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {MixinImmutables} from "./MixinImmutables.sol";
import {IGovernanceState} from "../interfaces/governance/IGovernanceState.sol";
import {IGovernanceVoting} from "../interfaces/governance/IGovernanceVoting.sol";

abstract contract MixinStorage is MixinImmutables {
    // we use the constructor to assert that we are not using occupied storage slots
    constructor() {
        assert(_IMPLEMENTATION_SLOT == bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1));
        assert(_GOVERNANCE_PARAMS_SLOT == bytes32(uint256(keccak256("governance.proxy.governanceparams")) - 1));
        assert(_NAME_SLOT == bytes32(uint256(keccak256("governance.proxy.name")) - 1));
        assert(_RECEIPT_SLOT == bytes32(uint256(keccak256("governance.proxy.user.receipt")) - 1));
        assert(_PROPOSAL_SLOT == bytes32(uint256(keccak256("governance.proxy.proposal")) - 1));
        assert(_PROPOSAL_COUNT_SLOT == bytes32(uint256(keccak256("governance.proxy.proposalcount")) - 1));
        assert(_PROPOSED_ACTION_SLOT == bytes32(uint256(keccak256("governance.proxy.proposedaction")) - 1));
        assert(_PROPOSAL_QUORUM_SLOT == bytes32(uint256(keccak256("governance.proxy.proposal.quorum")) - 1));
    }

    function _governanceParameters() internal pure returns (IGovernanceState.GovernanceParameters storage s) {
        assembly {
            s.slot := _GOVERNANCE_PARAMS_SLOT
        }
    }

    struct ParamsWrapper {
        IGovernanceState.GovernanceParameters governanceParameters;
    }

    function _paramsWrapper() internal pure returns (ParamsWrapper storage s) {
        assembly {
            s.slot := _GOVERNANCE_PARAMS_SLOT
        }
    }

    struct AddressSlot {
        address value;
    }

    function _implementation() internal pure returns (AddressSlot storage s) {
        assembly {
            s.slot := _IMPLEMENTATION_SLOT
        }
    }

    struct StringSlot {
        string value;
    }

    function _name() internal pure returns (StringSlot storage s) {
        assembly {
            s.slot := _NAME_SLOT
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

    struct ProposalByIndex {
        mapping(uint256 => IGovernanceState.Proposal) proposalById;
    }

    function _proposal() internal pure returns (ProposalByIndex storage s) {
        assembly {
            s.slot := _PROPOSAL_SLOT
        }
    }

    struct ProposalQuorumByIndex {
        mapping(uint256 proposalId => uint256 quorum) proposalQuorumById;
    }

    function _proposalQuorum() internal pure returns (ProposalQuorumByIndex storage s) {
        assembly {
            s.slot := _PROPOSAL_QUORUM_SLOT
        }
    }

    struct ActionByIndex {
        mapping(uint256 => mapping(uint256 => IGovernanceVoting.ProposedAction)) proposedActionbyIndex;
    }

    function _proposedAction() internal pure returns (ActionByIndex storage s) {
        assembly {
            s.slot := _PROPOSED_ACTION_SLOT
        }
    }

    struct UserReceipt {
        mapping(uint256 => mapping(address => IGovernanceState.Receipt)) userReceiptByProposal;
    }

    function _receipt() internal pure returns (UserReceipt storage s) {
        assembly {
            s.slot := _RECEIPT_SLOT
        }
    }
}
