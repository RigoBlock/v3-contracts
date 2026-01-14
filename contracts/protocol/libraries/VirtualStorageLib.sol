// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

import {SlotDerivation} from "./SlotDerivation.sol";
import {IECrosschain} from "../extensions/adapters/interfaces/IECrosschain.sol";

/// @title VirtualStorageLib - Library for managing per-token virtual balances
/// @notice Provides functions to get and set virtual balances for individual tokens
/// @dev Uses ERC-7201 namespaced storage pattern with per-token mappings
library VirtualStorageLib {
    using SlotDerivation for bytes32;

    bytes32 public constant VIRTUAL_BALANCES_SLOT = 0x52fe1e3ba959a28a9d52ea27285aed82cfb0b6d02d0df76215ab2acc4b84d64f;

    bytes32 public constant VIRTUAL_SUPPLY_SLOT = 0xc1634c3ed93b1f7aa4d725c710ac3b239c1d30894404e630b60009ee3411450f;

    struct VirtualBalance {
        mapping(address token => int256 balance) balanceByToken;
    }

    function virtualBalance() internal pure returns (VirtualBalance storage s) {
        assembly {
            s.slot := VIRTUAL_BALANCES_SLOT
        }
    }

    struct VirtualSupply {
        int256 supply;
    }

    function virtualSupply() internal pure returns (VirtualSupply storage s) {
        assembly {
            s.slot := VIRTUAL_SUPPLY_SLOT
        }
    }

    function updateVirtualBalance(address token, int256 delta) internal {
        virtualBalance().balanceByToken[token] += delta;
        emit IECrosschain.VirtualBalanceUpdated(token, delta, virtualBalance().balanceByToken[token]);
    }

    function updateVirtualSupply(int256 delta) internal {
        virtualSupply().supply += delta;
        emit IECrosschain.VirtualSupplyUpdated(delta, virtualSupply().supply);
    }

    function getVirtualBalance(address token) internal view returns (int256) {
        return virtualBalance().balanceByToken[token];
    }

    function getVirtualSupply() internal view returns (int256) {
        return virtualSupply().supply;
    }
}
