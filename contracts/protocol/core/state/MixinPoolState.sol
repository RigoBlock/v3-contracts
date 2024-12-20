// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import "../actions/MixinOwnerActions.sol";

abstract contract MixinPoolState is MixinOwnerActions {
    /*
     * EXTERNAL VIEW METHODS
     */
    /// @dev Returns how many pool tokens a user holds.
    /// @param who Address of the target account.
    /// @return Number of pool.
    function balanceOf(address who) external view override returns (uint256) {
        return accounts().userAccounts[who].userBalance;
    }

    /// @inheritdoc IRigoblockV3PoolState
    function getPoolStorage()
        external
        view
        override
        returns (
            ReturnedPool memory poolInitParams,
            PoolParams memory poolVariables,
            PoolTokens memory poolTokensInfo
        )
    {
        return (getPool(), getPoolParams(), getPoolTokens());
    }

    // TODO: check if should return tracked applicationsm or if should return in separate method
    /// @inheritdoc IRigoblockV3PoolState
    function getPortfolioTokens() external view override returns (PortfolioTokens memory tokens) {
        components.activeTokens = getTrackedTokens();
        components.baseToken = getPool().baseToken;
    }

    /// @inheritdoc IRigoblockV3PoolState
    function getTrackedTokens() public view override returns (address[] memory) {
        return tokenRegistry().addressList;
    }

    /// @inheritdoc IRigoblockV3PoolState
    function getTrackedApplications() public view override returns (address[] memory) {
        return applicationRegistry().packedApplications;
    }

    function getUserAccount(address who) external view override returns (UserAccount memory) {
        return accounts().userAccounts[who];
    }

    /// @inheritdoc IRigoblockV3PoolState
    function owner() external view override returns (address) {
        return pool().owner;
    }

    /*
     * PUBLIC VIEW METHODS
     */
    /// @notice Decimals are initialized at proxy creation.
    /// @return Number of decimals.
    function decimals() public view override returns (uint8) {
        return pool().decimals;
    }

    /// @inheritdoc IRigoblockV3PoolState
    function getPool() public view override returns (ReturnedPool memory) {
        Pool memory pool = pool();
        // we return symbol as string, omit unlocked as always true
        return
            ReturnedPool({
                name: pool.name,
                symbol: symbol(),
                decimals: pool.decimals,
                owner: pool.owner,
                baseToken: pool.baseToken
            });
    }

    /// @inheritdoc IRigoblockV3PoolState
    function getPoolParams() public view override returns (PoolParams memory) {
        return
            PoolParams({
                minPeriod: _getMinPeriod(),
                spread: _getSpread(),
                transactionFee: poolParams().transactionFee,
                feeCollector: _getFeeCollector(),
                kycProvider: poolParams().kycProvider
            });
    }

    /// @inheritdoc IRigoblockV3PoolState
    function getPoolTokens() public view override returns (PoolTokens memory) {
        return PoolTokens({unitaryValue: _getUnitaryValue(), totalSupply: poolTokens().totalSupply});
    }

    /// @inheritdoc IRigoblockV3PoolState
    function name() public view override returns (string memory) {
        return pool().name;
    }

    /// @inheritdoc IRigoblockV3PoolState
    function symbol() public view override returns (string memory) {
        bytes8 _symbol = pool().symbol;
        uint8 i = 0;
        while (i < 8 && _symbol[i] != 0) {
            i++;
        }
        bytes memory bytesArray = new bytes(i);
        for (i = 0; i < 8 && _symbol[i] != 0; i++) {
            bytesArray[i] = _symbol[i];
        }
        return string(bytesArray);
    }

    /// @inheritdoc IRigoblockV3PoolState
    function totalSupply() public view override returns (uint256) {
        return poolTokens().totalSupply;
    }

    /*
     * INTERNAL VIEW METHODS
     */
    function _getFeeCollector() internal view override returns (address) {
        address feeCollector = poolParams().feeCollector;
        return feeCollector != address(0) ? feeCollector : pool().owner;
    }

    function _getMinPeriod() internal view override returns (uint48) {
        uint48 minPeriod = poolParams().minPeriod;
        return minPeriod != 0 ? minPeriod : _MIN_LOCKUP;
    }

    // TODO: spread should be 100% -> 0% from time0 to time 1 month
    function _getSpread() internal view override returns (uint16) {
        uint16 spread = poolParams().spread;
        return spread != 0 ? spread : _INITIAL_SPREAD;
    }

    // TODO: assert not possible to inflate total supply to manipulate pool price.
    function _getUnitaryValue(uint256 poolValue) internal view override returns (uint256) {
        uint256 totalSupply = totalSupply();
        uint256 storedValue = poolTokens().unitaryValue;

        // a previously minted pool cannot have storedValue = 0 
        if (storedValue != 0) {
            // default scenario
            if (poolValue != 0 && totalSupply != 0) {
                return poolValue / totalSupply;
            // fallback to stored value when value would be null or infinite
            // TODO: verify why we did else if (poolValue == 0 || totalSupply == 0)
            } else {
                return storedValue;
            }
        // return 1 in base token units at first mint
        } else {
            return 10**pool().decimals;
        }
    }
}
