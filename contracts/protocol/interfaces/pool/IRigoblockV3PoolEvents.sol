// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

/// @title Rigoblock V3 Pool Events - Declares events of the pool contract.
/// @author Gabriele Rigo - <gab@rigoblock.com>
interface IRigoblockV3PoolEvents {
    /// @dev Logs initialization of a new pool.
    /// @notice Emitted after new pool created.
    /// @param group Address of the factory.
    /// @param owner Address of the owner.
    /// @param baseToken Address of the base token.
    /// @param name String name of the pool.
    /// @param symbol String symbol of the pool.
    event PoolInitialized(
        address indexed group,
        address indexed owner,
        address indexed baseToken,
        string name,
        string symbol
    );

    /// @dev Logs update of NAV.
    /// @notice Emitted when pool operator updates NAV.
    /// @param poolOperator Address of the pool owner.
    /// @param poolAddress Address of the pool.
    /// @param unitaryValue Value of 1 token in wei units.
    event NewNav(address indexed poolOperator, address indexed poolAddress, uint256 unitaryValue);

    /// @dev Logs update of mint fee.
    /// @notice Emitted when pool operator sets new fee.
    /// @param poolAddress Address of the pool.
    /// @param who Address that is sending the transaction.
    /// @param transactionFee Number of the new fee in wei.
    event NewFee(address indexed poolAddress, address indexed who, uint256 transactionFee);

    /// @dev Logs a change in the fees receiver.
    /// @notice Emitted when pool operator updates collector address.
    /// @param poolAddress Address of the pool.
    /// @param who Address that is sending the transaction.
    /// @param feeCollector Address of the new fee collector.
    event NewCollector(address indexed poolAddress, address indexed who, address feeCollector);

    /// @dev Logs a change in the minimum period.
    /// @notice Emitted when pool operator updates minimum holding period.
    /// @param poolAddress Address of the pool.
    /// @param minimumPeriod Number of seconds.
    event MinimumPeriodChanged(address indexed poolAddress, uint32 minimumPeriod);

    /// @dev Logs a change in the spread.
    /// @notice Emitted when pool operator updates the mint/burn spread.
    /// @param poolAddress Address of the pool.
    /// @param spread Number of the spread in basis points.
    event SpreadChanged(address indexed poolAddress, uint256 spread);

    /// @dev Logs a change in the kyc provider.
    /// @notice Emitted when pool operator sets a kyc provider.
    /// @param poolAddress Address of the pool.
    /// @param kycProvider Address of the kyc provider.
    event KycProviderSet(address indexed poolAddress, address indexed kycProvider);
}
