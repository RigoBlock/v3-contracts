// SPDX-License-Identifier: Apache 2.0
/*

  Original work Copyright 2019 ZeroEx Intl.
  Modified work Copyright 2020 Rigo Intl.

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

pragma solidity >=0.5.9 <0.9.0;

import "../../utils/0xUtils/IEtherToken.sol";
import {IGrgVault as GrgVault} from "../interfaces/IGrgVault.sol";
import "../interfaces/IStaking.sol";
import {IPoolRegistry as PoolRegistry} from "../../protocol/interfaces/IPoolRegistry.sol";
import {IRigoToken as RigoToken} from "../../rigoToken/interfaces/IRigoToken.sol";

// solhint-disable separate-by-one-line-in-contract
abstract contract MixinDeploymentConstants is IStaking {
    constructor(
        address _grgVault,
        address _poolRegistry,
        address _rigoToken
    ) {
        GRG_VAULT_ADDRESS = _grgVault;
        POOL_REGISTRY_ADDRESS = _poolRegistry;
        GRG_ADDRESS = _rigoToken;
    }

    address private immutable GRG_VAULT_ADDRESS;
    address private immutable POOL_REGISTRY_ADDRESS;
    address private immutable GRG_ADDRESS;

    /// @dev An overridable way to access the deployed grgVault.
    ///      Must be view to allow overrides to access state.
    /// @return grgVault The grgVault contract.
    function getGrgVault() public view virtual override returns (GrgVault) {
        return GrgVault(GRG_VAULT_ADDRESS);
    }

    /// @dev An overridable way to access the deployed rigoblock pool registry.
    ///      Must be view to allow overrides to access state.
    /// @return poolRegistry The pool registry contract.
    function getPoolRegistry() public view virtual override returns (PoolRegistry) {
        return PoolRegistry(POOL_REGISTRY_ADDRESS);
    }

    /// @dev An overridable way to access the deployed GRG contract.
    ///      Must be view to allow overrides to access state.
    /// @return grgContract The GRG contract instance.
    function getGrgContract() public view virtual override returns (RigoToken) {
        return RigoToken(GRG_ADDRESS);
    }
}
