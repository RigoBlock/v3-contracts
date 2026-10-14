// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.0;

import {IGovernanceState} from "./governance/IGovernanceState.sol";
import {IRigoblockGovernanceFactory} from "./IRigoblockGovernanceFactory.sol";
import {ProposalStatus, ProposedAction, ProposalExtraData} from "../types/GovernanceTypes.sol";
import {TimeType} from "../types/TimeType.sol";

interface IGovernanceStrategy {
    /// @notice Thrown when the proposal threshold is outside the range the strategy can honor.
    error GovStrategyInvalidProposalThreshold(uint256 threshold);

    /// @notice Thrown when the quorum threshold is outside the range the strategy can honor.
    error GovStrategyInvalidQuorumThreshold(uint256 threshold);

    /// @notice Thrown when the strategy does not support the governance's configured time type.
    error GovStrategyInvalidTimeType(TimeType timeType);

    /// @notice Reverts unless the governance parameters are valid for this strategy.
    /// @dev Called at initialization and by parameter updates.
    /// @param params Tuple of factory parameters.
    function validateParams(IRigoblockGovernanceFactory.Parameters calldata params) external view;

    /// @notice Returns the state of a proposal.
    /// @param proposal Tuple of the proposal.
    /// @param proposer The stored proposal proposer.
    /// @param minimumQuorum Number of votes required for a proposal to pass.
    /// @param votingPower Total voting power snapshotted by the governance on the first vote.
    /// @param timeType Time reference used by the proposal's voting period.
    /// @return Tuple of the proposal state.
    function getProposalState(
        IGovernanceState.Proposal calldata proposal,
        address proposer,
        uint256 minimumQuorum,
        uint256 votingPower,
        TimeType timeType
    ) external view returns (ProposalStatus);

    /// @notice Return the voting period in the governance's time unit.
    /// @return Period duration in blocks or seconds.
    function votingPeriod() external view returns (uint256);

    /// @notice Return a user's voting power.
    /// @param account Address to check votes for.
    function getVotingPower(address account) external view returns (uint256);

    /// @notice Validates and optionally modifies the actions before they are stored, and returns
    ///         the proposal's voting window.
    /// @dev Called once per proposal; the returned window is stored in the proposal.
    function beforePropose(
        ProposedAction[] calldata actions
    ) external returns (ProposedAction[] memory, uint256 startBlockOrTime, uint256 endBlockOrTime);

    /// @notice Called before every vote. Returns the total voting power recognized at vote time.
    /// @param extraData The proposal's current extra data.
    /// @return totalVotingPower The total voting power the strategy recognizes right now.
    function beforeVote(ProposalExtraData calldata extraData) external returns (uint256 totalVotingPower);

    /// @notice Returns the actions as they should be executed, optionally modifying their values.
    /// @param actions The actions to execute.
    /// @return The actions to execute.
    function beforeExecute(ProposedAction[] calldata actions) external view returns (ProposedAction[] memory);

    /// @notice Returns the Wormhole core contract used for cross-chain governance.
    /// @return Address of the Wormhole core contract, or the zero address if this chain is not
    ///         configured as a cross-chain governance receiver.
    function wormhole() external view returns (address);
}
