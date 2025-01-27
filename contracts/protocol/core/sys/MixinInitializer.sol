// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import {MixinImmutables} from "../immutable/MixinImmutables.sol";
import {MixinStorage} from "../immutable/MixinStorage.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {IRigoblockPoolProxyFactory} from "../../interfaces/IRigoblockPoolProxyFactory.sol";
import {IRigoblockV3PoolInitializer} from "../../interfaces/pool/IRigoblockV3PoolInitializer.sol";
//import {IEApps} from "../../extensions/adapters/interfaces/IEApps.sol";
//import {IEOracle} from "../../extensions/adapters/interfaces/IEOracle.sol";

abstract contract MixinInitializer is MixinImmutables, MixinStorage {
    error BaseTokenDecimals();
    error BaseTokenPriceFeedNotFound();
    error PoolAlreadyInitialized();

    modifier onlyUninitialized() {
        // pool proxy is always initialized in the constructor, therefore
        // empty code means the pool has not been initialized
        require(address(this).code.length == 0, PoolAlreadyInitialized());
        _;
    }

    /// @inheritdoc IRigoblockV3PoolInitializer
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
            //assert(initParams.baseToken.code.length > 0);
            // the following condition will never be true if base token is not a token
            // TODO: verify
            // TODO: not sure we can make a fallback call before pool is successfully inizialized
            /*try IEOracle(address(this)).hasPriceFeed(initParams.baseToken) returns (bool hasFeed) {
                require(hasFeed, BaseTokenPriceFeedNotFound());
                // revert in case the ERC20 read call fails silently
                try IERC20(initParams.baseToken).decimals() returns (uint8 decimals) {
                    // a pool with small decimals could easily underflow.
                    assert(decimals >= 6);

                    // update with the base token's decimals
                    pool.decimals = decimals;
                } catch {
                    revert BaseTokenDecimals();
                }
            } catch {
                revert BaseTokenPriceFeedNotFound();
            }*/
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
