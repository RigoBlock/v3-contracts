// SPDX-License-Identifier: Apache-2.0-or-later
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
        address tokenJar
    ) MixinImmutables(authority, extensionsMap, tokenJar) {
        // we lock implementation at deploy
        pool().owner = _ZERO_ADDRESS;
        poolParams().kycProvider == _BASE_TOKEN_FLAG;
    }
}
