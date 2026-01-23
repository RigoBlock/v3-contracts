// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

import {IECrosschain} from "../extensions/adapters/interfaces/IECrosschain.sol";

/// @title VirtualStorageLib - Library for managing virtual supply for cross-chain operations
/// @notice Provides functions to get and update virtual supply (VS-only model)
/// @dev Uses ERC-7201 namespaced storage pattern
/// @dev VS-only model: Transfer writes negative VS on source (NAV-neutral), positive VS on destination
///      Sync has no VS impact (NAV-impacting on both chains)
library VirtualStorageLib {
    bytes32 public constant VIRTUAL_SUPPLY_SLOT = 0xc1634c3ed93b1f7aa4d725c710ac3b239c1d30894404e630b60009ee3411450f;

    struct VirtualSupply {
        int256 supply;
    }

    function virtualSupply() internal pure returns (VirtualSupply storage s) {
        assembly {
            s.slot := VIRTUAL_SUPPLY_SLOT
        }
    }

    function updateVirtualSupply(int256 delta) internal {
        virtualSupply().supply += delta;
        emit IECrosschain.VirtualSupplyUpdated(delta, virtualSupply().supply);
    }

    function getVirtualSupply() internal view returns (int256) {
        return virtualSupply().supply;
    }
}
