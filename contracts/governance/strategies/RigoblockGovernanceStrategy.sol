// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {ICoreBridge} from "wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol";

import {CrossChainPayload, ProposalStatus, ProposedAction} from "../types/GovernanceTypes.sol";
import {IGovernanceState} from "../interfaces/governance/IGovernanceState.sol";
import {IGovernanceStrategy} from "../interfaces/IGovernanceStrategy.sol";
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
    /// @notice Thrown when a Wormhole cross-chain action has malformed calldata.
    error GovCrosschainInvalidData();

    /// @notice Thrown when a Wormhole cross-chain action targets the current chain.
    error GovCrosschainTargetSelf(uint16 targetChainId);

    /// @notice Thrown when a Wormhole cross-chain action carries a non-zero wrapper value.
    error GovCrosschainInvalidValue(uint256 value);

    /// @notice Thrown when a Wormhole message is published with a non-finalized consistency level.
    /// @param consistencyLevel The supplied consistency level.
    error GovCrosschainInvalidConsistencyLevel(uint8 consistencyLevel);

    /// @notice Thrown when the governance time type is not TimeType.Timestamp.
    error GovStrategyInvalidTimeType(TimeType timeType);

    /// @notice Thrown when the Wormhole core contract address is the zero address.
    error GovStrategyInvalidWormhole();

    /// @notice Maximum voting period. The one-second margin under the staking epoch duration
    ///         (see votingPeriod) keeps the whole voting window strictly inside the current
    ///         staking epoch whenever the epoch cannot roll, so a stuck epoch cannot split
    ///         the window across two epochs.
    uint256 private constant _VOTING_PERIOD = 7 days;

    /// @notice Wormhole core contract on the same chain as this strategy.
    address private immutable _wormhole;

    address private immutable _stakingProxy;

    constructor(address stakingProxy, address wormhole) {
        // an EOA or a non-wormhole contract would return empty returndata from the probe, which
        // the returns clause rejects
        require(wormhole.code.length > 0, GovStrategyInvalidWormhole());
        try ICoreBridge(wormhole).chainId() returns (uint16) {} catch {
            revert GovStrategyInvalidWormhole();
        }
        _stakingProxy = stakingProxy;
        _wormhole = wormhole;
    }

    /// @inheritdoc IGovernanceStrategy
    function validateParams(IRigoblockGovernanceFactory.Parameters memory params) external view override {
        _assertTimestamp(params.timeType);
        assert(keccak256(abi.encodePacked(params.name)) == keccak256(abi.encodePacked(string("Rigoblock Governance"))));
        _assertValidProposalThreshold(params.proposalThreshold);
        _assertValidQuorumThreshold(params.quorumThreshold);
    }

    /// @inheritdoc IGovernanceStrategy
    function getProposalState(
        IGovernanceState.Proposal memory proposal,
        address,
        uint256 minimumQuorum,
        uint256 votingPower,
        TimeType timeType
    ) external view override returns (ProposalStatus) {
        // executed is terminal and must be reported regardless of the clock or recovery state
        if (proposal.executed) return ProposalStatus.Executed;
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
    function getVotingPower(address account) public view override returns (uint256) {
        return
            IStaking(_stakingProxy).getOwnerStakeByStatus(account, IStructs.StakeStatus.DELEGATED).currentEpochBalance;
    }

    /// @inheritdoc IGovernanceStrategy
    function votingPeriod() public view override returns (uint256) {
        uint256 epochDuration = IStorage(_stakingProxy).epochDurationInSeconds();
        uint256 period = epochDuration >= 2 ? epochDuration - 1 : _VOTING_PERIOD;
        return period < _VOTING_PERIOD ? period : _VOTING_PERIOD;
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
            GovStrategyInvalidProposalThreshold(proposalThreshold)
        );
    }

    function _assertValidQuorumThreshold(uint256 quorumThreshold) private view {
        uint256 grgTotalSupply = IStaking(_stakingProxy).getGrgContract().totalSupply();

        // between 4 and 10% of total supply
        uint256 floor = grgTotalSupply / 25;
        uint256 cap = grgTotalSupply / 10;

        require(quorumThreshold >= floor && quorumThreshold <= cap, GovStrategyInvalidQuorumThreshold(quorumThreshold));
    }

    /// @inheritdoc IGovernanceStrategy
    function beforePropose(
        ProposedAction[] calldata actions
    ) external override returns (ProposedAction[] memory, uint256 startBlockOrTime, uint256 endBlockOrTime) {
        // roll a finished staking epoch so the voting window starts at a live epoch boundary;
        // a stale or unreadable clock falls back to starting at the current timestamp, so the
        // proposal is Pending during the propose block and voteable from the next block
        startBlockOrTime = _rollEpochIfStale();
        endBlockOrTime = startBlockOrTime + votingPeriod();

        // wormhole actions publish governance messages to the receiver chains
        for (uint256 i = 0; i < actions.length; i++) {
            if (actions[i].target != _wormhole) continue;
            // The wrapped action value is paid on the destination chain from the receiver's own
            // balance; Wormhole's fee is added at execution time in beforeExecute instead.
            require(actions[i].value == 0, GovCrosschainInvalidValue(actions[i].value));
            _assertValidWormholeData(actions[i].data);
        }

        return (actions, startBlockOrTime, endBlockOrTime);
    }

    /// @dev Returns the fixed start of the voting window: the current epoch's earliest end,
    ///      read once at proposal time. A finished epoch is rolled best-effort first — a stuck
    ///      epoch must never block governance — and only when the roll is impossible does the
    ///      window start at the current timestamp (there is no future epoch boundary to anchor
    ///      to): `time <= start` keeps the proposal Pending during the propose block, so it
    ///      becomes voteable from the next block.
    function _rollEpochIfStale() private returns (uint256 startBlockOrTime) {
        startBlockOrTime = IStaking(_stakingProxy).getCurrentEpochEarliestEndTimeInSeconds();
        if (block.timestamp < startBlockOrTime) return startBlockOrTime;
        try IStaking(_stakingProxy).endEpoch() {} catch {
            // the epoch cannot be rolled: governance must stay operational, so the window starts
            // at the current timestamp and the proposal becomes voteable from the next block
            return block.timestamp;
        }
        // a successful roll always produces a future earliest end
        startBlockOrTime = IStaking(_stakingProxy).getCurrentEpochEarliestEndTimeInSeconds();
    }

    /// @inheritdoc IGovernanceStrategy
    function beforeVote() external view override returns (uint256 totalVotingPower) {
        // no epoch roll here: the window is fixed at propose time, and rolling mid-window is
        // what would mix epochs; while an epoch cannot roll, the balances stay frozen, which
        // keeps votes and the snapshot consistent (see the governance documentation)
        return IStaking(_stakingProxy).getGlobalStakeByStatus(IStructs.StakeStatus.DELEGATED).currentEpochBalance;
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
            crossChainPayload.targetWormholeChainId != ICoreBridge(_wormhole).chainId(),
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
}
