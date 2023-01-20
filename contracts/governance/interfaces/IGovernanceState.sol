// SPDX-License-Identifier: Apache-2.0
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

import "./IGovernanceInitializer.sol";

interface IGovernanceState {
    function getStakingProxy() external view returns (address);
    function treasuryParameters() external view returns (IGovernanceInitializer.TreasuryParameters memory);

    /// @notice Returns the total number of proposals.
    /// @return count The number of proposals.
    function proposalCount() external view returns (uint256 count);

    // @notice Computes the current voting power of the given account.
    /// @dev Voting power is equal to staked delegated GRG.
    /// @param account The address of the account.
    /// @return votingPower The current voting power of the given account.
    function getVotingPower(address account) external view returns (uint256 votingPower);
}