// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {ProposalStatus} from "../types/GovernanceTypes.sol";

abstract contract MixinAbstract {
    /// @notice Thrown when a function is called with an invalid proposal id.
    /// @param proposalId The supplied proposal id.
    error GovProposalIdInvalid(uint256 proposalId);

    function _getProposalCount() internal view virtual returns (uint256);

    function _getProposalState(uint256 proposalId) internal view virtual returns (ProposalStatus);

    function _getVotingPower(address account) internal view virtual returns (uint256);

    /// @dev Canonical OpenZeppelin proposal hash formula, shared by the public view and the mixin call sites.
    function _hashProposal(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(targets, values, calldatas, descriptionHash)));
    }
}
