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
    function _initializePool(
        string calldata _poolName,
        string calldata _poolSymbol,
        address _baseToken,
        address _owner
    ) external override onlyUninitialized {
        uint8 tokenDecimals = 18;

        if (_baseToken != address(0)) {
            tokenDecimals = IERC20(_baseToken).decimals();
        }

        // a pool with small decimals could easily underflow.
        assert(tokenDecimals >= 6);

        poolWrapper().pool = Pool({
            name: _poolName,
            symbol: bytes8(bytes(_poolSymbol)),
            decimals: tokenDecimals,
            owner: _owner,
            unlocked: true,
            baseToken: _baseToken
        });

        emit PoolInitialized(msg.sender, _owner, _baseToken, _poolName, _poolSymbol);
    }
}
