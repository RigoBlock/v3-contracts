// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {ICoreBridge} from "wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol";

import {CrossChainPayload, ProposalStatus, ProposedAction, ProposalExtraData} from "../types/GovernanceTypes.sol";
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

    /// @notice Thrown when the Wormhole core contract address is the zero address.
    error GovStrategyInvalidWormhole();

    /// @notice Maximum voting period.
    uint256 private constant _VOTING_PERIOD = 7 days;

    /// @notice Wormhole core contract on the same chain as this strategy.
    address private immutable _wormhole;

    address private immutable _stakingProxy;

    constructor(address stakingProxy, address coreBridge) {
        // empty returndata from the probe is rejected by the returns clause
        require(coreBridge.code.length > 0, GovStrategyInvalidWormhole());
        try ICoreBridge(coreBridge).chainId() returns (uint16) {} catch {
            revert GovStrategyInvalidWormhole();
        }
        _stakingProxy = stakingProxy;
        _wormhole = coreBridge;
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
        // executed is terminal and reported first
        if (proposal.executed) return ProposalStatus.Executed;
        _assertTimestamp(timeType);
        uint256 time = block.timestamp;
        // slither-disable-next-line timestamp -- by-design timestamp clock
        if (time <= proposal.startBlockOrTime) {
            return ProposalStatus.Pending;
            // slither-disable-next-line timestamp -- by-design timestamp clock
        } else if (time <= proposal.endBlockOrTime && _qualifiedConsensus(proposal, minimumQuorum, votingPower)) {
            return ProposalStatus.Qualified;
            // slither-disable-next-line timestamp -- by-design timestamp clock
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

    /// @dev The governance clock and voting window are timestamp-based.
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
    ) external virtual override returns (ProposedAction[] memory, uint256 startBlockOrTime, uint256 endBlockOrTime) {
        startBlockOrTime = _rollEpochIfStale();
        endBlockOrTime = startBlockOrTime + votingPeriod();

        for (uint256 i = 0; i < actions.length; i++) {
            if (actions[i].target != _wormhole) continue;
            // the wrapper value is validated here; the Wormhole fee is attached in beforeExecute
            require(actions[i].value == 0, GovCrosschainInvalidValue(actions[i].value));
            _assertValidWormholeData(actions[i].data);
        }

        return (actions, startBlockOrTime, endBlockOrTime);
    }

    /// @dev Rolls a finished epoch best-effort; on a refused roll the window starts at the
    ///      current timestamp so the proposal becomes voteable from the next block.
    function _rollEpochIfStale() private returns (uint256 startBlockOrTime) {
        startBlockOrTime = IStaking(_stakingProxy).getCurrentEpochEarliestEndTimeInSeconds();
        // slither-disable-next-line timestamp -- by-design epoch staleness guard
        if (block.timestamp < startBlockOrTime) return startBlockOrTime;
        try IStaking(_stakingProxy).endEpoch() {} catch {
            return block.timestamp;
        }
        // a successful roll always produces a future earliest end
        startBlockOrTime = IStaking(_stakingProxy).getCurrentEpochEarliestEndTimeInSeconds();
    }

    /// @inheritdoc IGovernanceStrategy
    /// @dev Rolls a finished epoch best-effort before the first vote's snapshot and returns the
    ///      stored snapshot unchanged once it exists.
    function beforeVote(ProposalExtraData calldata extraData) external virtual override returns (uint256) {
        if (extraData.votingPower != 0) return extraData.votingPower;
        // slither-disable-next-line timestamp -- by-design epoch staleness guard
        if (block.timestamp >= IStaking(_stakingProxy).getCurrentEpochEarliestEndTimeInSeconds()) {
            try IStaking(_stakingProxy).endEpoch() {} catch {}
        }
        return IStaking(_stakingProxy).getGlobalStakeByStatus(IStructs.StakeStatus.DELEGATED).currentEpochBalance;
    }

    /// @dev Validates a Wormhole publishMessage payload and its inner actions.
    function _assertValidWormholeData(bytes calldata data) private view {
        require(data.length >= 4 && bytes4(data) == ICoreBridge.publishMessage.selector, GovCrosschainInvalidData());

        (, bytes memory payload, uint8 consistencyLevel) = abi.decode(data[4:], (uint32, bytes, uint8));
        // 202 is Wormhole's finalized consistency level
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
    function beforeExecute(
        ProposedAction[] memory actions
    ) external view virtual override returns (ProposedAction[] memory) {
        for (uint256 i = 0; i < actions.length; i++) {
            if (actions[i].target != _wormhole) continue;
            // publishMessage requires msg.value == messageFee(), so the wrapper value is set to the fee
            actions[i].value = ICoreBridge(_wormhole).messageFee();
        }
        return actions;
    }

    /// @inheritdoc IGovernanceStrategy
    function wormhole() external view override returns (address) {
        return _wormhole;
    }
}
