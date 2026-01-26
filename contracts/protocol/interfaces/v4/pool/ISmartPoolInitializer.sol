// SPDX-License-Identifier: Apache 2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

/// @title Rigoblock V3 Pool Initializer Interface - Allows initializing a pool contract.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
interface ISmartPoolInitializer {
    /// @notice Initializes to pool storage.
    /// @dev Pool can only be initialized at creation, meaning this method cannot be called directly to implementation.
    function initializePool() external;
}
