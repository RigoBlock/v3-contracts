// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {ICoreBridge} from "wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol";
import {IGovernanceState} from "../interfaces/governance/IGovernanceState.sol";
import {IGovernanceStrategy} from "../interfaces/IGovernanceStrategy.sol";
import {IRigoblockGovernanceFactory} from "../interfaces/IRigoblockGovernanceFactory.sol";
import {ProposalStatus, ProposedAction} from "../types/GovernanceTypes.sol";
import {TimeType} from "../types/TimeType.sol";
import {IWormholeReceiverStrategy} from "./interfaces/IWormholeReceiverStrategy.sol";

/// @title WormholeReceiverStrategy - Receiver-chain governance strategy.
/// @dev Staking-free: local governance is fail-closed and the only execution path is
///      cross-chain messages delivered from the sender chain. A recovery escape hatch
///      (see the governance documentation) covers bridge failure.
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

    constructor(address wormhole, address governanceProxy, address recoveryAddress) {
        require(wormhole.code.length > 0, GovRecoveryAddressZero());
        try ICoreBridge(wormhole).chainId() returns (uint16) {} catch {
            revert GovRecoveryAddressZero();
        }
        require(governanceProxy != address(0), GovRecoveryAddressZero());
        require(recoveryAddress != address(0), GovRecoveryAddressZero());
        _wormhole = wormhole;
        _governanceProxy = governanceProxy;
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
        require(msg.sender == _governanceProxy, GovRecoveryUnauthorized(msg.sender));
        require(_recoveryRequestedAt != 0, GovRecoveryNotPending());
        _recoveryRequestedAt = 0;
        emit RecoverRejected();
    }

    /// @inheritdoc IGovernanceStrategy
    /// @dev Receiver governance has no voting thresholds, so any value is accepted.
    function validateParams(IRigoblockGovernanceFactory.Parameters memory params) external view override {
        assert(keccak256(abi.encodePacked(params.name)) == keccak256(abi.encodePacked(string("Rigoblock Governance"))));
    }

    /// @inheritdoc IGovernanceStrategy
    /// @dev Local governance is fail-closed: only the recovery address can pass a proposal,
    ///      and only while a recovery is active. Execution status is handled here, first.
    function getProposalState(
        IGovernanceState.Proposal memory proposal,
        address proposer,
        uint256,
        uint256,
        TimeType
    ) external view override returns (ProposalStatus) {
        // executed is terminal and must be reported regardless of the clock or recovery state
        if (proposal.executed) return ProposalStatus.Executed;
        if (proposer == _recoveryAddress && _isRecoveryActive()) return ProposalStatus.Succeeded;
        return ProposalStatus.Defeated;
    }

    /// @inheritdoc IGovernanceStrategy
    function getVotingPower(address account) public view override returns (uint256) {
        // the recovery address must always be able to pass the proposer-threshold gate,
        // regardless of the configured threshold value
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
        return (actions, block.timestamp, block.timestamp);
    }

    /// @inheritdoc IGovernanceStrategy
    /// @dev No staking on receiver chains.
    function beforeVote() external pure override returns (uint256) {
        return 0;
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
