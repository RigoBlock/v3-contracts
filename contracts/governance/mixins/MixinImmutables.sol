// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {MixinConstants} from "./MixinConstants.sol";

/// @notice Immutables are copied in the bytecode and not assigned a storage slot
/// @dev New immutables can safely be added to this contract without ordering.
abstract contract MixinImmutables is MixinConstants {
    /// @notice Wormhole chain id of the governance hub chain (the only chain that publishes
    ///         cross-chain governance messages). Identical on every deployment, so the
    ///         deterministic implementation address is unchanged across chains.
    uint16 internal immutable _HUB_WORMHOLE_CHAIN_ID;

    constructor(uint16 hubWormholeChainId) {
        _HUB_WORMHOLE_CHAIN_ID = hubWormholeChainId;
    }
}
