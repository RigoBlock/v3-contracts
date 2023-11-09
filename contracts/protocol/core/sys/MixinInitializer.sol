// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import "../immutable/MixinImmutables.sol";
import "../immutable/MixinStorage.sol";
import "../../interfaces/IERC20.sol";
import "../../interfaces/IRigoblockPoolProxyFactory.sol";

abstract contract MixinInitializer is MixinImmutables, MixinStorage {
    error BaseTokenDecimals();

    modifier onlyUninitialized() {
        // pool proxy is always initialized in the constructor, therefore
        // empty code means the pool has not been initialized
        require(address(this).code.length == 0, "POOL_ALREADY_INITIALIZED_ERROR");
        _;
    }

    /// @inheritdoc IRigoblockV3PoolInitializer
    function initializePool() external override onlyUninitialized {
        IRigoblockPoolProxyFactory.Parameters memory initParams = IRigoblockPoolProxyFactory(msg.sender).parameters();
        uint8 tokenDecimals;

        if (initParams.baseToken != address(0)) {
            assert(initParams.baseToken.code.length > 0);
            // revert in case the ERC20 read call fails silently
            try IERC20(initParams.baseToken).decimals() returns (uint8 decimals) {
                tokenDecimals = decimals;
            } catch {
                revert BaseTokenDecimals();
            }
            // a pool with small decimals could easily underflow.
            assert(tokenDecimals >= 6);
        } else {
            tokenDecimals = 18;
        }

        poolWrapper().pool = Pool({
            name: initParams.name,
            symbol: initParams.symbol,
            decimals: tokenDecimals,
            owner: initParams.owner,
            unlocked: true,
            baseToken: initParams.baseToken
        });

        emit PoolInitialized(msg.sender, initParams.owner, initParams.baseToken, initParams.name, initParams.symbol);
    }
}
