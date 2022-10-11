// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import "./IPoolStructs.sol";

/// @title Rigoblock V3 Pool State - Returns the pool view methods.
/// @author Gabriele Rigo - <gab@rigoblock.com>
interface IRigoblockV3PoolState {
    /// @notice Returns the struct containing pool initialization parameters.
    /// @dev Symbol is stored as bytes8 but returned as string in the returned struct, unlocked is omitted as alwasy true.
    /// @return ReturnedPool struct: string name, string symbol, uint8 decimals, owner, baseToken.
    function getPool() external view returns (IPoolStructs.ReturnedPool memory);

    /// @notice Returns the struct compaining pool parameters.
    /// @return PoolParams struct: uint48 minPeriod, uint16 spread, uint16 transactionFee, feeCollector, kycProvider.
    function getPoolParams() external view returns (IPoolStructs.PoolParams memory);

    /// @notice Returns the struct containing pool tokens info.
    /// @return PoolTokens struct: uint256 unitaryValue, uint256 totalSupply.
    function getPoolTokens() external view returns (IPoolStructs.PoolTokens memory);

    /// @notice Returns the aggregate pool generic storage.
    /// @return poolInitParams The pool's initialization parameters.
    /// @return poolVariables The pool's variables.
    /// @return poolTokensInfo The pool's tokens info.
    function getPoolStorage()
        external
        view
        returns (
            IPoolStructs.ReturnedPool memory poolInitParams,
            IPoolStructs.PoolParams memory poolVariables,
            IPoolStructs.PoolTokens memory poolTokensInfo
        );

    /// @notice Returns a pool holder's account struct.
    /// @return UserAccount struct: uint204 userBalance, uint48 activation.
    function getUserAccount(address _who) external view returns (IPoolStructs.UserAccount memory);

    /// @notice Returns a string of the pool name.
    function name() external view returns (string memory);

    /// @notice Returns the address of the owner.
    /// @return Address of the owner.
    function owner() external view returns (address);

    /// @notice Returns a string of the pool symbol.
    function symbol() external view returns (string memory);

    /// @notice Returns the total amount of issued tokens for this pool.
    /// @return Number of tokens.
    function totalSupply() external view returns (uint256);
}
