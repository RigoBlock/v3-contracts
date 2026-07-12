// SPDX-License-Identifier: Apache 2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {MixinPoolValue} from "../state/MixinPoolValue.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {IPoolRegistry} from "../../interfaces/IPoolRegistry.sol";
import {ISmartPoolState} from "../../interfaces/v4/pool/ISmartPoolState.sol";
import {DelegationData, DelegationLib} from "../../libraries/DelegationLib.sol";
import {Pool} from "../../libraries/EnumerableSet.sol";

abstract contract MixinPoolState is MixinPoolValue {
    using DelegationLib for DelegationData;

    /*
     * EXTERNAL VIEW METHODS
     */
    /// @inheritdoc IERC20
    function balanceOf(address who) external view override returns (uint256) {
        return accounts().userAccounts[who].userBalance;
    }

    /// @inheritdoc ISmartPoolState
    function getAcceptedMintTokens() external view override returns (address[] memory tokens) {
        return _getAcceptedMintTokens();
    }

    /// @inheritdoc ISmartPoolState
    /// @dev Grg staking is always queried regardless of the active bit.
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

    /// @inheritdoc ISmartPoolState
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
     * EXTERNAL ERC20 METHODS
     */
    /// @inheritdoc IERC20
    function transfer(address to, uint256 value) external override returns (bool success) {
        _transfer(msg.sender, to, value);
        return true;
    }

    /// @inheritdoc IERC20
    function transferFrom(address from, address to, uint256 value) external override returns (bool success) {
        _spendAllowance(from, msg.sender, value);
        _transfer(from, to, value);
        return true;
    }

    /// @inheritdoc IERC20
    function approve(address spender, uint256 value) external override returns (bool success) {
        require(spender != _ZERO_ADDRESS, PoolTokenApproveToNullAddress());
        allowances().allowances[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    /// @inheritdoc IERC20
    function allowance(address _owner, address spender) external view override returns (uint256) {
        return allowances().allowances[_owner][spender];
    }

    /*
     * PUBLIC VIEW METHODS
     */
    /// @inheritdoc IERC20
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

    /// @inheritdoc ISmartPoolState
    function getDelegatedAddresses(bytes4 selector) external view override returns (address[] memory) {
        return delegation().getAddresses(selector);
    }

    /// @inheritdoc ISmartPoolState
    function getDelegatedSelectors(address delegated) external view override returns (bytes4[] memory) {
        return delegation().getSelectors(delegated);
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

    error PoolTokenTransferToNullAddress();
    error PoolTokenCannotReceivePoolTokens(address pool);
    error PoolTokenInsufficientBalance();
    error PoolTokenInsufficientAllowance();
    error PoolTokenApproveToNullAddress();

    function _transfer(address from, address to, uint256 value) private {
        require(to != _ZERO_ADDRESS, PoolTokenTransferToNullAddress());
        require(
            IPoolRegistry(poolRegistry).getPoolIdFromAddress(to) == bytes32(0),
            PoolTokenCannotReceivePoolTokens(to)
        );

        UserAccount storage senderAccount = accounts().userAccounts[from];
        require(senderAccount.userBalance >= value, PoolTokenInsufficientBalance());

        UserAccount storage recipientAccount = accounts().userAccounts[to];

        // Transferred tokens carry the sender's lockup expiration; the recipient's activation
        // is set to the sender's so that the lockup is not extended beyond what the sender had.
        recipientAccount.activation = senderAccount.activation;

        senderAccount.userBalance -= uint208(value);
        recipientAccount.userBalance += uint208(value);

        emit Transfer(from, to, value);
    }

    function _spendAllowance(address _owner, address spender, uint256 value) private {
        uint256 currentAllowance = allowances().allowances[_owner][spender];
        require(currentAllowance >= value, PoolTokenInsufficientAllowance());
        if (currentAllowance != type(uint256).max) {
            allowances().allowances[_owner][spender] = currentAllowance - value;
        }
    }
}
