// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.0;

import {ProposalStatus} from "../types/GovernanceTypes.sol";
import {IGovernanceState} from "./governance/IGovernanceState.sol";
import {IGovernanceVoting} from "./governance/IGovernanceVoting.sol";
import {IRigoblockGovernanceFactory} from "./IRigoblockGovernanceFactory.sol";
import {TimeType} from "../types/TimeType.sol";

interface IGovernanceStrategy {
    /// @notice Reverts if initialization paramters are incorrect.
    /// @dev Only used at initialization, as params deleted from factory storage after setup.
    /// @param params Tuple of factory parameters.
    function assertValidInitParams(IRigoblockGovernanceFactory.Parameters calldata params) external view;

    /// @notice Reverts if the proposal threshold is incorrect.
    /// @param proposalThreshold Number of votes required to make a proposal.
    function assertValidProposalThreshold(uint256 proposalThreshold) external view;

    /// @notice Reverts if the quorum threshold is incorrect.
    /// @param quorumThreshold Number of votes required for a proposal to succeed.
    function assertValidQuorumThreshold(uint256 quorumThreshold) external view;

    /// @notice Returns the state of a proposal for a required quorum.
    /// @dev Must use the same time reference as `timeType` and revert for unsupported time types.
    ///      See docs/governance/STRATEGY.md.
    /// @param proposal Tuple of the proposal.
    /// @param minimumQuorum Number of votes required for a proposal to pass.
    /// @param timeType Time reference used by the proposal's voting period.
    /// @return Tuple of the proposal state.
    function getProposalState(
        IGovernanceState.Proposal calldata proposal,
        uint256 minimumQuorum,
        TimeType timeType
    ) external view returns (ProposalStatus);

    /// @notice Return the voting period.
    /// @dev Informational only: the enforceable window is the one returned by votingTimestamps.
    /// @return Number of blocks or seconds of period duration, matching the governance's time type.
    function votingPeriod() external view returns (uint256);

    /// @notice Returns the voting timestamps.
    /// @dev Must produce start/end values expressed in the same unit as `timeType` (block numbers
    ///      for TimeType.Blocknumber, timestamps for TimeType.Timestamp). See getProposalState.
    /// @param timeType Time reference used by the proposal's voting period.
    /// @return startBlockOrTime Timestamp when proposal starts.
    /// @return endBlockOrTime Timestamp when voting ends.
    function votingTimestamps(
        TimeType timeType
    ) external view returns (uint256 startBlockOrTime, uint256 endBlockOrTime);

    /// @notice Return a user's voting power.
    /// @param account Address to check votes for.
    function getVotingPower(address account) external view returns (uint256);

    /// @notice Validates and optionally modifies an action before it is stored as part of a proposal.
    /// @param action The action to validate.
    /// @return The validated (possibly modified) action.
    function beforePropose(
        IGovernanceVoting.ProposedAction calldata action
    ) external view returns (IGovernanceVoting.ProposedAction memory);

    /// @notice Returns the action as it should be executed, optionally modifying the value.
    /// @param action The action to execute.
    /// @return The action to execute.
    function beforeExecute(
        IGovernanceVoting.ProposedAction calldata action
    ) external view returns (IGovernanceVoting.ProposedAction memory);

    /// @notice Returns the Wormhole core contract used for cross-chain governance.
    /// @return Address of the Wormhole core contract, or the zero address if this chain is not
    ///         configured as a cross-chain governance receiver.
    function wormhole() external view returns (address);

    /// @notice Returns the Wormhole chain id of the chain this strategy is deployed on.
    function wormholeChainId() external view returns (uint16);
}
