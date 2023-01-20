// SPDX-License-Identifier: Apache-2.0-or-later
/*

 Copyright 2017-2022 RigoBlock, Rigo Investment Sagl, Rigo Intl.

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

// solhint-disable-next-line
interface IRigoblockGovernanceFactory {
    /// @notice Emitted when a governance is created.
    /// @param governance Address of the governance proxy.
    event GovernanceCreated(address governance);

    // TODO: complete docs
    /// @notice Creates a new governance.
    /// @param implementation .
    /// @param stakingProxy .
    /// @param votingPeriod .
    /// @param proposalThreshold .
    /// @param quorumThreshold .
    function createGovernance(
        address implementation,
        address stakingProxy,
        uint256 votingPeriod,
        uint256 proposalThreshold,
        uint256 quorumThreshold
    ) external returns (address governance);

    // TODO: fix docs
    /// @notice Governance initialization parameters.
    /// @param implementation .
    /// @param stakingProxy .
    /// @param votingPeriod .
    /// @param proposalThreshold .
    /// @param quorumThreshold .
    struct Parameters {
        address implementation;
        address stakingProxy;
        uint256 votingPeriod;
        uint256 proposalThreshold;
        uint256 quorumThreshold;
    }

    /// @notice Returns the pool initialization parameters at proxy deploy.
    /// @return Tuple of the pool parameters.
    function parameters() external view returns (Parameters memory);
}
