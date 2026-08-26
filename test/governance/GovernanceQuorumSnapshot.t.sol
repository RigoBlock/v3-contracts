// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {MixinStorage} from "../../contracts/governance/mixins/MixinStorage.sol";
import {MixinState} from "../../contracts/governance/mixins/MixinState.sol";
import {MixinVoting} from "../../contracts/governance/mixins/MixinVoting.sol";
import {MixinInitializer} from "../../contracts/governance/mixins/MixinInitializer.sol";
import {MixinUpgrade} from "../../contracts/governance/mixins/MixinUpgrade.sol";
import {IGovernanceState} from "../../contracts/governance/interfaces/governance/IGovernanceState.sol";
import {IRigoblockGovernance} from "../../contracts/governance/IRigoblockGovernance.sol";
import {IRigoblockGovernanceFactory} from "../../contracts/governance/interfaces/IRigoblockGovernanceFactory.sol";

contract MockStrategy {
    function assertValidInitParams(IRigoblockGovernanceFactory.Parameters calldata) external pure {}
    function assertValidThresholds(uint256, uint256) external pure {}
    function getProposalState(
        IRigoblockGovernance.Proposal memory,
        uint256
    ) external pure returns (IGovernanceState.ProposalState) {
        return IGovernanceState.ProposalState.Defeated;
    }
    function votingPeriod() external pure returns (uint256) {
        return 1;
    }
    function votingTimestamps() external pure returns (uint256, uint256) {
        return (0, 0);
    }
    function getVotingPower(address) external pure returns (uint256) {
        return 0;
    }
    function validateAction(IRigoblockGovernance.ProposedAction calldata) external pure {}
}

contract QuorumHarness is MixinStorage, MixinInitializer, MixinUpgrade, MixinVoting, MixinState {
    constructor() MixinStorage() {}

    function setStrategy(address strategy_) external {
        _paramsWrapper().governanceParameters.strategy = strategy_;
    }

    function setProposalCount(uint256 count) external {
        _proposalCount().value = count;
    }

    function setProposal(uint256 proposalId, IGovernanceState.Proposal calldata proposal) external {
        _proposal().proposalById[proposalId] = proposal;
    }

    function proposalSlot() external pure returns (bytes32) {
        return _PROPOSAL_SLOT;
    }
}

contract GovernanceQuorumSnapshotTest is Test {
    QuorumHarness internal harness;
    MockStrategy internal strategy;

    function setUp() public {
        harness = new QuorumHarness();
        strategy = new MockStrategy();
        harness.setStrategy(address(strategy));
    }

    function test_LegacyProposal_QuorumZero_ReadsOtherFieldsAndFallsBack() public {
        // Simulate a pre-snapshot proposal: all fields set except quorumThreshold.
        IGovernanceState.Proposal memory legacy = IGovernanceState.Proposal({
            actionsLength: 3,
            startBlockOrTime: 100,
            endBlockOrTime: 200,
            votesFor: 10,
            votesAgainst: 5,
            votesAbstain: 1,
            executed: false,
            quorumThreshold: 0
        });
        harness.setProposal(1, legacy);
        harness.setProposalCount(1);

        IGovernanceState.ProposalWrapper memory wrapper = harness.getProposalById(1);
        assertEq(wrapper.proposal.actionsLength, 3);
        assertEq(wrapper.proposal.startBlockOrTime, 100);
        assertEq(wrapper.proposal.endBlockOrTime, 200);
        assertEq(wrapper.proposal.votesFor, 10);
        assertEq(wrapper.proposal.votesAgainst, 5);
        assertEq(wrapper.proposal.votesAbstain, 1);
        assertEq(wrapper.proposal.quorumThreshold, 0);

        // Legacy proposals fall back to the current governance quorum so their state stays
        // readable. The mock strategy returns Defeated for any call, proving it was invoked.
        IGovernanceState.ProposalState state = harness.getProposalState(1);
        assertEq(uint256(state), uint256(IGovernanceState.ProposalState.Defeated));
    }

    function test_NewProposal_QuorumSnapshotted() public {
        IGovernanceState.Proposal memory proposal = IGovernanceState.Proposal({
            actionsLength: 1,
            startBlockOrTime: 100,
            endBlockOrTime: 200,
            votesFor: 0,
            votesAgainst: 0,
            votesAbstain: 0,
            executed: false,
            quorumThreshold: 1_000_000e18
        });
        harness.setProposal(1, proposal);
        harness.setProposalCount(1);

        IGovernanceState.ProposalWrapper memory wrapper = harness.getProposalById(1);
        assertEq(wrapper.proposal.quorumThreshold, 1_000_000e18);

        // New proposals are readable by the strategy.
        IGovernanceState.ProposalState state = harness.getProposalState(1);
        assertEq(uint256(state), uint256(IGovernanceState.ProposalState.Defeated));
    }

    function test_StorageLayout_QuorumThresholdAppendedInOwnSlot() public {
        // Write a proposal with known executed and quorumThreshold values.
        IGovernanceState.Proposal memory proposal = IGovernanceState.Proposal({
            actionsLength: 1,
            startBlockOrTime: 100,
            endBlockOrTime: 200,
            votesFor: 0,
            votesAgainst: 0,
            votesAbstain: 0,
            executed: true,
            quorumThreshold: 12345
        });
        harness.setProposal(1, proposal);
        harness.setProposalCount(1);

        // Compute the mapping entry slot for proposalId = 1.
        bytes32 proposalSlot = keccak256(abi.encode(uint256(1), uint256(harness.proposalSlot())));

        // executed is the 7th field (slot offset 6), quorumThreshold the 8th (slot offset 7).
        bytes32 executedSlot = bytes32(uint256(proposalSlot) + 6);
        bytes32 quorumSlot = bytes32(uint256(proposalSlot) + 7);

        // They must occupy different slots.
        assertTrue(executedSlot != quorumSlot);

        // executed is stored in its own slot and does not bleed into quorumThreshold.
        assertEq(vm.load(address(harness), executedSlot), bytes32(uint256(1)));
        assertEq(vm.load(address(harness), quorumSlot), bytes32(uint256(12345)));
    }
}
