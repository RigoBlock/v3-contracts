// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {ISmartPoolActions} from "./interfaces/v4/pool/ISmartPoolActions.sol";
import {ISmartPoolEvents} from "./interfaces/v4/pool/ISmartPoolEvents.sol";
import {ISmartPoolFallback} from "./interfaces/v4/pool/ISmartPoolFallback.sol";
import {ISmartPoolImmutable} from "./interfaces/v4/pool/ISmartPoolImmutable.sol";
import {ISmartPoolInitializer} from "./interfaces/v4/pool/ISmartPoolInitializer.sol";
import {ISmartPoolOwnerActions} from "./interfaces/v4/pool/ISmartPoolOwnerActions.sol";
import {ISmartPoolState} from "./interfaces/v4/pool/ISmartPoolState.sol";
import {IStorageAccessible} from "./interfaces/v4/pool/IStorageAccessible.sol";

/// @title Rigoblock V3 Pool Interface - Allows interaction with the pool contract.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
interface ISmartPool is
    ISmartPoolImmutable,
    ISmartPoolEvents,
    ISmartPoolFallback,
    ISmartPoolInitializer,
    ISmartPoolActions,
    ISmartPoolOwnerActions,
    ISmartPoolState,
    IStorageAccessible
{}
