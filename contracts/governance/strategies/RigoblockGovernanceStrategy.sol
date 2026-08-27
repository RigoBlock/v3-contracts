// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.35;

import {ICoreBridge} from "wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol";

import {IGovernanceStrategy} from "../interfaces/IGovernanceStrategy.sol";
import {IRigoblockGovernanceFactory} from "../interfaces/IRigoblockGovernanceFactory.sol";
import {IGovernanceState} from "../interfaces/governance/IGovernanceState.sol";
import {IGovernanceVoting} from "../interfaces/governance/IGovernanceVoting.sol";
import {CrossChainPayload} from "../types/GovernanceTypes.sol";
import {IStructs} from "../../staking/interfaces/IStructs.sol";
import {IStaking} from "../../staking/interfaces/IStaking.sol";
import {IStorage} from "../../staking/interfaces/IStorage.sol";

contract RigoblockGovernanceStrategy is IGovernanceStrategy {
    /// @notice Wormhole core contract on the same chain as this strategy.
    address private immutable _wormhole;

    /// @notice Wormhole chain id of the chain this strategy is deployed on.
    uint16 private immutable _wormholeChainId;

    address private immutable _stakingProxy;
    uint256 private immutable _votingPeriod;

    /// @notice Thrown when a Wormhole cross-chain action has malformed calldata.
    error GovCrosschainInvalidData();

    /// @notice Thrown when a Wormhole cross-chain action targets the current chain.
    error GovCrosschainTargetSelf(uint16 targetChainId);

    /// @notice Thrown when a Wormhole cross-chain proposal is created outside Ethereum mainnet.
    error GovCrosschainNotMainnet();

    /// @notice Thrown when the proposal threshold is outside the allowed range.
    error GovStrategyInvalidProposalThreshold(uint256 proposalThreshold, uint256 floor, uint256 cap);

    /// @notice Thrown when the quorum threshold is outside the allowed range.
    error GovStrategyInvalidQuorumThreshold(uint256 quorumThreshold, uint256 floor, uint256 cap);

    constructor(address stakingProxy, address wormhole, uint16 wormholeChainId) {
        _stakingProxy = stakingProxy;
        _wormhole = wormhole;
        _wormholeChainId = wormholeChainId;
        _votingPeriod = 7 days;
    }

    /// @inheritdoc IGovernanceStrategy
    function assertValidInitParams(IRigoblockGovernanceFactory.Parameters memory params) external view override {
        assert(keccak256(abi.encodePacked(params.name)) == keccak256(abi.encodePacked(string("Rigoblock Governance"))));
        assertValidThresholds(params.proposalThreshold, params.quorumThreshold);
    }

    /// @inheritdoc IGovernanceStrategy
    function assertValidThresholds(uint256 proposalThreshold, uint256 quorumThreshold) public view override {
        _assertValidProposalThreshold(proposalThreshold);
        _assertValidQuorumThreshold(quorumThreshold);
    }

    /// @inheritdoc IGovernanceStrategy
    function getProposalState(
        IGovernanceState.Proposal memory proposal,
        uint256 minimumQuorum
    ) external view override returns (IGovernanceState.ProposalState) {
        // notice: because in rigoblock staking we use epochs, the exact start time will never perfectly match the new epoch
        // using timestamps instead of epoch is a safeguard for upgrades, should the staking system get stuck by being unable to finalize.
        if (block.timestamp <= proposal.startBlockOrTime) {
            return IGovernanceState.ProposalState.Pending;
        } else if (block.timestamp <= proposal.endBlockOrTime && _qualifiedConsensus(proposal, minimumQuorum)) {
            return IGovernanceState.ProposalState.Qualified;
        } else if (block.timestamp <= proposal.endBlockOrTime) {
            return IGovernanceState.ProposalState.Active;
        } else if (proposal.votesFor <= 2 * proposal.votesAgainst || proposal.votesFor < minimumQuorum) {
            return IGovernanceState.ProposalState.Defeated;
        } else if (proposal.executed) {
            return IGovernanceState.ProposalState.Executed;
        } else {
            return IGovernanceState.ProposalState.Succeeded;
        }
    }

    function _qualifiedConsensus(IGovernanceState.Proposal memory proposal, uint256 minimumQuorum) private view returns (bool) {
        return (3 * proposal.votesFor >
            2 *
                IStaking(_getStakingProxy())
                    .getGlobalStakeByStatus(IStructs.StakeStatus.DELEGATED)
                    .currentEpochBalance &&
            proposal.votesFor >= minimumQuorum);
    }

    /// @inheritdoc IGovernanceStrategy
    function getVotingPower(address account) public view override returns (uint256) {
        return
            IStaking(_getStakingProxy())
                .getOwnerStakeByStatus(account, IStructs.StakeStatus.DELEGATED)
                .currentEpochBalance;
    }

    /// @inheritdoc IGovernanceStrategy
    function votingPeriod() public view override returns (uint256) {
        uint256 stakingEpochDuration = IStorage(_getStakingProxy()).epochDurationInSeconds();
        return stakingEpochDuration < _votingPeriod ? stakingEpochDuration : _votingPeriod;
    }

    /// @inheritdoc IGovernanceStrategy
    function votingTimestamps() public view override returns (uint256 startBlockOrTime, uint256 endBlockOrTime) {
        startBlockOrTime = IStaking(_getStakingProxy()).getCurrentEpochEarliestEndTimeInSeconds();

        // we require voting starts next block to prevent instant upgrade
        startBlockOrTime = block.timestamp >= startBlockOrTime ? block.timestamp + 1 : startBlockOrTime;

        endBlockOrTime = startBlockOrTime + votingPeriod();
    }

    function _assertValidProposalThreshold(uint256 proposalThreshold) private view {
        uint256 grgTotalSupply = IStaking(_getStakingProxy()).getGrgContract().totalSupply();
        uint256 chainId = block.chainid;

        // between 1 and 2% of total supply
        uint256 floor = grgTotalSupply / 100;
        uint256 cap = grgTotalSupply / 50;

        // hard limits on altchains
        if (chainId != 1) {
            floor = floor < 20_000e18 ? 20_000e18 : floor;
            cap = cap < 100_000e18 ? 100_000e18 : cap;
        }

        require(
            proposalThreshold >= floor && proposalThreshold <= cap,
            GovStrategyInvalidProposalThreshold(proposalThreshold, floor, cap)
        );
    }

    function _assertValidQuorumThreshold(uint256 quorumThreshold) private view {
        uint256 grgTotalSupply = IStaking(_getStakingProxy()).getGrgContract().totalSupply();
        uint256 chainId = block.chainid;

        // between 4 and 10% of total supply
        uint256 floor = grgTotalSupply / 25;
        uint256 cap = grgTotalSupply / 10;

        // hard limits on altchains
        if (chainId != 1) {
            floor = floor < 100_000e18 ? 100_000e18 : floor;
            cap = cap < 400_000e18 ? 400_000e18 : cap;
        }

        require(
            quorumThreshold >= floor && quorumThreshold <= cap,
            GovStrategyInvalidQuorumThreshold(quorumThreshold, floor, cap)
        );
    }

    /// @inheritdoc IGovernanceStrategy
    function beforePropose(
        IGovernanceVoting.ProposedAction calldata action
    ) external view override returns (IGovernanceVoting.ProposedAction memory) {
        if (action.target != _wormhole) {
            return action;
        }

        // Cross-chain proposals are only allowed from Ethereum mainnet
        require(block.chainid == 1, GovCrosschainNotMainnet());

        _assertValidWormholeData(action.data);
        return action;
    }

    /// @inheritdoc IGovernanceStrategy
    function beforeExecute(IGovernanceVoting.ProposedAction memory action) external view override returns (IGovernanceVoting.ProposedAction memory) {
        if (action.target != _wormhole) {
            return action;
        }

        action.value += ICoreBridge(_wormhole).messageFee();

        return action;
    }

    /// @notice Decodes a Wormhole publishMessage call and validates its inner payload.
    function _assertValidWormholeData(bytes calldata data) private view {
        require(data.length >= 4 && bytes4(data) == ICoreBridge.publishMessage.selector, GovCrosschainInvalidData());

        (, bytes memory payload, ) = abi.decode(data[4:], (uint32, bytes, uint8));
        CrossChainPayload memory crossChainPayload = abi.decode(payload, (CrossChainPayload));
        require(
            crossChainPayload.targetWormholeChainId != _wormholeChainId,
            GovCrosschainTargetSelf(crossChainPayload.targetWormholeChainId)
        );
    }

    /// @notice It is more gas efficient at deploy to reading immutable from internal method.
    function _getStakingProxy() private view returns (address) {
        return _stakingProxy;
    }
}
