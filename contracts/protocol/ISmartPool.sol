// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2025 Rigo Intl.

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

import {IERC20} from "./interfaces/IERC20.sol";
import {ISmartPoolActions} from "./interfaces/pool/ISmartPoolActions.sol";
import {ISmartPoolEvents} from "./interfaces/pool/ISmartPoolEvents.sol";
import {ISmartPoolFallback} from "./interfaces/pool/ISmartPoolFallback.sol";
import {ISmartPoolImmutable} from "./interfaces/pool/ISmartPoolImmutable.sol";
import {ISmartPoolInitializer} from "./interfaces/pool/ISmartPoolInitializer.sol";
import {ISmartPoolOwnerActions} from "./interfaces/pool/ISmartPoolOwnerActions.sol";
import {ISmartPoolState} from "./interfaces/pool/ISmartPoolState.sol";
import {IStorageAccessible} from "./interfaces/pool/IStorageAccessible.sol";

/// @title Rigoblock V3 Pool Interface - Allows interaction with the pool contract.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
interface ISmartPool is
    IERC20,
    ISmartPoolImmutable,
    ISmartPoolEvents,
    ISmartPoolFallback,
    ISmartPoolInitializer,
    ISmartPoolActions,
    ISmartPoolOwnerActions,
    ISmartPoolState,
    IStorageAccessible
{}
