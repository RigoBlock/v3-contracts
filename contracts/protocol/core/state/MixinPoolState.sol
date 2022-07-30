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

    /// @dev Finds details of this pool.
    /// @return poolName String name of this pool.
    /// @return poolSymbol String symbol of this pool.
    /// @return baseToken Address of base token (0 for coinbase).
    /// @return unitaryValue Value of the token in wei unit.
    /// @return spread Value of the spread from unitary value.
    // TODO: can inheritdoc only if implemented in subcontract
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

    /// @dev Finds the administrative data of the pool.
    /// @return Address of the owner.
    /// @return feeCollector Address of the account where a user collects fees.
    /// @return transactionFee Value of the transaction fee in basis points.
    /// @return minPeriod Number of the minimum holding period for tokens.
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

    function getKycProvider() external view override returns (address kycProviderAddress) {
        return kycProviderAddress = admin.kycProvider;
    }

    /// @dev Returns the total amount of issued tokens for this pool.
    /// @return Number of tokens.
    function totalSupply() external view override returns (uint256) {
        return poolData.totalSupply;
    }

    /*
     * PUBLIC VIEW METHODS
     */
    function name() public view override returns (string memory) {
        return poolData.name;
    }

    function symbol() public view override returns (string memory) {
        return poolData.symbol;
    }

    /// @dev Decimals are initialized at proxy creation only if base token not null.
    /// @return Number of decimals.
    /// @notice We use this method to save gas on base currency pools.
    function decimals() public view virtual override returns (uint8) {
        return poolData.decimals != 0 ? poolData.decimals : _coinbaseDecimals;
    }

    /*
     * INTERNAL VIEW METHODS
     */
    function _getMinPeriod() internal view virtual returns (uint32) {
        return poolData.minPeriod != 0 ? poolData.minPeriod : MIN_LOCKUP;
    }

    function _getSpread() internal view virtual returns (uint256) {
        return poolData.spread != 0 ? poolData.spread : INITIAL_SPREAD;
    }

    function _getUnitaryValue() internal view virtual returns (uint256) {
        return poolData.unitaryValue != 0 ? poolData.unitaryValue : _coinbaseUnitaryValue;
    }
}
