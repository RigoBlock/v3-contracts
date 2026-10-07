// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {ICoreBridge} from "wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol";

import {CrossChainPayload, GovernanceMode, ProposalStatus} from "../types/GovernanceTypes.sol";
import {IGovernanceState} from "../interfaces/governance/IGovernanceState.sol";
import {IGovernanceStrategy} from "../interfaces/IGovernanceStrategy.sol";
import {IGovernanceVoting} from "../interfaces/governance/IGovernanceVoting.sol";
import {IRigoblockGovernanceFactory} from "../interfaces/IRigoblockGovernanceFactory.sol";
import {IStaking} from "../../staking/interfaces/IStaking.sol";
import {IStorage} from "../../staking/interfaces/IStorage.sol";
import {IStructs} from "../../staking/interfaces/IStructs.sol";
import {TimeType} from "../types/TimeType.sol";

/// @title RigoblockGovernanceStrategy - Custom specs of the Rigoblock governance.
/// @dev Each strategy contract is specific to the governance model and may vary by chain.
contract RigoblockGovernanceStrategy is IGovernanceStrategy {
    /// @notice Wormhole core contract on the same chain as this strategy.
    address private immutable _wormhole;

    /// @notice Wormhole chain id of the chain this strategy is deployed on.
    uint16 private immutable _wormholeChainId;

    address private immutable _stakingProxy;
    uint256 private immutable _votingPeriod;

    /// @notice Governance mode of the chain this strategy is deployed on.
    GovernanceMode private immutable _mode;

    /// @notice Thrown when a local governance method is called on a receiver-only chain.
    error GovLocalGovernanceDisabled();

    /// @notice Thrown when a Wormhole cross-chain action has malformed calldata.
    error GovCrosschainInvalidData();

    /// @notice Thrown when a Wormhole cross-chain action targets the current chain.
    error GovCrosschainTargetSelf(uint16 targetChainId);

    /// @notice Thrown when a non-sender governance attempts to create a cross-chain proposal.
    error GovCrosschainNotSender();

    /// @notice Thrown when a Wormhole cross-chain action carries a non-zero wrapper value.
    /// @dev The inner action value is paid on the destination chain from the receiver's balance,
    /// so the wrapper must be zero and the Wormhole fee is attached at execution time only.
    error GovCrosschainInvalidValue(uint256 value);

    /// @notice Thrown when a Wormhole message is published with a consistency level other than finalized.
    /// @param consistencyLevel The supplied consistency level.
    error GovCrosschainInvalidConsistencyLevel(uint8 consistencyLevel);

    /// @notice Thrown when the proposal threshold is outside the allowed range.
    error GovStrategyInvalidProposalThreshold(uint256 proposalThreshold, uint256 floor, uint256 cap);

    /// @notice Thrown when the quorum threshold is outside the allowed range.
    error GovStrategyInvalidQuorumThreshold(uint256 quorumThreshold, uint256 floor, uint256 cap);

    /// @notice Thrown when the governance time type is not TimeType.Timestamp.
    error GovStrategyInvalidTimeType(TimeType timeType);

    constructor(address stakingProxy, address wormhole, uint16 wormholeChainId, GovernanceMode mode) {
        _stakingProxy = stakingProxy;
        _wormhole = wormhole;
        _wormholeChainId = wormholeChainId;
        _mode = mode;
        _votingPeriod = 7 days;
    }

    /// @inheritdoc IGovernanceStrategy
    function assertValidInitParams(IRigoblockGovernanceFactory.Parameters memory params) external view override {
        _assertTimestamp(params.timeType);
        assert(keccak256(abi.encodePacked(params.name)) == keccak256(abi.encodePacked(string("Rigoblock Governance"))));
        if (_mode == GovernanceMode.Receiver) return;
        _assertValidProposalThreshold(params.proposalThreshold);
        _assertValidQuorumThreshold(params.quorumThreshold);
    }

    /// @inheritdoc IGovernanceStrategy
    function assertValidProposalThreshold(uint256 proposalThreshold) public view override {
        if (_mode == GovernanceMode.Receiver) return;
        _assertValidProposalThreshold(proposalThreshold);
    }

    /// @inheritdoc IGovernanceStrategy
    function assertValidQuorumThreshold(uint256 quorumThreshold) public view override {
        if (_mode == GovernanceMode.Receiver) return;
        _assertValidQuorumThreshold(quorumThreshold);
    }

    /// @inheritdoc IGovernanceStrategy
    function getProposalState(
        IGovernanceState.Proposal memory proposal,
        uint256 minimumQuorum,
        TimeType timeType
    ) external view override returns (ProposalStatus) {
        if (_mode == GovernanceMode.Receiver) return ProposalStatus.Defeated;
        _assertTimestamp(timeType);

        // notice: because in rigoblock staking we use epochs, the exact start time will never perfectly match the new epoch
        // using timestamps instead of epoch is a safeguard for upgrades, should the staking system get stuck by being unable to finalize.
        uint256 time = block.timestamp;
        if (time <= proposal.startBlockOrTime) {
            return ProposalStatus.Pending;
        } else if (time <= proposal.endBlockOrTime && _qualifiedConsensus(proposal, minimumQuorum)) {
            return ProposalStatus.Qualified;
        } else if (time <= proposal.endBlockOrTime) {
            return ProposalStatus.Active;
        } else if (proposal.votesFor <= 2 * proposal.votesAgainst || proposal.votesFor < minimumQuorum) {
            return ProposalStatus.Defeated;
        } else if (proposal.executed) {
            return ProposalStatus.Executed;
        } else {
            return ProposalStatus.Succeeded;
        }
    }

    function _qualifiedConsensus(
        IGovernanceState.Proposal memory proposal,
        uint256 minimumQuorum
    ) private view returns (bool) {
        return (3 * proposal.votesFor >
            2 *
                IStaking(_getStakingProxy())
                    .getGlobalStakeByStatus(IStructs.StakeStatus.DELEGATED)
                    .currentEpochBalance &&
            proposal.votesFor >= minimumQuorum);
    }

    /// @inheritdoc IGovernanceStrategy
    function getVotingPower(address account) public view override returns (uint256) {
        if (_mode == GovernanceMode.Receiver) return 0;
        return
            IStaking(_getStakingProxy())
                .getOwnerStakeByStatus(account, IStructs.StakeStatus.DELEGATED)
                .currentEpochBalance;
    }

    /// @inheritdoc IGovernanceStrategy
    function votingPeriod() public view override returns (uint256) {
        if (_mode == GovernanceMode.Receiver) return _votingPeriod;
        uint256 stakingEpochDuration = IStorage(_getStakingProxy()).epochDurationInSeconds();
        return stakingEpochDuration < _votingPeriod ? stakingEpochDuration : _votingPeriod;
    }

    /// @inheritdoc IGovernanceStrategy
    function votingTimestamps(
        TimeType timeType
    ) public view override returns (uint256 startBlockOrTime, uint256 endBlockOrTime) {
        _assertTimestamp(timeType);
        require(_mode != GovernanceMode.Receiver, GovLocalGovernanceDisabled());

        startBlockOrTime = IStaking(_getStakingProxy()).getCurrentEpochEarliestEndTimeInSeconds();

        // we require voting starts next block to prevent instant upgrade
        startBlockOrTime = block.timestamp >= startBlockOrTime ? block.timestamp + 1 : startBlockOrTime;

        endBlockOrTime = startBlockOrTime + votingPeriod();
    }

    /// @dev Reverts unless the governance uses TimeType.Timestamp.
    function _assertTimestamp(TimeType timeType) private pure {
        require(timeType == TimeType.Timestamp, GovStrategyInvalidTimeType(timeType));
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
        if (_mode == GovernanceMode.Receiver) {
            revert GovLocalGovernanceDisabled();
        } else if (_mode == GovernanceMode.Sender) {
            if (action.target != _wormhole) {
                return action;
            }
            // The wrapped action value is paid on the destination chain from the receiver's own
            // balance; Wormhole's fee is added at execution time in beforeExecute instead.
            require(action.value == 0, GovCrosschainInvalidValue(action.value));
            _assertValidWormholeData(action.data);
            return action;
        } else {
            // GovernanceMode.Dual: local proposals only, crosschain sending is exclusive to Sender
            if (action.target == _wormhole) {
                revert GovCrosschainNotSender();
            }
            return action;
        }
    }

    /// @notice Decodes a Wormhole publishMessage call and validates its inner payload.
    /// @dev Enforced at proposal time on the sender chain: every inner action must carry no
    ///      value, as the governance is expected to hold no native balance on receiver chains.
    function _assertValidWormholeData(bytes calldata data) private view {
        require(data.length >= 4 && bytes4(data) == ICoreBridge.publishMessage.selector, GovCrosschainInvalidData());

        (, bytes memory payload, uint8 consistencyLevel) = abi.decode(data[4:], (uint32, bytes, uint8));
        // 200 is Wormhole's finalized consistency level: mainnet votes must reach finality before attestation
        require(consistencyLevel == 200, GovCrosschainInvalidConsistencyLevel(consistencyLevel));
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
    function beforeExecute(
        IGovernanceVoting.ProposedAction memory action
    ) external view override returns (IGovernanceVoting.ProposedAction memory) {
        if (_mode == GovernanceMode.Receiver) {
            revert GovLocalGovernanceDisabled();
        } else if (_mode == GovernanceMode.Sender) {
            if (action.target != _wormhole) {
                return action;
            }
            // Wormhole requires msg.value == messageFee() on publishMessage, so the wrapper value
            // must be exactly the fee, overriding any (zero) value set at proposal time.
            action.value = ICoreBridge(_wormhole).messageFee();
            return action;
        } else {
            // GovernanceMode.Dual: wormhole actions cannot reach execution (beforePropose reverts them)
            return action;
        }
    }

    /// @inheritdoc IGovernanceStrategy
    function wormhole() external view override returns (address) {
        return _wormhole;
    }

    /// @inheritdoc IGovernanceStrategy
    function wormholeChainId() external view override returns (uint16) {
        return _wormholeChainId;
    }

    /// @notice It is more gas efficient at deploy to reading immutable from internal method.
    function _getStakingProxy() private view returns (address) {
        return _stakingProxy;
    }
}
