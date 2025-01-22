// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import "../immutable/MixinImmutables.sol";
import "../immutable/MixinStorage.sol";
import "../../interfaces/IERC20.sol";
import "../../interfaces/IRigoblockPoolProxyFactory.sol";
import {IEApps} from "../../extensions/adapters/interfaces/IEApps.sol";
import {IEOracle} from "../../extensions/adapters/interfaces/IEOracle.sol";

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
    /// @dev Cannot be reentered as no non-view call is performed to external contracts.
    function initializePool() external override onlyUninitialized {
        IRigoblockPoolProxyFactory.Parameters memory initParams = IRigoblockPoolProxyFactory(msg.sender).parameters();
        uint8 tokenDecimals;

        if (initParams.baseToken != address(0)) {
            // the following condition will never be true if base token is not a token
            // TODO: verify
            try IEOracle(address(this)).hasPriceFeed(initParams.baseToken) {
                // revert in case the ERC20 read call fails silently
                try IERC20(initParams.baseToken).decimals() returns (uint8 decimals) {
                    tokenDecimals = decimals;

                    // a pool with small decimals could easily underflow.
                    assert(tokenDecimals >= 6);
                } catch {
                    revert BaseTokenDecimals();
                }
            } catch {
                revert BaseTokenPriceFeedNotFound();
            }
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
