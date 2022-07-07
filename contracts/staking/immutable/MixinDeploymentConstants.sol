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

pragma solidity >=0.5.9 <0.8.0;
pragma experimental ABIEncoderV2;

import "../../utils/0xUtils/IEtherToken.sol";
import { IGrgVault as GrgVault } from "../interfaces/IGrgVault.sol";
import "../interfaces/IStaking.sol";
import  { IPoolRegistry as PoolRegistry } from "../../protocol/interfaces/IPoolRegistry.sol";
import { IRigoToken as RigoToken } from "../../rigoToken/interfaces/IRigoToken.sol";


// solhint-disable separate-by-one-line-in-contract
abstract contract MixinDeploymentConstants is IStaking {

    // TODO: since we return these values, we could send input at initialization instead of having hardcoded addresses.
    // TODO: we could store instance instead of address for gas savings at tx.
    // Mainnet GrgVault address
    address constant private GRG_VAULT_ADDRESS = address(0xfbd2588b170Ff776eBb1aBbB58C0fbE3ffFe1931);

    // Ropsten GrgVault address
    // address constant private GRG_VAULT_ADDRESS = address(0x7fc6a07e4b7b859c80F949A2A7812e00C64b4264);
    
    // Mainnet PoolRegistry address
    // TODO: update registry with new deployed contract
    address constant private POOL_REGISTRY_ADDRESS = address(0xdE6445484a8dcD9bf35fC95eb4E3990Cc358822e);
    
    // Ropsten PoolRegistry address
    // address constant private POOL_REGISTRY_ADDRESS = address(0x4e868D1dDF940316964eA7673E21bE6CBED8b30B);
    
    // Mainnet GRG Address
    address constant private GRG_ADDRESS = address(0x4FbB350052Bca5417566f188eB2EBCE5b19BC964);

    // Ropsten GRG Address
    // address constant private GRG_ADDRESS = address(0x6FA8590920c5966713b1a86916f7b0419411e474);

    /// @dev An overridable way to access the deployed grgVault.
    ///      Must be view to allow overrides to access state.
    /// @return grgVault The grgVault contract.
    function getGrgVault()
        public
        view
        virtual
        override
        returns (GrgVault)
    {
        return GrgVault(GRG_VAULT_ADDRESS);
    }
    
    /// @dev An overridable way to access the deployed rigoblock pool registry.
    ///      Must be view to allow overrides to access state.
    /// @return poolRegistry The pool registry contract.
    function getPoolRegistry()
        public
        view
        virtual
        override
        returns (PoolRegistry)
    {
        return PoolRegistry(POOL_REGISTRY_ADDRESS);
    }
    
    /// @dev An overridable way to access the deployed GRG contract.
    ///      Must be view to allow overrides to access state.
    /// @return grgContract The GRG contract instance.
    function getGrgContract()
        public
        view
        virtual
        override
        returns (RigoToken)
    {
        return RigoToken(GRG_ADDRESS);
    }
}
