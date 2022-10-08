// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

/// @title Rigoblock V3 Pool State - Returns the pool view methods.
/// @author Gabriele Rigo - <gab@rigoblock.com>
interface IRigoblockV3PoolState {
    /// @notice Finds the administrative data of the pool.
    /// @return owner Address of the owner.
    /// @return feeCollector Address of the account where a user collects fees.
    /// @return transactionFee Value of the transaction fee in basis points.
    /// @return minPeriod Number of the minimum holding period for tokens.
    function getAdminData()
        external
        view
        returns (
            address owner,
            address feeCollector,
            uint16 transactionFee,
            uint48 minPeriod
        );

    /// @notice Finds details of this pool.
    /// @return poolName String name of this pool.
    /// @return poolSymbol String symbol of this pool.
    /// @return baseToken Address of base token (0 for coinbase).
    /// @return unitaryValue Value of the token in wei unit.
    /// @return spread Value of the spread from unitary value.
    function getData()
        external
        view
        returns (
            string memory poolName,
            string memory poolSymbol,
            address baseToken,
            uint256 unitaryValue,
            uint16 spread
        );

    /// @notice Returns the address of the pools whitelists.
    /// @return Address of the provider contract.
    function getKycProvider() external view returns (address);

    /// @notice Returns the address of the owner.
    /// @return Address of the owner.
    function owner() external view returns (address);

    /// @notice Returns the total amount of issued tokens for this pool.
    /// @return Number of tokens.
    function totalSupply() external view returns (uint256);
}
