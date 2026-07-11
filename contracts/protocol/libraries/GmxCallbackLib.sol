// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

import {EnumerableSet, AddressSet, Bytes32Set} from "./EnumerableSet.sol";

/// @title GmxCallbackLib
/// @notice Storage layout and helpers for the GMX v2 order callback extension.
///  The data is stored in the pool proxy and updated by `EGmxCallback` when
///  GMX keepers execute, cancel, or freeze orders.
/// @dev All state is ERC-7201 namespaced; `MixinStorage` asserts the slot.
library GmxCallbackLib {
    using EnumerableSet for AddressSet;
    using EnumerableSet for Bytes32Set;

    bytes32 internal constant GMX_CALLBACK_DATA_SLOT = bytes32(uint256(keccak256("pool.proxy.gmx.callback")) - 1);

    error InvalidCallbackAccount();

    /// @notice Metadata for a recorded claimable-collateral DataStore key.
    ///  The factor/reduction/claimed keys are recomputed at NAV time to minimize
    ///  callback gas costs.
    struct ClaimableCollateralInfo {
        address token;
        address market;
        uint256 timeKey;
    }

    /// @notice Storage layout for the GMX callback extension.
    struct GmxCallbackSlot {
        AddressSet trackedMarkets;
        Bytes32Set claimableCollateralKeys;
        mapping(bytes32 => ClaimableCollateralInfo) claimableCollateralInfo;
    }

    /// @notice Returns the GMX callback storage slot for the current pool.
    function gmxCallbackData() internal pure returns (GmxCallbackSlot storage s) {
        bytes32 slot = GMX_CALLBACK_DATA_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /// @notice Removes a market from the tracked set if it is no longer needed.
    function removeTrackedMarket(address market) internal {
        gmxCallbackData().trackedMarkets.remove(market);
    }

    /// @notice Removes a fully-claimed collateral key from the tracked set and metadata map.
    function removeClaimableCollateralKey(bytes32 key) internal {
        GmxCallbackSlot storage s = gmxCallbackData();
        if (s.claimableCollateralKeys.contains(key)) {
            s.claimableCollateralKeys.remove(key);
            delete s.claimableCollateralInfo[key];
        }
    }
}
