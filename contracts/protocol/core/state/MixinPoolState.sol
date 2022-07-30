// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import "../immutable/MixinConstants.sol";
import "../immutable/MixinImmutables.sol";
import "../immutable/MixinStorage.sol";

abstract contract MixinPoolState is MixinConstants, MixinImmutables, MixinStorage {
    /*
     * EXTERNAL VIEW METHODS
     */
    /// @dev Returns how many pool tokens a user holds.
    /// @param _who Address of the target account.
    /// @return Number of pool.
    function balanceOf(address _who) external view override returns (uint256) {
        return userAccount[_who].balance;
    }

    /// @inheritdoc IRigoblockV3PoolState
    function getData()
        external
        view
        override
        returns (
            string memory poolName,
            string memory poolSymbol,
            address baseToken,
            uint256 unitaryValue,
            uint256 spread
        )
    {
        // TODO: check if we should reorg return data for client efficiency
        return (
            poolName = name(),
            poolSymbol = symbol(),
            baseToken = admin.baseToken,
            _getUnitaryValue(),
            _getSpread()
        );
    }

    /// @inheritdoc IRigoblockV3PoolState
    function getAdminData()
        external
        view
        override
        returns (
            // TODO: check if should name returned poolOwner
            address, //owner
            address feeCollector,
            uint256 transactionFee,
            uint32 minPeriod
        )
    {
        return (
            owner,
            // TODO: must return internal method
            admin.feeCollector,
            poolData.transactionFee,
            _getMinPeriod()
        );
    }

    /// @inheritdoc IRigoblockV3PoolState
    function getKycProvider() external view override returns (address kycProviderAddress) {
        return kycProviderAddress = admin.kycProvider;
    }

    /// @inheritdoc IRigoblockV3PoolState
    function totalSupply() external view override returns (uint256) {
        return poolData.totalSupply;
    }

    /*
     * PUBLIC VIEW METHODS
     */
    /// @dev Decimals are initialized at proxy creation only if base token not null.
    /// @return Number of decimals.
    /// @notice We use this method to save gas on base currency pools.
    function decimals() public view virtual override returns (uint8) {
        return poolData.decimals != 0 ? poolData.decimals : _coinbaseDecimals;
    }

    /// @inheritdoc IRigoblockV3PoolImmutable
    function name() public view override returns (string memory) {
        return poolData.name;
    }

    /// @inheritdoc IRigoblockV3PoolImmutable
    function symbol() public view override returns (string memory) {
        return poolData.symbol;
    }

    /*
     * INTERNAL VIEW METHODS
     */
    function _getMinPeriod() internal view virtual returns (uint32);

    function _getSpread() internal view virtual returns (uint256);

    function _getUnitaryValue() internal view virtual returns (uint256);
}
