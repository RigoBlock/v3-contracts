// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2022 Rigo Intl.

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

import "../../interfaces/pool/IStructs.sol";
import "../../../utils/reentrancyGuard/ReentrancyGuard.sol";
import {OwnedUninitialized as Owned} from "../../../utils/owned/OwnedUninitialized.sol";

pragma solidity >=0.8.0 <0.9.0;

/// @notice Storage slots must be preserved to prevent storage clashing. Each new variable must be assigned
/// a dedicated (randomly big enough) storage slot and queried from slot, or added at the end of existing storage.
abstract contract MixinStorage is IStructs, Owned, ReentrancyGuard {
    // slot(0) declared in Owned contract
    //address public override owner;

    // slot(1) declared in ReentrancyGuard contract
    //bool private locked = false;

    // mappings are storage at a different storage location
    mapping(address => Account) internal userAccount;

    // slot(2)
    Admin internal admin;

    // slot(3)
    PoolData internal poolData;
}
