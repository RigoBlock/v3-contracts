// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import "./MixinConstants.sol";

/// @notice Immutables are copied in the bytecode and not assigned a storage slot
/// @dev New immutables can safely be added to this contract without ordering.
abstract contract MixinImmutables is MixinConstants {
    constructor() {}
}
