// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {IGovernanceState} from "../interfaces/governance/IGovernanceState.sol";

abstract contract MixinAbstract {
    /// @notice Thrown when a function is called with an invalid proposal id.
    /// @param proposalId The supplied proposal id.
    error GovProposalIdInvalid(uint256 proposalId);

    function _getProposalCount() internal view virtual returns (uint256);

    function _getProposalState(uint256 proposalId) internal view virtual returns (IGovernanceState.ProposalState);

    function _getVotingPower(address account) internal view virtual returns (uint256);
}
