// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {ICoreBridge} from "wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol";

import {CrossChainPayload, ProposalStatus} from "../types/GovernanceTypes.sol";
import {IGovernanceState} from "../interfaces/governance/IGovernanceState.sol";
import {IGovernanceStrategy} from "../interfaces/IGovernanceStrategy.sol";
import {IGovernanceVoting} from "../interfaces/governance/IGovernanceVoting.sol";
import {IRigoblockGovernanceFactory} from "../interfaces/IRigoblockGovernanceFactory.sol";
import {IStaking} from "../../staking/interfaces/IStaking.sol";
import {IStorage} from "../../staking/interfaces/IStorage.sol";
import {IStructs} from "../../staking/interfaces/IStructs.sol";
import {TimeType} from "../types/TimeType.sol";

/// @notice Governance mode of a chain, fixed in the strategy at deployment.
/// @dev See the governance documentation for per-mode behavior. Encoded as uint8; value
///      numbering is part of the deployment configuration and must never change.
enum GovernanceMode {
    Sender,
    Dual,
    Receiver
}

/// @title RigoblockGovernanceStrategy - Custom specs of the Rigoblock governance.
/// @dev Each strategy contract is specific to the governance model and may vary by chain.
contract RigoblockGovernanceStrategy is IGovernanceStrategy {
    /// @notice Wormhole core contract on the same chain as this strategy.
    address private immutable _wormhole;

    /// @notice Maximum voting period; receiver chains always use it.
    uint256 private constant _VOTING_PERIOD = 7 days;

    /// @notice Challenge window between a recovery request and its activation.
    uint256 private constant _RECOVERY_WINDOW = 45 days;

    /// @notice The Rigoblock governance proxy, identical on every chain; authenticates a recovery rejection.
    address private constant _GOVERNANCE_PROXY = 0x5F8607739c2D2d0b57a4292868C368AB1809767a;

    /// @notice Wormhole chain id of the chain this strategy is deployed on.
    uint16 private immutable _wormholeChainId;

    address private immutable _stakingProxy;

    /// @notice Governance mode of the chain this strategy is deployed on.
    GovernanceMode private immutable _mode;

    /// @notice Pre-designated recovery address; only meaningful on receiver chains.
    address private immutable _recoveryAddress;

    uint256 private _recoveryRequestedAt;

    constructor(
        address stakingProxy,
        address wormhole,
        uint16 wormholeChainId,
        GovernanceMode mode,
        address recoveryAddress
    ) {
        _wormhole = wormhole;
        _wormholeChainId = wormholeChainId;
        _mode = mode;
        // receiver chains never read staking; the recovery address is receiver-only
        if (mode == GovernanceMode.Receiver) {
            require(recoveryAddress != address(0), GovRecoveryAddressZero());
            _recoveryAddress = recoveryAddress;
        } else {
            _stakingProxy = stakingProxy;
        }
    }

    /// @inheritdoc IGovernanceStrategy
    function requestRecover() external override {
        require(msg.sender == _recoveryAddress, GovRecoveryUnauthorized(msg.sender));
        // a nonzero timestamp covers a pending request and an active recovery alike:
        // re-requesting an active recovery would overwrite its timestamp and disarm it
        require(_recoveryRequestedAt == 0, GovRecoveryAlreadyPending());
        _recoveryRequestedAt = block.timestamp;
        emit RecoverRequested(block.timestamp);
    }

    /// @inheritdoc IGovernanceStrategy
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
        _assertTimestamp(timeType);
        uint256 time = block.timestamp;
        // fail closed on receiver chains unless an active recovery authorizes local governance
        if (_mode == GovernanceMode.Receiver && !_isRecoveryActive()) return ProposalStatus.Defeated;
        if (time <= proposal.startBlockOrTime) {
            return ProposalStatus.Pending;
        } else if (time <= proposal.endBlockOrTime && _qualifiedConsensus(proposal, minimumQuorum)) {
            // notice: because in rigoblock staking we use epochs, the exact start time will never perfectly match the new epoch
            // using timestamps instead of epoch is a safeguard for upgrades, should the staking system get stuck by being unable to finalize.
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
        if (_mode == GovernanceMode.Receiver) {
            // the recovery address holds superquorum by design
            return proposal.votesFor >= minimumQuorum;
        }
        return (3 * proposal.votesFor >
            2 *
                IStaking(_getStakingProxy())
                    .getGlobalStakeByStatus(IStructs.StakeStatus.DELEGATED)
                    .currentEpochBalance &&
            proposal.votesFor >= minimumQuorum);
    }

    /// @inheritdoc IGovernanceStrategy
    function getVotingPower(address account) public view override returns (uint256) {
        if (_mode == GovernanceMode.Receiver) {
            // uint96: fits the vote receipt, far above any real quorum, no external reads
            return _isRecoveryActive() && account == _recoveryAddress ? type(uint96).max : 0;
        }
        return
            IStaking(_getStakingProxy())
                .getOwnerStakeByStatus(account, IStructs.StakeStatus.DELEGATED)
                .currentEpochBalance;
    }

    /// @inheritdoc IGovernanceStrategy
    function votingPeriod() public view override returns (uint256) {
        if (_mode == GovernanceMode.Receiver) return _VOTING_PERIOD;
        uint256 stakingEpochDuration = IStorage(_getStakingProxy()).epochDurationInSeconds();
        return stakingEpochDuration < _VOTING_PERIOD ? stakingEpochDuration : _VOTING_PERIOD;
    }

    /// @inheritdoc IGovernanceStrategy
    function votingTimestamps(
        TimeType timeType
    ) public view override returns (uint256 startBlockOrTime, uint256 endBlockOrTime) {
        _assertTimestamp(timeType);

        if (_mode == GovernanceMode.Receiver) {
            // recovery has no flash-vote risk: power is fixed to the recovery address
            require(_isRecoveryActive(), GovLocalGovernanceDisabled());
            startBlockOrTime = block.timestamp;
        } else {
            // we require voting starts next block to prevent instant upgrade
            startBlockOrTime = IStaking(_getStakingProxy()).getCurrentEpochEarliestEndTimeInSeconds();
            startBlockOrTime = block.timestamp >= startBlockOrTime ? block.timestamp + 1 : startBlockOrTime;
        }

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
            require(_isRecoveryActive(), GovLocalGovernanceDisabled());
            // fails fast: publishing would revert on the fee at execution time
            if (action.target == _wormhole) {
                revert GovCrosschainNotSender();
            }
            return action;
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
            require(_isRecoveryActive(), GovLocalGovernanceDisabled());
            // fails fast: publishing would revert on the fee at execution time
            if (action.target == _wormhole) {
                revert GovCrosschainNotSender();
            }
            return action;
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

    function _isRecoveryActive() private view returns (bool) {
        uint256 requestedAt = _recoveryRequestedAt;
        return requestedAt != 0 && block.timestamp >= requestedAt + _RECOVERY_WINDOW;
    }
}
