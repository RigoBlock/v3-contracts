// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2022-2025 Rigo Intl.

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

pragma solidity 0.8.28;

import {ISmartPool} from "./ISmartPool.sol";
import {MixinImmutables} from "./core/immutable/MixinImmutables.sol";
import {MixinStorage} from "./core/immutable/MixinStorage.sol";
import {MixinPoolState} from "./core/state/MixinPoolState.sol";
import {MixinStorageAccessible} from "./core/state/MixinStorageAccessible.sol";
import {MixinAbstract} from "./core/sys/MixinAbstract.sol";
import {MixinInitializer} from "./core/sys/MixinInitializer.sol";
import {MixinFallback} from "./core/sys/MixinFallback.sol";

/// @title ISmartPool - A set of rules for Rigoblock pools.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
contract SmartPool is
    ISmartPool,
    MixinStorage,
    MixinFallback,
    MixinInitializer,
    MixinAbstract,
    MixinPoolState,
    MixinStorageAccessible
{
    /// @notice Owner is initialized to 0 to lock owner actions in this implementation.
    /// @notice Kyc provider set as will effectively lock direct mint/burn actions.
    /// @notice ExtensionsMap validation is performed in MixinImmutables constructor.
    constructor(
        address authority,
        address extensionsMap,
        address wrappedNative
    ) MixinImmutables(authority, extensionsMap, wrappedNative) {
        // we lock implementation at deploy
        pool().owner = _ZERO_ADDRESS;
        poolParams().kycProvider == _BASE_TOKEN_FLAG;
    }
}
