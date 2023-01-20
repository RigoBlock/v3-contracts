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

import "./MixinImmutables.sol";

abstract contract MixinStorage is MixinImmutables {
    struct DomainSeparator {
        bytes32 value;
    }

    function domainSeparator() internal pure returns (DomainSeparator storage s) {
        assembly {
            s.slot := _DOMAIN_SEPARATOR_SLOT
        }
    }

    struct StakingProxy {
        address value;
    }

    function stakingProxy() internal pure returns (StakingProxy storage s) {
        assembly {
            s.slot := _STAKING_PROXY_SLOT
        }
    }

    struct ParamsWrapper {
        TreasuryParameters treasuryParameters;
    }

    function paramsWrapper() internal pure returns (ParamsWrapper storage s) {
        assembly {
            s.slot := _TREASURY_PARAMS_SLOT
        }
    }

    // TODO: check where we can batch structs
    struct ProposalsCount {
        uint256 value;
    }

    function proposalsCount() internal pure returns (ProposalsCount storage s) {
        assembly {
            s.slot := _PROPOSALS_COUNT_SLOT
        }
    }

    struct Proposals {
        mapping(uint256 => Proposal) value;
    }

    function proposals() internal pure returns (Proposals storage s) {
        assembly {
            s.slot := _PROPOSALS_SLOT
        }
    }

    struct HasVoted {
        mapping(uint256 => mapping(address => bool)) value;
    }

    function hasVoted() internal pure returns (HasVoted storage s) {
        assembly {
            s.slot := _HAS_VOTED_SLOT
        }
    }
}