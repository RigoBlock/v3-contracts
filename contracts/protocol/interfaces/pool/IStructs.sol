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

/// @title IStructs - Pool struct variables.
/// @author Gabriele Rigo - <gab@rigoblock.com>
interface IStructs {
    /// @notice Pool holder data.
    /// @param balance Number of pool units held.
    /// @param activation Number of seconds until tokens can be burnt.
    /*struct Account {
        // can be scaled down to i.e. 160
        uint256 balance;
        // must be uint 48
        uint48 activation;
    }

    /// @notice Pool admin storage.
    /// @param feeCollector Address of the fee receiver.
    /// @param kycProvider Address of the kyc provider.
    /// @param baseToken Address of the base token (0 for base currency).
    struct Admin {
        address feeCollector;
        address kycProvider;
        address baseToken; // TODO: check where best to store
    }

    /// @notice Pool storage.
    /// @param name String of the pool name (max 32 characters).
    /// @param symbol String of the pool symbol (from 3 to 5 characters).
    /// @param unitaryValue Value of the pool in base currency.
    /// @param spread Number of spread in basis points (from 0 to +-10%).
    /// @param totalSupply Number of total issued pool tokens.
    /// @param transactionFee Number of transaction fee in basis points (from 0 to 1%).
    /// @param minPeriod Uint32 minimum holding period.
    /// @param decimals Uint8 decimals.
    struct PoolData {
        string name;
        string symbol;
        uint256 unitaryValue; // initially = 1 * 10**decimals
        // TODO: check if we get benefit as storing spread as uint32
        uint256 spread; // in basis points 1 = 0.01%
        uint256 totalSupply;
        uint256 transactionFee; // in basis points 1 = 0.01%
        uint32 minPeriod;
        uint8 decimals;
    }*/

    struct Pool {
        string name;
        bytes8 symbol;
        uint8 decimals;
        address owner;
        bool unlocked;
        address baseToken;
    }

    struct PoolParams {
        uint48 minPeriod;
        uint16 spread;
        uint16 transactionFee;
        address feeCollector;
        address kycProvider;
    }

    struct PoolTokens {
        uint256 unitaryValue;
        uint256 totalSupply;
    }

    struct UserAccount {
        uint208 userBalance;
        uint48 activation;
    }
}
