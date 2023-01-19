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

import "../../staking/interfaces/IStorage.sol";
import "./MixinStorage.sol";

abstract contract MixinInitializer is MixinStorage {
    modifier onlyDelegatecall() virtual;

    /// @inheritdoc IRigoblockGovernance
    function initializeGovernance(
        address stakingProxy_,
        TreasuryParameters memory params
    )
        external
        onlyDelegatecall
        override
    {
        // assert uninitialized
        require(getStakingProxy() == address(0), "GOV_ALREADY_INIT_ERROR");
        require(params.votingPeriod < IStorage(stakingProxy_).epochDurationInSeconds(), "VOTING_PERIOD_TOO_LONG");
        stakingProxy().value = stakingProxy_;
        paramsWrapper().treasuryParameters = TreasuryParameters({
            votingPeriod: params.votingPeriod,
            proposalThreshold: params.proposalThreshold,
            quorumThreshold: params.quorumThreshold
        });
        domainSeparator().value = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes(CONTRACT_NAME)),
                block.chainid,
                keccak256(bytes(CONTRACT_VERSION)),
                address(this)
            )
        );
    }
}