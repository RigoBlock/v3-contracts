// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

/// @title Rigoblock V3 Pool Fallback Interface - Interface of the fallback method.
/// @author Gabriele Rigo - <gab@rigoblock.com>
interface IRigoblockV3PoolFallback {
    /// @dev Delegate calls to extension.
    /// @notice Restricting delegatecall to owner effectively locks direct calls.
    fallback() external payable;

    /// @dev Allows transfers to pool.
    /// @notice Prevents accidental transfer to implementation contract.
    receive() external payable;
}
