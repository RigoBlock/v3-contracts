// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import "../actions/MixinOwnerActions.sol";

abstract contract MixinPoolState is MixinOwnerActions {
    /*
     * EXTERNAL VIEW METHODS
     */
    /// @dev Returns how many pool tokens a user holds.
    /// @param _who Address of the target account.
    /// @return Number of pool.
    function balanceOf(address _who) external view override returns (uint256) {
        return userAccounts[_who].userBalance;
    }

    // TODO: update view methods after pool storage restructuring
    /// @inheritdoc IRigoblockV3PoolState
    function getAdminData()
        external
        view
        override
        returns (
            address poolOwner,
            address feeCollector,
            uint16 transactionFee,
            uint48 minPeriod
        )
    {
        return (pool.owner, _getFeeCollector(), poolParams.transactionFee, _getMinPeriod());
    }

    /// @inheritdoc IRigoblockV3PoolState
    function getData()
        public
        view
        override
        returns (
            string memory poolName,
            string memory poolSymbol,
            address baseToken,
            uint256 unitaryValue,
            uint16 spread
        )
    {
        // TODO: check if we should reorg return data for client efficiency
        return (
            poolName = name(),
            poolSymbol = symbol(),
            baseToken = pool.baseToken,
            _getUnitaryValue(),
            _getSpread()
        );
    }

    /// @inheritdoc IRigoblockV3PoolState
    function getKycProvider() external view override returns (address kycProviderAddress) {
        return kycProviderAddress = poolParams.kycProvider;
    }

    function getPoolStorage()
        external
        view
        returns (
            ReturnedPool memory poolInitParams,
            PoolParams memory poolVariables,
            PoolTokens memory poolTokensInfo
        )
    {
        return(
            getPool(),
            getPoolParams(),
            getPoolTokens()
        );
    }

    function getUserAccount(address _who) external view returns (UserAccount memory) {
        return userAccounts[_who];
    }

    /// @inheritdoc IRigoblockV3PoolState
    function owner() external view override returns (address) {
        return pool.owner;
    }

    /// @inheritdoc IRigoblockV3PoolState
    function totalSupply() public view override returns (uint256) {
        return poolTokens.totalSupply;
    }

    /*
     * PUBLIC VIEW METHODS
     */
    /// @dev Decimals are initialized at proxy creation only if base token not null.
    /// @return Number of decimals.
    /// @notice We use this method to save gas on base currency pools.
    // TODO: we initialize decimals now
    function decimals() public view override returns (uint8) {
        return pool.decimals != 0 ? pool.decimals : _coinbaseDecimals;
    }

    // we return symbol as string
    struct ReturnedPool {
        string name;
        string symbol;
        uint8 decimals;
        address owner;
        bool unlocked;
        address baseToken;
    }


    function getPool() public view returns (ReturnedPool memory poolReturnedInitParams) {
        poolReturnedInitParams.name = pool.name;
        poolReturnedInitParams.symbol = symbol();
        poolReturnedInitParams.decimals = pool.decimals;
        poolReturnedInitParams.owner = pool.owner;
        poolReturnedInitParams.unlocked = pool.unlocked;
        poolReturnedInitParams.baseToken = pool.baseToken;
    }

    function getPoolParams() public view returns (PoolParams memory poolReturnedParams) {
        poolReturnedParams = poolParams;
        poolReturnedParams.minPeriod = _getMinPeriod();
        poolReturnedParams.spread = _getSpread();
    }

    function getPoolTokens() public view returns (PoolTokens memory poolReturnedTokens) {
        poolReturnedTokens = poolTokens;
        poolReturnedTokens.unitaryValue = _getUnitaryValue();
    }

    /// @inheritdoc IRigoblockV3PoolImmutable
    function name() public view override returns (string memory) {
        return pool.name;
    }

    /// @inheritdoc IRigoblockV3PoolImmutable
    function symbol() public view override returns (string memory) {
        bytes8 _symbol = pool.symbol;
        uint8 i = 0;
        while(i < 8 && _symbol[i] != 0) {
            i++;
        }
        bytes memory bytesArray = new bytes(i);
        for (i = 0; i < 8 && _symbol[i] != 0; i++) {
            bytesArray[i] = _symbol[i];
        }
        return string(bytesArray);
    }

    /*
     * INTERNAL VIEW METHODS
     */
    function _getFeeCollector() internal view override returns (address) {
        return poolParams.feeCollector != address(0) ? poolParams.feeCollector : pool.owner;
    }

    function _getMinPeriod() internal view override returns (uint48) {
        return poolParams.minPeriod != 0 ? poolParams.minPeriod : MIN_LOCKUP;
    }

    function _getSpread() internal view override returns (uint16) {
        return poolParams.spread != 0 ? poolParams.spread : INITIAL_SPREAD;
    }

    // TODO: we can add return here, so we reduce initialize method
    function _getUnitaryValue() internal view override returns (uint256) {
        return poolTokens.unitaryValue != 0 ? poolTokens.unitaryValue : _coinbaseUnitaryValue;
    }
}
