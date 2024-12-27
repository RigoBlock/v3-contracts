// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import "../state/MixinPoolValue.sol";
import "../../interfaces/pool/IRigoblockV3PoolState.sol";

abstract contract MixinPoolState is MixinPoolValue {
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

    /// @inheritdoc IRigoblockV3PoolState
    function getPortfolioTokens() public view override returns (PortfolioTokens memory tokens) {
        tokens.activeTokens = getActiveTokens();
        tokens.baseToken = getPool().baseToken;
    }

    // TODO: verify public is correct visibility
    /// @inheritdoc IRigoblockV3PoolState
    function getActiveTokens() public view override returns (address[] memory) {
        return activeTokensSet().addresses;
    }

    /// @inheritdoc IRigoblockV3PoolState
    /// @dev Grg staking and UniV3 positions will not be returned by default.
    function getActiveApplications() public view override returns (uint256 packedApplications) {
        // and return a uint that includes grg staking and uni v3 apps by default
        return applications().packedApplications;
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

    // TODO: verify, as we would return no value until pool is initialized, 
    /// @inheritdoc IRigoblockV3PoolState
    function getPoolTokens() public view override returns (PoolTokens memory) {
        return PoolTokens({unitaryValue: poolTokens().unitaryValue, totalSupply: poolTokens().totalSupply});
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
        return minPeriod != 0 ? minPeriod : _MAX_LOCKUP;
    }

    function _getSpread() internal view override returns (uint16) {
        uint16 spread = poolParams().spread;
        return spread != 0 ? spread : _MAX_SPREAD;
    }
}
