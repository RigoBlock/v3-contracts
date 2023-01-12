// SPDX-License-Identifier: Apache 2.0
/*

  Original work Copyright 2019 ZeroEx Intl.
  Modified work Copyright 2020-2022 Rigo Intl.

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

import {IGrgVault as GrgVault} from "../interfaces/IGrgVault.sol";
import "../interfaces/IStaking.sol";
import {IPoolRegistry as PoolRegistry} from "../../protocol/interfaces/IPoolRegistry.sol";
import {IRigoToken as RigoToken} from "../../rigoToken/interfaces/IRigoToken.sol";

// solhint-disable separate-by-one-line-in-contract
abstract contract MixinDeploymentConstants is IStaking {
    constructor(
        address grgVault,
        address poolRegistry,
        address rigoToken
    ) {
        _grgVault = grgVault;
        _poolRegistry = poolRegistry;
        _rigoToken = rigoToken;
        _implementation = address(this);
    }

    // we store this address in the bytecode to being able to prevent direct calls to the implementation.
    address internal immutable _implementation;

    address private immutable _rigoToken;
    address private immutable _grgVault;
    address private immutable _poolRegistry;

    /// @inheritdoc IStaking
    function getGrgContract() public view virtual override returns (RigoToken) {
        return RigoToken(_rigoToken);
    }

    /// @inheritdoc IStaking
    function getGrgVault() public view virtual override returns (GrgVault) {
        return GrgVault(_grgVault);
    }

    /// @inheritdoc IStaking
    function getPoolRegistry() public view virtual override returns (PoolRegistry) {
        return PoolRegistry(_poolRegistry);
    }

    /// @notice Changing inflation address will result in different staking proxy address.
    /// @dev Saving address in storage instead of immutable will require an input in the constructor
    ///   which will change the staking proxy address deployed with deterministic deployment.
    function _getInflation() internal view returns (address) {
        uint256 chainId;
        assembly {
            chainId := chainid()
        }

        if (chainId == 1 || chainId == 5 || chainId == 31337) {
            return getGrgContract().minter();
        } else {
            // hardcoded deterministic inflation L2 address
            return 0xbEc1CAbcd47599DED37315354a862D2E13b0bEed;
        }
    }
}
