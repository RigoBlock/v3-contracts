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

interface IGovernanceStrategy {
    /// @notice Checks whether the given proposal has passed or not.
    /// @param proposal The proposal to check.
    function hasProposalPassed(IRigoblockGovernance.Proposal calldata proposal, uint256 minimumQuorum) external view returns (bool);

    function votingPeriod() external view returns (uint256);

    function votingTimestamps() external view returns (uint256 startTime, uint256 endTime);

    function getVotingPower(address account) external view returns (uint256);
}
