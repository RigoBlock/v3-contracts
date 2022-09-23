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
        poolData.name = _poolName;
        poolData.symbol = _poolSymbol;
        owner = _owner;

        // we do not initialize unless values different from default ones
        // DANGER! Careful with new releases as default values must be returned unless poolData overwritten
        if (_baseToken != address(0)) {
            admin.baseToken = _baseToken;
            uint8 tokenDecimals = IERC20(_baseToken).decimals();
            if (tokenDecimals != _coinbaseDecimals) {
                poolData.decimals = tokenDecimals;
                poolData.unitaryValue = 1 * 10**tokenDecimals; // initial value is 1
            }
        }

        emit PoolInitialized(msg.sender, _owner, _baseToken, _poolName, _poolSymbol);
    }
}
