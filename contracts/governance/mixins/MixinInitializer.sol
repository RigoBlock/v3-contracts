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
import "../interfaces/IRigoblockGovernanceFactory.sol";
import "./MixinStorage.sol";

abstract contract MixinInitializer is MixinStorage {
    modifier onlyUninitialized() {
        // proxy is always initialized in the constructor, therefore
        // empty extcodesize means the governance has not been initialized
        require(address(this).code.length == 0, "POOL_ALREADY_INITIALIZED_ERROR");
        _;
    }

    /// @inheritdoc IGovernanceInitializer
    function initializeGovernance() external override onlyUninitialized {
        IRigoblockGovernanceFactory.Parameters memory params = IRigoblockGovernanceFactory(msg.sender).parameters();

        require(params.votingPeriod < IStorage(params.stakingProxy).epochDurationInSeconds(), "VOTING_PERIOD_TOO_LONG");
        _stakingProxy().value = params.stakingProxy;
        _paramsWrapper().treasuryParameters = TreasuryParameters({
            votingPeriod: params.votingPeriod,
            proposalThreshold: params.proposalThreshold,
            quorumThreshold: params.quorumThreshold
        });
        _domainSeparator().value = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes(CONTRACT_NAME)),
                keccak256(bytes(CONTRACT_VERSION)),
                block.chainid,
                address(this)
            )
        );
    }
}
