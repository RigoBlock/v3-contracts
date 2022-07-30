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
    struct Account {
        uint256 balance;
        uint32 activation;
    }

    struct Admin {
        address feeCollector;
        address kycProvider;
        address baseToken; // TODO: check where best to store
    }

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
    }
}
