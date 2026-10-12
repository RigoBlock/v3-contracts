// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {IGovernanceState} from "../interfaces/governance/IGovernanceState.sol";
import {IGovernanceStrategy} from "../interfaces/IGovernanceStrategy.sol";
import {IGovernanceVoting} from "../interfaces/governance/IGovernanceVoting.sol";
import {IRigoblockGovernanceFactory} from "../interfaces/IRigoblockGovernanceFactory.sol";
import {ProposalStatus} from "../types/GovernanceTypes.sol";
import {TimeType} from "../types/TimeType.sol";
import {IWormholeReceiverStrategy} from "./interfaces/IWormholeReceiverStrategy.sol";

/// @title WormholeReceiverStrategy - Receiver-chain governance strategy.
/// @dev Staking-free: local governance is fail-closed and the only execution path is
///      cross-chain messages delivered from the sender chain. A recovery escape hatch
///      (see the governance documentation) covers bridge failure.
contract WormholeReceiverStrategy is IGovernanceStrategy, IWormholeReceiverStrategy {
    /// @notice Wormhole core contract on the same chain as this strategy.
    address private immutable _wormhole;

    /// @notice Fixed voting period; the recovery address has no flash-vote risk.
    uint256 private constant _VOTING_PERIOD = 7 days;

    /// @notice Challenge window between a recovery request and its activation.
    uint256 private constant _RECOVERY_WINDOW = 60 days;

    /// @notice The Rigoblock governance proxy, identical on every chain; authenticates a recovery rejection.
    address private constant _GOVERNANCE_PROXY = 0x5F8607739c2D2d0b57a4292868C368AB1809767a;

    /// @notice Wormhole chain id of the chain this strategy is deployed on.
    uint16 private immutable _wormholeChainId;

    /// @notice Pre-designated recovery address.
    address private immutable _recoveryAddress;

    uint256 private _recoveryRequestedAt;

    constructor(address wormhole, uint16 wormholeChainId, address recoveryAddress) {
        require(recoveryAddress != address(0), GovRecoveryAddressZero());
        _wormhole = wormhole;
        _wormholeChainId = wormholeChainId;
        _recoveryAddress = recoveryAddress;
    }

    /// @inheritdoc IWormholeReceiverStrategy
    function requestRecover() external override {
        require(msg.sender == _recoveryAddress, GovRecoveryUnauthorized(msg.sender));
        // a nonzero timestamp covers a pending request and an active recovery alike:
        // re-requesting an active recovery would overwrite its timestamp and disarm it
        require(_recoveryRequestedAt == 0, GovRecoveryAlreadyPending());
        _recoveryRequestedAt = block.timestamp;
        emit RecoverRequested(block.timestamp);
    }

    /// @inheritdoc IWormholeReceiverStrategy
    function rejectRecover() external override {
        require(msg.sender == _GOVERNANCE_PROXY, GovRecoveryUnauthorized(msg.sender));
        require(_recoveryRequestedAt != 0, GovRecoveryNotPending());
        _recoveryRequestedAt = 0;
        emit RecoverRejected();
    }

    /// @inheritdoc IGovernanceStrategy
    function assertValidInitParams(IRigoblockGovernanceFactory.Parameters memory params) external view override {
        _assertTimestamp(params.timeType);
        assert(keccak256(abi.encodePacked(params.name)) == keccak256(abi.encodePacked(string("Rigoblock Governance"))));
        assertValidProposalThreshold(params.proposalThreshold);
        assertValidQuorumThreshold(params.quorumThreshold);
    }

    /// @inheritdoc IGovernanceStrategy
    function assertValidProposalThreshold(uint256 proposalThreshold) public pure override {
        _assertValidReceiverThreshold(proposalThreshold);
    }

    /// @inheritdoc IGovernanceStrategy
    function assertValidQuorumThreshold(uint256 quorumThreshold) public pure override {
        _assertValidReceiverThreshold(quorumThreshold);
    }

    /// @dev Thresholds must stay within the recovery address's fixed voting power.
    function _assertValidReceiverThreshold(uint256 threshold) private pure {
        require(threshold != 0 && threshold <= type(uint96).max, GovStrategyInvalidReceiverThreshold(threshold));
    }

    /// @inheritdoc IGovernanceStrategy
    function getProposalState(
        IGovernanceState.Proposal memory proposal,
        uint256 minimumQuorum,
        uint256,
        TimeType timeType
    ) external view override returns (ProposalStatus) {
        _assertTimestamp(timeType);
        uint256 time = block.timestamp;
        // executed is terminal and must be reported regardless of the recovery state
        if (proposal.executed) return ProposalStatus.Executed;
        // fail closed unless an active recovery authorizes local governance
        if (!_isRecoveryActive()) return ProposalStatus.Defeated;
        if (time <= proposal.startBlockOrTime) {
            return ProposalStatus.Pending;
        } else if (time <= proposal.endBlockOrTime && proposal.votesFor >= minimumQuorum) {
            return ProposalStatus.Qualified;
        } else if (time <= proposal.endBlockOrTime) {
            return ProposalStatus.Active;
        } else if (proposal.votesFor <= 2 * proposal.votesAgainst || proposal.votesFor < minimumQuorum) {
            return ProposalStatus.Defeated;
        } else {
            return ProposalStatus.Succeeded;
        }
    }

    /// @inheritdoc IGovernanceStrategy
    function totalVotingPower() external pure override returns (uint256) {
        return 0;
    }

    /// @inheritdoc IGovernanceStrategy
    function getVotingPower(address account) public view override returns (uint256) {
        // uint96: fits the vote receipt, far above any real quorum, no external reads
        return _isRecoveryActive() && account == _recoveryAddress ? type(uint96).max : 0;
    }

    /// @inheritdoc IGovernanceStrategy
    function votingPeriod() public pure override returns (uint256) {
        return _VOTING_PERIOD;
    }

    /// @inheritdoc IGovernanceStrategy
    function votingTimestamps(
        TimeType timeType
    ) public view override returns (uint256 startBlockOrTime, uint256 endBlockOrTime) {
        _assertTimestamp(timeType);
        // recovery has no flash-vote risk: power is fixed to the recovery address
        require(_isRecoveryActive(), GovLocalGovernanceDisabled());
        startBlockOrTime = block.timestamp;
        endBlockOrTime = startBlockOrTime + _VOTING_PERIOD;
    }

    /// @inheritdoc IGovernanceStrategy
    function beforeVote(uint256) external pure override returns (uint256) {
        return 0;
    }

    /// @inheritdoc IGovernanceStrategy
    function beforePropose(
        IGovernanceVoting.ProposedAction[] calldata actions
    ) external view override returns (IGovernanceVoting.ProposedAction[] memory) {
        require(_isRecoveryActive(), GovLocalGovernanceDisabled());
        for (uint256 i = 0; i < actions.length; i++) {
            // fails fast: publishing would revert on the fee at execution time
            if (actions[i].target == _wormhole) {
                revert GovCrosschainNotSender();
            }
        }
        return actions;
    }

    /// @inheritdoc IGovernanceStrategy
    function beforeExecute(
        IGovernanceVoting.ProposedAction[] calldata actions
    ) external view override returns (IGovernanceVoting.ProposedAction[] memory) {
        require(_isRecoveryActive(), GovLocalGovernanceDisabled());
        for (uint256 i = 0; i < actions.length; i++) {
            // fails fast: publishing would revert on the fee at execution time
            if (actions[i].target == _wormhole) {
                revert GovCrosschainNotSender();
            }
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

    /// @dev Reverts unless the governance uses TimeType.Timestamp.
    function _assertTimestamp(TimeType timeType) private pure {
        require(timeType == TimeType.Timestamp, GovStrategyInvalidTimeType(timeType));
    }

    function _isRecoveryActive() private view returns (bool) {
        uint256 requestedAt = _recoveryRequestedAt;
        return requestedAt != 0 && block.timestamp >= requestedAt + _RECOVERY_WINDOW;
    }
}
