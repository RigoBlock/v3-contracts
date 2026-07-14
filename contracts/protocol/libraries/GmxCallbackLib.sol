// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

import {EnumerableSet, Bytes32Set} from "./EnumerableSet.sol";

/// @title GmxCallbackLib
/// @notice Storage layout and helpers for the GMX v2 order callback extension.
///  The data is stored in the pool proxy and updated by `EGmxCallback` when
///  GMX keepers execute, cancel, or freeze orders.
/// @dev All state is ERC-7201 namespaced; `MixinStorage` asserts the slot.
library GmxCallbackLib {
    using EnumerableSet for Bytes32Set;

    /// @notice ERC-7201 slot for GMX callback data.
    /// @dev Must stay in sync with `MixinStorage` assertion.
    bytes32 internal constant GMX_CALLBACK_DATA_SLOT =
        0xef0ce2d52a301ad6c6e80df0060b9ecd4dec1ba111fe46b11bf9055649205071;

    /// @notice GMX v2 DataStore keys used by the callback extension and NAV accounting.
    bytes32 internal constant CLAIMABLE_FUNDING_AMOUNT_KEY = keccak256(abi.encode("CLAIMABLE_FUNDING_AMOUNT"));
    bytes32 internal constant CLAIMABLE_COLLATERAL_AMOUNT_KEY = keccak256(abi.encode("CLAIMABLE_COLLATERAL_AMOUNT"));
    bytes32 internal constant CLAIMABLE_COLLATERAL_FACTOR_KEY = keccak256(abi.encode("CLAIMABLE_COLLATERAL_FACTOR"));
    bytes32 internal constant CLAIMABLE_COLLATERAL_REDUCTION_FACTOR_KEY =
        keccak256(abi.encode("CLAIMABLE_COLLATERAL_REDUCTION_FACTOR"));
    bytes32 internal constant CLAIMED_COLLATERAL_AMOUNT_KEY = keccak256(abi.encode("CLAIMED_COLLATERAL_AMOUNT"));
    bytes32 internal constant CLAIMABLE_COLLATERAL_TIME_DIVISOR_KEY =
        keccak256(abi.encode("CLAIMABLE_COLLATERAL_TIME_DIVISOR"));
    bytes32 internal constant CLAIMABLE_COLLATERAL_DELAY_KEY = keccak256(abi.encode("CLAIMABLE_COLLATERAL_DELAY"));

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
        Bytes32Set trackedMarkets;
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

    /// @notice Adds `market` to the tracked-markets set.
    function addTrackedMarket(address market) internal {
        gmxCallbackData().trackedMarkets.add(_addressToBytes32(market));
    }

    /// @notice Removes `market` from the tracked-markets set.
    function removeTrackedMarket(address market) internal {
        gmxCallbackData().trackedMarkets.remove(_addressToBytes32(market));
    }

    /// @notice Returns true when `market` is in the tracked-markets set.
    function containsTrackedMarket(address market) internal view returns (bool) {
        return gmxCallbackData().trackedMarkets.contains(_addressToBytes32(market));
    }

    /// @notice Returns the number of tracked markets.
    function trackedMarketsCount() internal view returns (uint256) {
        return gmxCallbackData().trackedMarkets.length();
    }

    /// @notice Returns the tracked market at `index`.
    function trackedMarketAt(uint256 index) internal view returns (address) {
        return _bytes32ToAddress(gmxCallbackData().trackedMarkets.at(index));
    }

    /// @notice Removes a fully-claimed collateral key from the tracked set and metadata map.
    function removeClaimableCollateralKey(bytes32 key) internal {
        GmxCallbackSlot storage s = gmxCallbackData();
        if (s.claimableCollateralKeys.contains(key)) {
            s.claimableCollateralKeys.remove(key);
            delete s.claimableCollateralInfo[key];
        }
    }

    function _addressToBytes32(address value) private pure returns (bytes32) {
        return bytes32(uint256(uint160(value)));
    }

    function _bytes32ToAddress(bytes32 value) private pure returns (address) {
        return address(uint160(uint256(value)));
    }
}
