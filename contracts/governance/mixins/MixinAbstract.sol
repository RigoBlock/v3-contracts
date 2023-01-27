// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2023 Rigo Intl.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.

*/

pragma solidity >=0.8.0 <0.9.0;

import "../IRigoblockGovernance.sol";

abstract contract MixinAbstract {
    function _getGovernanceParameters() internal view virtual returns (IGovernanceState.GovernanceParameters memory);

    function _getProposalCount() internal view virtual returns (uint256);

    function _getProposalState(uint256 proposalId) internal view virtual returns (IRigoblockGovernance.ProposalState);

    // TODO: not sure we are using this
    function _getReceipt(uint256 proposalId, address voter) internal view virtual returns (IRigoblockGovernance.Receipt memory);

    function _getVotingPower(address account) internal view virtual returns (uint256);

    function _hasProposalPassed(IRigoblockGovernance.Proposal memory proposal) internal view virtual returns (bool);
}
