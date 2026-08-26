// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import "../IRigoblockGovernance.sol";

abstract contract MixinAbstract {
    function _getProposalCount() internal view virtual returns (uint256);

    function _getProposalState(uint256 proposalId) internal view virtual returns (IRigoblockGovernance.ProposalState);

    function _getVotingPower(address account) internal view virtual returns (uint256);
}
