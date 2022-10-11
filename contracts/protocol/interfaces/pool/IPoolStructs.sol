// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2022 Rigo Intl.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.

*/

pragma solidity >=0.8.0 <0.9.0;

/// @title IPoolStructs - Pool struct variables.
/// @author Gabriele Rigo - <gab@rigoblock.com>
interface IPoolStructs {
    /// @notice Pool initialization parameters.
    /// @dev This struct is not visible externally and only used at pool creation.
    /// @param name String of the pool name (max 32 characters).
    /// @param symbol Bytes8 of the pool symbol (from 3 to 5 characters).
    /// @param decimals Uint8 decimals.
    /// @param owner Address of the pool operator.
    /// @param unlocked Boolean the pool is locked for reentrancy check.
    /// @param baseToken Address of the base token of the pool (0 for base currency).
    struct Pool {
        string name;
        bytes8 symbol;
        uint8 decimals;
        address owner;
        bool unlocked;
        address baseToken;
    }

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

    /// @notice Pool tokens.
    /// @param unitaryValue A token's unitary value in base token.
    /// @param totalSupply Number of total issued pool tokens.
    struct PoolTokens {
        uint256 unitaryValue;
        uint256 totalSupply;
    }

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

    /// @notice Pool holder account.
    /// @param userBalance Number of tokens held by user.
    /// @param activation Time when tokens become active.
    struct UserAccount {
        uint208 userBalance;
        uint48 activation;
    }

    // mappings slot kept empty and i.e. userBalance stored at location keccak256(address(msg.sender) . uint256(2))
    // activation stored at locantion keccak256(address(msg.sender) . uint256(2)) + 1
    // slot(0)
    //mapping(address => IPoolStructs.UserAccount) internal userAccounts;
    struct Accounts {
        mapping(address => UserAccount) userAccounts;
    }
}
