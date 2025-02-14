// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import {MixinImmutables} from "../immutable/MixinImmutables.sol";
import {MixinStorage} from "../immutable/MixinStorage.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {IRigoblockPoolProxyFactory} from "../../interfaces/IRigoblockPoolProxyFactory.sol";
import {ISmartPoolInitializer} from "../../interfaces/pool/ISmartPoolInitializer.sol";
import {Pool} from "../../libraries/EnumerableSet.sol";

abstract contract MixinInitializer is MixinImmutables, MixinStorage {
    error BaseTokenDecimals();
    error PoolAlreadyInitialized();

    modifier onlyUninitialized() {
        // pool proxy is always initialized in the constructor, therefore
        // empty code means the pool has not been initialized
        require(address(this).code.length == 0, PoolAlreadyInitialized());
        _;
    }

    /// @inheritdoc ISmartPoolInitializer
    /// @dev Cannot be reentered as no non-view call is performed to external contracts. Unlocked is kept for backwards compatibility.
    function initializePool() external override onlyUninitialized {
        IRigoblockPoolProxyFactory.Parameters memory initParams = IRigoblockPoolProxyFactory(msg.sender).parameters();

        Pool memory pool = Pool({
            name: initParams.name,
            symbol: initParams.symbol,
            decimals: 18,
            owner: initParams.owner,
            unlocked: true,
            baseToken: initParams.baseToken
        });

        // overwrite token decimals
        if (initParams.baseToken != _ZERO_ADDRESS) {
            assert(initParams.baseToken.code.length > 0);
            try IERC20(initParams.baseToken).decimals() returns (uint8 decimals) {
                // a pool with small decimals could easily underflow.
                assert(decimals >= 6);

                // update with the base token's decimals
                pool.decimals = decimals;
            } catch {
                revert BaseTokenDecimals();
            }
        }

        // initialize storage
        poolWrapper().pool = pool;
        emit PoolInitialized(msg.sender, initParams.owner, initParams.baseToken, initParams.name, initParams.symbol);
    }
}
