// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import "../immutable/MixinImmutables.sol";
import "../immutable/MixinStorage.sol";
import "../../interfaces/IERC20.sol";

abstract contract MixinInitializer is MixinImmutables, MixinStorage {
    modifier onlyUninitialized() {
        // pool proxy is always initialized in the constructor, therefore
        // empty extcodesize means the pool has not been initialized
        address self = address(this);
        uint256 size;
        assembly {
            size := extcodesize(self)
        }
        require(size == 0, "POOL_ALREADY_INITIALIZED_ERROR");
        _;
    }

    /// @inheritdoc IRigoblockV3PoolInitializer
    function initializePool(
        string calldata poolName,
        string calldata poolSymbol,
        address baseToken,
        address owner
    ) external override onlyUninitialized {
        uint8 tokenDecimals = 18;

        if (baseToken != address(0)) {
            tokenDecimals = IERC20(baseToken).decimals();
        }

        // a pool with small decimals could easily underflow.
        assert(tokenDecimals >= 6);

        poolWrapper().pool = Pool({
            name: poolName,
            symbol: bytes8(bytes(poolSymbol)),
            decimals: tokenDecimals,
            owner: owner,
            unlocked: true,
            baseToken: baseToken
        });

        emit PoolInitialized(msg.sender, owner, baseToken, poolName, poolSymbol);
    }
}
