// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {ICoreBridge} from "wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol";
import {IGovernanceState} from "../interfaces/governance/IGovernanceState.sol";
import {IGovernanceStrategy} from "../interfaces/IGovernanceStrategy.sol";
import {IRigoblockGovernanceFactory} from "../interfaces/IRigoblockGovernanceFactory.sol";
import {ProposalStatus, ProposedAction, ProposalExtraData} from "../types/GovernanceTypes.sol";
import {TimeType} from "../types/TimeType.sol";
import {IWormholeReceiverStrategy} from "./interfaces/IWormholeReceiverStrategy.sol";

/// @title WormholeReceiverStrategy - Receiver-chain governance strategy.
/// @dev Staking-free and fail-closed: the only execution path is cross-chain delivery.
///      See docs/governance/RECOVERY.md for the recovery escape hatch.
contract WormholeReceiverStrategy is IGovernanceStrategy, IWormholeReceiverStrategy {
    /// @notice Challenge window between a recovery request and its activation.
    uint256 private constant _RECOVERY_WINDOW = 60 days;

    /// @notice Wormhole core contract on the same chain as this strategy.
    address private immutable _wormhole;

    /// @notice The Rigoblock governance proxy, identical on every chain; authenticates a recovery rejection.
    address private immutable _governanceProxy;

    /// @notice Pre-designated recovery address.
    address private immutable _recoveryAddress;

    uint256 private _recoveryRequestedAt;

    constructor(address coreBridge, address governanceProxy, address recoveryAddress) {
        require(coreBridge.code.length > 0, GovRecoveryAddressZero());
        try ICoreBridge(coreBridge).chainId() returns (uint16) {} catch {
            revert GovRecoveryAddressZero();
        }
        // the proxy cannot be probed yet; code.length rules out the zero address and EOAs
        require(governanceProxy.code.length > 0, GovRecoveryInvalidProxy(governanceProxy));
        require(recoveryAddress != address(0), GovRecoveryAddressZero());
        _wormhole = coreBridge;
        _governanceProxy = governanceProxy;
        _recoveryAddress = recoveryAddress;
    }

    /// @inheritdoc IWormholeReceiverStrategy
    function requestRecover() external override {
        require(msg.sender == _recoveryAddress, GovRecoveryUnauthorized(msg.sender));
        // slither-disable-next-line incorrect-equality -- sentinel check on a timestamp, not an economic value
        require(_recoveryRequestedAt == 0, GovRecoveryAlreadyPending());
        _recoveryRequestedAt = block.timestamp;
        emit RecoverRequested(block.timestamp);
    }

    /// @inheritdoc IWormholeReceiverStrategy
    function rejectRecover() external override {
        require(msg.sender == _governanceProxy, GovRecoveryUnauthorized(msg.sender));
        require(_recoveryRequestedAt != 0, GovRecoveryNotPending());
        _recoveryRequestedAt = 0;
        emit RecoverRejected();
    }

    /// @inheritdoc IGovernanceStrategy
    /// @dev Thresholds are bounded by the recovery address's hardcoded voting power.
    function validateParams(IRigoblockGovernanceFactory.Parameters memory params) external view override {
        assert(keccak256(abi.encodePacked(params.name)) == keccak256(abi.encodePacked(string("Rigoblock Governance"))));
        require(params.timeType == TimeType.Timestamp, GovStrategyInvalidTimeType(params.timeType));
        require(
            params.proposalThreshold > 0 && params.proposalThreshold <= type(uint96).max,
            GovStrategyInvalidProposalThreshold(params.proposalThreshold)
        );
        require(
            params.quorumThreshold > 0 && params.quorumThreshold <= type(uint96).max,
            GovStrategyInvalidQuorumThreshold(params.quorumThreshold)
        );
    }

    /// @inheritdoc IGovernanceStrategy
    /// @dev Fail-closed: only the recovery address passes, and only during an active recovery.
    function getProposalState(
        IGovernanceState.Proposal memory proposal,
        address proposer,
        uint256,
        uint256,
        TimeType
    ) external view override returns (ProposalStatus) {
        // executed is terminal and reported first
        if (proposal.executed) return ProposalStatus.Executed;
        if (proposer == _recoveryAddress && _isRecoveryActive()) return ProposalStatus.Succeeded;
        return ProposalStatus.Defeated;
    }

    /// @inheritdoc IGovernanceStrategy
    function getVotingPower(address account) public view override returns (uint256) {
        // the recovery address always passes the proposer-threshold gate
        return _isRecoveryActive() && account == _recoveryAddress ? type(uint96).max : 0;
    }

    /// @inheritdoc IGovernanceStrategy
    /// @dev Receiver governance has no voting period.
    function votingPeriod() public pure override returns (uint256) {
        return 0;
    }

    /// @inheritdoc IGovernanceStrategy
    function beforePropose(
        ProposedAction[] calldata actions
    ) external view override returns (ProposedAction[] memory, uint256 startBlockOrTime, uint256 endBlockOrTime) {
        require(_isRecoveryActive(), GovLocalGovernanceDisabled());

        for (uint256 i = 0; i < actions.length; i++) {
            // early revert as a wormhole action would revert during execution
            require(actions[i].target != _wormhole, GovCrosschainNotSender());
        }

        return (actions, block.timestamp, block.timestamp);
    }

    /// @inheritdoc IGovernanceStrategy
    /// @dev Effectively unreachable: receiver proposals are never Active, so no vote reaches
    ///      this hook in production.
    function beforeVote(ProposalExtraData calldata) external override returns (uint256) {
        return _isRecoveryActive() ? type(uint96).max : 0;
    }

    /// @inheritdoc IGovernanceStrategy
    function beforeExecute(ProposedAction[] calldata actions) external pure override returns (ProposedAction[] memory) {
        return actions;
    }

    /// @inheritdoc IGovernanceStrategy
    function wormhole() external view override returns (address) {
        return _wormhole;
    }

    function _isRecoveryActive() private view returns (bool) {
        uint256 requestedAt = _recoveryRequestedAt;
        return requestedAt != 0 && block.timestamp >= requestedAt + _RECOVERY_WINDOW;
    }
}
