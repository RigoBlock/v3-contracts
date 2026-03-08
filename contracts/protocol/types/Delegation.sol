// SPDX-License-Identifier: Apache 2.0-or-later
pragma solidity ^0.8.0;

/// @notice Encodes a single delegation add/remove operation.
/// @param delegated Address to grant or revoke access for.
/// @param selector Function selector to grant or revoke access to.
/// @param isDelegated True to grant, false to revoke.
struct Delegation {
    address delegated;
    bytes4 selector;
    bool isDelegated;
}
