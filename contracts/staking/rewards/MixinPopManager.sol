// SPDX-License-Identifier: Apache 2.0
/*

  Original work Copyright 2019 ZeroEx Intl.
  Modified work Copyright 2020 Rigo Intl.

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

pragma solidity >=0.5.9 <0.8.0;
pragma experimental ABIEncoderV2;

import "../../utils/0xUtils/LibRichErrors.sol";
import "../libs/LibStakingRichErrors.sol";
import "../interfaces/IStakingEvents.sol";
import "../interfaces/IStaking.sol";
import "../immutable/MixinStorage.sol";


abstract contract MixinPopManager is
    IStaking,
    IStakingEvents,
    MixinStorage
{
    /// @dev Asserts that the call is coming from a valid pop.
    modifier onlyPop() {
        require(validPops[msg.sender], "STAKING_ONLY_CALLABLE_BY_POP_ERROR");
        _;
    }

    /// @dev Adds a new pop address.
    /// @param addr Address of pop contract to add.
    function addPopAddress(address addr)
        external
        override
        onlyAuthorized
    {
        require(!validPops[addr], "STAKING_POP_ALREADY_REGISTERED_ERROR");
        validPops[addr] = true;
        emit PopAdded(addr);
    }

    /// @dev Removes an existing proof_of_performance address.
    /// @param addr Address of proof_of_performance contract to remove.
    function removePopAddress(address addr)
        external
        override
        onlyAuthorized
    {
        require(validPops[addr], "STAKING_POP_NOT_REGISTERED_ERROR");
        validPops[addr] = false;
        emit PopRemoved(addr);
    }
}
