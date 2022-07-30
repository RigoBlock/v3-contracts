// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

/// @title Rigoblock V3 Pool Immutable - Interface of the pool storage.
/// @author Gabriele Rigo - <gab@rigoblock.com>
interface IRigoblockV3PoolImmutable {
    /*
     * IMMUTABLE STORAGE
     */
    function authority() external view returns (address);

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function VERSION() external view returns (string calldata);
}
