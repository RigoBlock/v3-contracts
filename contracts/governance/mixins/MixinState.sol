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

import "../../staking/interfaces/IStaking.sol";
import "./MixinAbstract.sol";
import "./MixinStorage.sol";

abstract contract MixinState is MixinStorage, MixinAbstract {
    function getStakingProxy()
        public
        view
        override
        returns (address)
    {
        return _getStakingProxy();
    }

    /// @inheritdoc IGovernanceState
    function getVotingPower(address account)
        public
        view
        override
        returns (uint256)
    {
        return _getVotingPower(account);
    }

    /// @inheritdoc IGovernanceState
    function proposalCount()
        public
        view
        override
        returns (uint256 count)
    {
        return _proposalCount();
    }

    function treasuryParameters()
        public
        view
        override
        returns (TreasuryParameters memory)
    {
        return _treasuryParameters();
    }

    function getProposals() public view override returns (Proposal[] memory proposalList) {
        // TODO: test as we are not producing a new array
        for (uint i; i < _proposalCount(); ++i) {
            proposalList[i] = proposals().value[i];
        }
    }

    function _getStakingProxy()
        internal
        view
        override
        returns (address)
    {
        return stakingProxy().value;
    }

    function _getVotingPower(address account)
        internal
        view
        override
        returns (uint256)
    {
        return IStaking(getStakingProxy())
            .getOwnerStakeByStatus(account, IStructs.StakeStatus.DELEGATED)
            .currentEpochBalance;
    }

    function _proposalCount()
        internal
        view
        override
        returns (uint256 count)
    {
        return proposalsCount().value;
    }

    function _treasuryParameters()
        internal
        view
        override
        returns (TreasuryParameters memory)
    {
        return paramsWrapper().treasuryParameters;
    }
}