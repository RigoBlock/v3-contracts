// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

/// @title GmxCallbackKeys
/// @notice GMX v2 DataStore keys used by the callback extension and NAV accounting.
/// @dev Kept separate from GmxLib so the callback-specific surface is reduced and
///  both the extension and the valuation library share one authoritative source.
library GmxCallbackKeys {
    bytes32 internal constant CLAIMABLE_FUNDING_AMOUNT_KEY = keccak256(abi.encode("CLAIMABLE_FUNDING_AMOUNT"));
    bytes32 internal constant CLAIMABLE_COLLATERAL_AMOUNT_KEY = keccak256(abi.encode("CLAIMABLE_COLLATERAL_AMOUNT"));
    bytes32 internal constant CLAIMABLE_COLLATERAL_FACTOR_KEY = keccak256(abi.encode("CLAIMABLE_COLLATERAL_FACTOR"));
    bytes32 internal constant CLAIMABLE_COLLATERAL_REDUCTION_FACTOR_KEY =
        keccak256(abi.encode("CLAIMABLE_COLLATERAL_REDUCTION_FACTOR"));
    bytes32 internal constant CLAIMED_COLLATERAL_AMOUNT_KEY = keccak256(abi.encode("CLAIMED_COLLATERAL_AMOUNT"));
    bytes32 internal constant CLAIMABLE_COLLATERAL_TIME_DIVISOR_KEY =
        keccak256(abi.encode("CLAIMABLE_COLLATERAL_TIME_DIVISOR"));
    bytes32 internal constant CLAIMABLE_COLLATERAL_DELAY_KEY = keccak256(abi.encode("CLAIMABLE_COLLATERAL_DELAY"));
}
