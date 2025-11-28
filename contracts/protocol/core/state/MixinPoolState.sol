// SPDX-License-Identifier: Apache 2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {MixinPoolValue} from "../state/MixinPoolValue.sol";
import {ISmartPoolState} from "../../interfaces/v4/pool/ISmartPoolState.sol";
import {Pool} from "../../libraries/EnumerableSet.sol";

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

    /// @inheritdoc ISmartPoolState
    function getAcceptedMintTokens() external view override returns (address[] memory tokens) {
        return _getAcceptedMintTokens();
    }

    /// @inheritdoc ISmartPoolState
    /// @dev Grg staking and UniV3 positions will not be returned by default.
    function getActiveApplications() external view override returns (uint256 packedApplications) {
        return _getActiveApplications();
    }

    /// @inheritdoc ISmartPoolState
    function getActiveTokens() external view override returns (ActiveTokens memory tokens) {
        return _getActiveTokens();
    }

    /// @inheritdoc ISmartPoolState
    function getPoolStorage()
        external
        view
        override
        returns (ReturnedPool memory poolInitParams, PoolParams memory poolVariables, PoolTokens memory poolTokensInfo)
    {
        return (getPool(), getPoolParams(), getPoolTokens());
    }

    function getUserAccount(address who) external view override returns (UserAccount memory) {
        return accounts().userAccounts[who];
    }

    /// @inheritdoc ISmartPoolState
    function name() external view override returns (string memory) {
        return pool().name;
    }

    /// @inheritdoc ISmartPoolState
    function owner() external view override returns (address) {
        return pool().owner;
    }

    /// @inheritdoc ISmartPoolState
    function totalSupply() external view override returns (uint256) {
        return poolTokens().totalSupply;
    }

    /*
     * PUBLIC VIEW METHODS
     */
    /// @notice Decimals are initialized at proxy creation.
    /// @return Number of decimals.
    function decimals() public view override returns (uint8) {
        return pool().decimals;
    }

    /// @inheritdoc ISmartPoolState
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

    /// @inheritdoc ISmartPoolState
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

    /// @inheritdoc ISmartPoolState
    function getPoolTokens() public view override returns (PoolTokens memory) {
        uint256 unitaryValue = poolTokens().unitaryValue;
        return
            PoolTokens({
                unitaryValue: unitaryValue != 0 ? unitaryValue : 10 ** pool().decimals,
                totalSupply: poolTokens().totalSupply
            });
    }

    /// @inheritdoc ISmartPoolState
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

    /// @inheritdoc ISmartPoolState
    function isOperator(address holder, address operator) public view override returns (bool) {
        return operators().isApproved[holder][operator];
    }

    /*
     * INTERNAL VIEW METHODS
     */
    function _getActiveApplications() internal view override returns (uint256) {
        return activeApplications().packedApplications;
    }

    function _getFeeCollector() internal view override returns (address) {
        address feeCollector = poolParams().feeCollector;
        return feeCollector != _ZERO_ADDRESS ? feeCollector : pool().owner;
    }

    function _getMinPeriod() internal view override returns (uint48) {
        uint48 minPeriod = poolParams().minPeriod;
        return minPeriod != 0 ? minPeriod : _MAX_LOCKUP;
    }

    function _getSpread() internal view override returns (uint16) {
        uint16 spread = poolParams().spread;
        return spread != 0 ? spread : _DEFAULT_SPREAD;
    }

    function _getTokenJar() internal view override returns (address) {
        return tokenJar;
    }

    function _getAcceptedMintTokens() private view returns (address[] memory) {
        return acceptedTokensSet().addresses;
    }

    function _getActiveTokens() private view returns (ActiveTokens memory tokens) {
        tokens.activeTokens = activeTokensSet().addresses;
        tokens.baseToken = pool().baseToken;
    }
}
