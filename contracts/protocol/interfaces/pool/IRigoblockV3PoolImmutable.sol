// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

/// @title Rigoblock V3 Pool Immutable - Interface of the pool storage.
/// @author Gabriele Rigo - <gab@rigoblock.com>
interface IRigoblockV3PoolImmutable {
    /// @notice Returns a string of the pool version.
    /// @return String of the pool implementation version.
    function VERSION() external view returns (string memory);

    /// @notice Returns the address of the authority contract.
    /// @return Address of the authority contract.
    function authority() external view returns (address);

    /// @notice Returns the WETH9 contract.
    /// @dev Used to convert WETH balances to ETH without executing an oracle call.
    /// @return Address of the WETH9 contract.
    function wrappedNative() external view returns (address);
}
