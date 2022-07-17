// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0;

interface IRigoblockV3PoolEvents {
    /// @dev Logs initialization of a new pool.
    /// @notice Emitted after new pool created.
    /// @param group Address of the factory.
    /// @param owner Address of the owner.
    /// @param name String name of the pool.
    /// @param symbol String symbol of the pool.
    event PoolInitialized(
        address group,
        address indexed owner,
        string name,
        string symbol
    );

    /// @dev Logs purchase of pool tokens.
    /// @notice Emitted when user buys into pool.
    /// @param poolAddress Address of the pool.
    /// @param from Address that is sending the transaction.
    /// @param to Address that receives the tokens.
    /// @param amount Number of units created.
    /// @param revenue Value in base unit.
    event Mint(
        address indexed poolAddress,
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 revenue
    );

    /// @dev Logs sale of pool tokens.
    /// @notice Emitted when user sells pool tokens.
    /// @param poolAddress Address of the pool.
    /// @param from Address that is sending the transaction.
    /// @param amount Number of units burnt.
    /// @param revenue Value in base unit.
    /// @param name String name of the pool.
    /// @param symbol String symbol of the pool.
    event Burn(
        address indexed poolAddress,
        address indexed from,
        uint256 amount,
        uint256 revenue,
        bytes name,
        bytes symbol
    );

    /// @dev Logs update of ratio.
    /// @notice Emitted when pool operator sets ratio.
    /// @param poolAddress Address of the pool.
    /// @param from Address that is sending the transaction.
    /// @param newRatio Value of the new ration.
    event NewRatio(
        address indexed poolAddress,
        address indexed from,
        uint256 newRatio
    );

    /// @dev Logs update of NAV.
    /// @notice Emitted when pool operator updates NAV.
    /// @param poolOperator Address of the pool owner.
    /// @param poolAddress Address of the pool.
    /// @param unitaryValue Value of 1 token in wei units.
    event NewNav(
        address indexed poolOperator,
        address indexed poolAddress,
        uint256 unitaryValue
    );

    /// @dev Logs update of mint fee.
    /// @notice Emitted when pool operator sets new fee.
    /// @param poolAddress Address of the pool.
    /// @param who Address that is sending the transaction.
    /// @param transactionFee Number of the new fee in wei.
    event NewFee(
        address indexed poolAddress,
        address indexed who,
        uint256 transactionFee
    );

    /// @dev Logs a change in the fees receiver.
    /// @notice Emitted when pool operator updates collector address.
    /// @param poolAddress Address of the pool.
    /// @param who Address that is sending the transaction.
    /// @param feeCollector Address of the new fee collector.
    event NewCollector(
        address indexed poolAddress,
        address indexed who,
        address feeCollector
    );

    // TODO: fix method
    /// @dev Logs update of Rigoblock DAO.
    /// @notice Emitted when pool factory updates Dao address.
    /// @param poolAddress Address of the pool.
    /// @param from Address that is sending the transaction.
    /// @param dragoDao Address of the Dao.
    event DragoDaoSet(
        address indexed poolAddress,
        address indexed from,
        address dragoDao
    );
}
