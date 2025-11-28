// SPDX-License-Identifier: Apache 2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

/// @title Rigoblock V3 Pool State - Returns the pool view methods.
/// @author Gabriele Rigo - <gab@rigoblock.com>
interface ISmartPoolState {
    /// @notice Returns the list of accepted mint tokens.
    /// @return tokens Array of token addresses.
    function getAcceptedMintTokens() external view returns (address[] memory tokens);

    /// @notice Returns the active application flags.
    /// @return packedApplications Packed value of bitmap encoded active flags.
    function getActiveApplications() external view returns (uint256 packedApplications);

    struct ActiveTokens {
        address[] activeTokens;
        address baseToken;
    }

    /// @notice Returns the list of active tokens and the base token.
    /// @return tokens Tuple of active tokens list and base token.
    /// @dev Base token is always active.
    function getActiveTokens() external view returns (ActiveTokens memory tokens);

    /// @notice Returned pool initialization parameters.
    /// @dev Symbol is stored as bytes8 but returned as string to facilitating client view.
    /// @param name String of the pool name (max 32 characters).
    /// @param symbol String of the pool symbol (from 3 to 5 characters).
    /// @param decimals Uint8 decimals.
    /// @param owner Address of the pool operator.
    /// @param baseToken Address of the base token of the pool (0 for base currency).
    struct ReturnedPool {
        string name;
        string symbol;
        uint8 decimals;
        address owner;
        address baseToken;
    }

    /// @notice Returns the struct containing pool initialization parameters.
    /// @dev Symbol is stored as bytes8 but returned as string in the returned struct, unlocked is omitted as alwasy true.
    /// @return ReturnedPool struct.
    function getPool() external view returns (ReturnedPool memory);

    /// @notice Pool variables.
    /// @param minPeriod Minimum holding period in seconds.
    /// @param spread Value of spread in basis points (from 0 to +-10%).
    /// @param transactionFee Value of transaction fee in basis points (from 0 to 1%).
    /// @param feeCollector Address of the fee receiver.
    /// @param kycProvider Address of the kyc provider.
    struct PoolParams {
        uint48 minPeriod;
        uint16 spread;
        uint16 transactionFee;
        address feeCollector;
        address kycProvider;
    }

    /// @notice Returns the struct compaining pool parameters.
    /// @return PoolParams struct.
    function getPoolParams() external view returns (PoolParams memory);

    /// @notice Pool tokens.
    /// @param unitaryValue A token's unitary value in base token.
    /// @param totalSupply Number of total issued pool tokens.
    struct PoolTokens {
        uint256 unitaryValue;
        uint256 totalSupply;
    }

    /// @notice Returns the struct containing pool tokens info.
    /// @return PoolTokens struct.
    /// @notice Unitary value is the last stored unitary value.
    function getPoolTokens() external view returns (PoolTokens memory);

    /// @notice Returns the aggregate pool generic storage.
    /// @return poolInitParams The pool's initialization parameters.
    /// @return poolVariables The pool's variables.
    /// @return poolTokensInfo The pool's tokens info.
    function getPoolStorage()
        external
        view
        returns (ReturnedPool memory poolInitParams, PoolParams memory poolVariables, PoolTokens memory poolTokensInfo);

    /// @notice Pool holder account.
    /// @param userBalance Number of tokens held by user.
    /// @param activation Time when tokens become active.
    struct UserAccount {
        uint208 userBalance;
        uint48 activation;
    }

    /// @notice Returns a pool holder's account struct.
    /// @return UserAccount struct.
    function getUserAccount(address _who) external view returns (UserAccount memory);

    /// @notice Returns a string of the pool name.
    /// @dev Name maximum length 31 bytes.
    /// @return String of the name.
    function name() external view returns (string memory);

    /// @notice Returns the address of the owner.
    /// @return Address of the owner.
    function owner() external view returns (address);

    /// @notice Returns a string of the pool symbol.
    /// @return String of the symbol.
    function symbol() external view returns (string memory);

    /// @notice Returns the total amount of issued tokens for this pool.
    /// @return Number of total issued tokens.
    function totalSupply() external view returns (uint256);

    /// @param holder The address of the holder.
    /// @param operator The address of the operator.
    /// @return approved The approval status.
    function isOperator(address holder, address operator) external view returns (bool approved);
}
