// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {IRigoblockGovernance} from "../../../../governance/IRigoblockGovernance.sol";

interface IAGovernance {
    /// @notice Allows to make a proposal to the Rigoblock governance.
    /// @param actions Array of tuples of proposed actions.
    /// @param description A human-readable description.
    /// @return proposalId Number of the newly created proposal.
    function propose(
        IRigoblockGovernance.ProposedAction[] calldata actions,
        string calldata description
    ) external returns (uint256 proposalId);

    /// @notice Allows a pool to vote on a proposal.
    /// @param proposalId Number of the proposal.
    /// @param voteType Enum of the vote type.
    function castVote(uint256 proposalId, IRigoblockGovernance.VoteType voteType) external;

    /// @notice Allows a pool to execute a proposal.
    /// @dev Payable to support proposals whose actions carry native value.
    /// @param proposalId Number of the proposal.
    function execute(uint256 proposalId) external payable;
}
