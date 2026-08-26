// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import "../IRigoblockGovernance.sol";
import "./IRigoblockGovernanceFactory.sol";

interface IGovernanceStrategy {
    /// @notice Reverts if initialization paramters are incorrect.
    /// @dev Only used at initialization, as params deleted from factory storage after setup.
    /// @param params Tuple of factory parameters.
    function assertValidInitParams(IRigoblockGovernanceFactory.Parameters calldata params) external view;

    /// @notice Reverts if thresholds are incorrect.
    /// @param proposalThreshold Number of votes required to make a proposal.
    /// @param quorumThreshold Number of votes required for a proposal to succeed.
    function assertValidThresholds(uint256 proposalThreshold, uint256 quorumThreshold) external view;

    /// @notice Returns the state of a proposal for a required quorum.
    /// @param proposal Tuple of the proposal.
    /// @param minimumQuorum Number of votes required for a proposal to pass.
    /// @return Tuple of the proposal state.
    function getProposalState(
        IRigoblockGovernance.Proposal calldata proposal,
        uint256 minimumQuorum
    ) external view returns (IRigoblockGovernance.ProposalState);

    /// @notice Return the voting period.
    /// @return Number of seconds of period duration.
    function votingPeriod() external view returns (uint256);

    /// @notice Returns the voting timestamps.
    /// @return startBlockOrTime Timestamp when proposal starts.
    /// @return endBlockOrTime Timestamp when voting ends.
    function votingTimestamps() external view returns (uint256 startBlockOrTime, uint256 endBlockOrTime);

    /// @notice Return a user's voting power.
    /// @param account Address to check votes for.
    function getVotingPower(address account) external view returns (uint256);

    /// @notice Reverts if a proposed action is invalid for this strategy.
    /// @dev The governance contract calls this hook for every action during
    ///      execution. Strategies can enforce chain-specific rules (e.g. a
    ///      Wormhole message must target the local Wormhole core and carry the
    ///      correct fee) without adding custom logic to the governance contract.
    /// @param action The action to validate.
    function validateAction(IRigoblockGovernance.ProposedAction calldata action) external view;
}
