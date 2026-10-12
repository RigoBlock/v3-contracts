// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {ICoreBridge} from "wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol";

import {CrossChainPayload, ProposalStatus, ProposedAction} from "../types/GovernanceTypes.sol";
import {IGovernanceState} from "../interfaces/governance/IGovernanceState.sol";
import {IGovernanceStrategy} from "../interfaces/IGovernanceStrategy.sol";
import {IGovernanceVoting} from "../interfaces/governance/IGovernanceVoting.sol";
import {IRigoblockGovernanceFactory} from "../interfaces/IRigoblockGovernanceFactory.sol";
import {IStaking} from "../../staking/interfaces/IStaking.sol";
import {IStorage} from "../../staking/interfaces/IStorage.sol";
import {IStructs} from "../../staking/interfaces/IStructs.sol";
import {TimeType} from "../types/TimeType.sol";

/// @title RigoblockGovernanceStrategy - Sender-chain governance strategy.
/// @dev Staking-backed voting power for the governance hub chain (Ethereum mainnet). It is
///      the only chain that can create local proposals and publish cross-chain governance
///      messages; every other chain runs a receiver strategy.
contract RigoblockGovernanceStrategy is IGovernanceStrategy {
    /// @notice Wormhole core contract on the same chain as this strategy.
    address private immutable _wormhole;

    /// @notice Maximum voting period. The one-second margin under the staking epoch duration
    ///         (see votingPeriod) keeps the whole voting window strictly inside a single
    ///         staking epoch even when the epoch duration equals this cap, so votes can never
    ///         mix epochs and no per-proposal epoch guard is needed.
    uint256 private constant _VOTING_PERIOD = 7 days;

    /// @notice Wormhole chain id of the chain this strategy is deployed on.
    uint16 private immutable _wormholeChainId;

    address private immutable _stakingProxy;

    constructor(address stakingProxy, address wormhole, uint16 wormholeChainId) {
        _stakingProxy = stakingProxy;
        _wormhole = wormhole;
        _wormholeChainId = wormholeChainId;
    }

    /// @inheritdoc IGovernanceStrategy
    function assertValidInitParams(IRigoblockGovernanceFactory.Parameters memory params) external view override {
        _assertTimestamp(params.timeType);
        assert(keccak256(abi.encodePacked(params.name)) == keccak256(abi.encodePacked(string("Rigoblock Governance"))));
        assertValidProposalThreshold(params.proposalThreshold);
        assertValidQuorumThreshold(params.quorumThreshold);
    }

    /// @inheritdoc IGovernanceStrategy
    function assertValidProposalThreshold(uint256 proposalThreshold) public view override {
        _assertValidProposalThreshold(proposalThreshold);
    }

    /// @inheritdoc IGovernanceStrategy
    function assertValidQuorumThreshold(uint256 quorumThreshold) public view override {
        _assertValidQuorumThreshold(quorumThreshold);
    }

    /// @inheritdoc IGovernanceStrategy
    function getProposalState(
        IGovernanceState.Proposal memory proposal,
        address,
        uint256 minimumQuorum,
        uint256 votingPower,
        TimeType timeType
    ) external view override returns (ProposalStatus) {
        _assertTimestamp(timeType);
        uint256 time = block.timestamp;
        if (time <= proposal.startBlockOrTime) {
            return ProposalStatus.Pending;
        } else if (time <= proposal.endBlockOrTime && _qualifiedConsensus(proposal, minimumQuorum, votingPower)) {
            return ProposalStatus.Qualified;
        } else if (time <= proposal.endBlockOrTime) {
            return ProposalStatus.Active;
        } else if (proposal.votesFor <= 2 * proposal.votesAgainst || proposal.votesFor < minimumQuorum) {
            return ProposalStatus.Defeated;
        } else {
            return ProposalStatus.Succeeded;
        }
    }

    function _qualifiedConsensus(
        IGovernanceState.Proposal memory proposal,
        uint256 minimumQuorum,
        uint256 votingPower
    ) private pure returns (bool) {
        // the denominator is snapshotted on the first vote, so staking epoch rollovers
        // cannot shrink the electorate after votes are recorded
        return (3 * proposal.votesFor > 2 * votingPower &&
            proposal.votesFor > 2 * proposal.votesAgainst &&
            proposal.votesFor >= minimumQuorum);
    }

    /// @inheritdoc IGovernanceStrategy
    function totalVotingPower() external view override returns (uint256) {
        return IStaking(_stakingProxy).getGlobalStakeByStatus(IStructs.StakeStatus.DELEGATED).currentEpochBalance;
    }

    /// @inheritdoc IGovernanceStrategy
    function getVotingPower(address account) public view override returns (uint256) {
        return
            IStaking(_stakingProxy).getOwnerStakeByStatus(account, IStructs.StakeStatus.DELEGATED).currentEpochBalance;
    }

    /// @inheritdoc IGovernanceStrategy
    function votingPeriod() public view override returns (uint256) {
        uint256 epochDuration;
        try IStorage(_stakingProxy).epochDurationInSeconds() returns (uint256 duration) {
            epochDuration = duration;
        } catch {
            return _VOTING_PERIOD;
        }
        if (epochDuration < 2) return _VOTING_PERIOD;
        uint256 period = epochDuration - 1;
        return period < _VOTING_PERIOD ? period : _VOTING_PERIOD;
    }

    /// @inheritdoc IGovernanceStrategy
    function votingTimestamps(
        TimeType timeType
    ) public view override returns (uint256 startBlockOrTime, uint256 endBlockOrTime) {
        _assertTimestamp(timeType);
        uint256 earliestEnd;
        try IStaking(_stakingProxy).getCurrentEpochEarliestEndTimeInSeconds() returns (uint256 end) {
            earliestEnd = end;
        } catch {
            earliestEnd = block.timestamp;
        }
        // a stale clock (the roll attempt in beforePropose failed or this is a plain view call)
        // falls back to starting the window at the next timestamp
        startBlockOrTime = block.timestamp >= earliestEnd ? block.timestamp + 1 : earliestEnd;
        endBlockOrTime = startBlockOrTime + votingPeriod();
    }

    /// @dev Attempts to roll a finished staking epoch. Governance must stay operational even
    ///      if the staking contract cannot roll, so a reverting endEpoch is swallowed and the
    ///      staking clock is used as-is.
    function _rollEpochIfStale() private {
        uint256 earliestEnd = IStaking(_stakingProxy).getCurrentEpochEarliestEndTimeInSeconds();
        if (block.timestamp >= earliestEnd) {
            try IStaking(_stakingProxy).endEpoch() {} catch {}
        }
    }

    /// @dev Reverts unless the governance uses TimeType.Timestamp.
    function _assertTimestamp(TimeType timeType) private pure {
        require(timeType == TimeType.Timestamp, GovStrategyInvalidTimeType(timeType));
    }

    function _assertValidProposalThreshold(uint256 proposalThreshold) private view {
        uint256 grgTotalSupply = IStaking(_stakingProxy).getGrgContract().totalSupply();

        // between 1 and 2% of total supply
        uint256 floor = grgTotalSupply / 100;
        uint256 cap = grgTotalSupply / 50;

        require(
            proposalThreshold >= floor && proposalThreshold <= cap,
            GovStrategyInvalidProposalThreshold(proposalThreshold, floor, cap)
        );
    }

    function _assertValidQuorumThreshold(uint256 quorumThreshold) private view {
        uint256 grgTotalSupply = IStaking(_stakingProxy).getGrgContract().totalSupply();

        // between 4 and 10% of total supply
        uint256 floor = grgTotalSupply / 25;
        uint256 cap = grgTotalSupply / 10;

        require(
            quorumThreshold >= floor && quorumThreshold <= cap,
            GovStrategyInvalidQuorumThreshold(quorumThreshold, floor, cap)
        );
    }

    /// @inheritdoc IGovernanceStrategy
    function beforePropose(ProposedAction[] calldata actions) external override returns (ProposedAction[] memory) {
        // roll a finished staking epoch so the voting window starts at a live epoch boundary
        _rollEpochIfStale();

        // wormhole actions publish governance messages to the receiver chains
        for (uint256 i = 0; i < actions.length; i++) {
            if (actions[i].target != _wormhole) continue;
            // The wrapped action value is paid on the destination chain from the receiver's own
            // balance; Wormhole's fee is added at execution time in beforeExecute instead.
            require(actions[i].value == 0, GovCrosschainInvalidValue(actions[i].value));
            _assertValidWormholeData(actions[i].data);
        }
        return actions;
    }

    /// @notice Decodes a Wormhole publishMessage call and validates its inner payload.
    /// @dev Enforced at proposal time: every inner action must carry no value, as the
    ///      governance is expected to hold no native balance on receiver chains.
    function _assertValidWormholeData(bytes calldata data) private view {
        require(data.length >= 4 && bytes4(data) == ICoreBridge.publishMessage.selector, GovCrosschainInvalidData());

        (, bytes memory payload, uint8 consistencyLevel) = abi.decode(data[4:], (uint32, bytes, uint8));
        // 202 is Wormhole's finalized consistency level: mainnet votes must reach finality before attestation
        require(consistencyLevel == 202, GovCrosschainInvalidConsistencyLevel(consistencyLevel));
        CrossChainPayload memory crossChainPayload = abi.decode(payload, (CrossChainPayload));
        require(
            crossChainPayload.targetWormholeChainId != _wormholeChainId,
            GovCrosschainTargetSelf(crossChainPayload.targetWormholeChainId)
        );
        for (uint256 i = 0; i < crossChainPayload.actions.length; i++) {
            require(
                crossChainPayload.actions[i].value == 0,
                GovCrosschainInvalidValue(crossChainPayload.actions[i].value)
            );
        }
    }

    /// @inheritdoc IGovernanceStrategy
    function beforeExecute(ProposedAction[] memory actions) external view override returns (ProposedAction[] memory) {
        for (uint256 i = 0; i < actions.length; i++) {
            if (actions[i].target != _wormhole) continue;
            // Wormhole requires msg.value == messageFee() on publishMessage, so the wrapper value
            // must be exactly the fee, overriding any (zero) value set at proposal time.
            actions[i].value = ICoreBridge(_wormhole).messageFee();
        }
        return actions;
    }

    /// @inheritdoc IGovernanceStrategy
    function wormhole() external view override returns (address) {
        return _wormhole;
    }

    /// @inheritdoc IGovernanceStrategy
    function wormholeChainId() external view override returns (uint16) {
        return _wormholeChainId;
    }
}
