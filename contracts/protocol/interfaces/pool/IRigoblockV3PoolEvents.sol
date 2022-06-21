// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0;

interface IRigoblockV3PoolEvents {
    /// @dev Logs creation of a new pool.
    /// @notice Emitted when new pool created.
    /// @param drago Address of the new pool.
    /// @param group Address of the factory.
    /// @param owner Address of the owner.
    /// @param dragoId Id of the pool.
    /// @param name String name of the pool.
    /// @param symbol String symbol of the pool.
    event DragoCreated(
        address drago,
        address indexed group,
        address indexed owner,
        uint256 dragoId,
        string name,
        string symbol
    );

    /// @dev Logs purchase of pool tokens.
    /// @notice Emitted when user buys into pool.
    /// @param drago Address of the pool.
    /// @param from Address that is sending the transaction.
    /// @param to Address that receives the tokens.
    /// @param amount Number of units created.
    /// @param revenue Value in base unit.
    /// @param name String name of the pool.
    /// @param symbol String symbol of the pool.
    event Mint(
        address indexed drago,
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 revenue,
        bytes name,
        bytes symbol
    );

    /// @dev Logs sale of pool tokens.
    /// @notice Emitted when user sells pool tokens.
    /// @param drago Address of the pool.
    /// @param from Address that is sending the transaction.
    /// @param amount Number of units burnt.
    /// @param revenue Value in base unit.
    /// @param name String name of the pool.
    /// @param symbol String symbol of the pool.
    event Burn(
        address indexed drago,
        address indexed from,
        uint256 amount,
        uint256 revenue,
        bytes name,
        bytes symbol
    );

    /// @dev Logs update of ratio.
    /// @notice Emitted when pool operator sets ratio.
    /// @param drago Address of the pool.
    /// @param from Address that is sending the transaction.
    /// @param newRatio Value of the new ration.
    event NewRatio(
        address indexed drago,
        address indexed from,
        uint256 newRatio
    );

    /// @dev Logs update of NAV.
    /// @notice Emitted when pool operator updates NAV.
    /// @param drago Address of the pool.
    /// @param from Address that is sending the transaction.
    /// @param sellPrice Value of the bid price.
    /// @param buyPrice Value of the offer price.
    event NewNav(
        address indexed drago,
        address indexed from,
        uint256 sellPrice,
        uint256 buyPrice
    );

    /// @dev Logs update of mint fee.
    /// @notice Emitted when pool operator sets new fee.
    /// @param drago Address of the pool.
    /// @param who Address that is sending the transaction.
    /// @param transactionFee Number of the new fee in wei.
    event NewFee(
        address indexed drago,
        address indexed who,
        uint256 transactionFee
    );

    /// @dev Logs a change in the fees receiver.
    /// @notice Emitted when pool operator updates collector address.
    /// @param drago Address of the pool.
    /// @param who Address that is sending the transaction.
    /// @param feeCollector Address of the new fee collector.
    event NewCollector(
        address indexed drago,
        address indexed who,
        address feeCollector
    );

    /// @dev Logs update of drago DAO.
    /// @notice Emitted when pool factory updates Dao address.
    /// @param drago Address of the pool.
    /// @param from Address that is sending the transaction.
    /// @param dragoDao Address of the Dao.
    event DragoDaoSet(
        address indexed drago,
        address indexed from,
        address dragoDao
    );
}