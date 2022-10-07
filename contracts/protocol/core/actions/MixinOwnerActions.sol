// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import "./MixinActions.sol";

abstract contract MixinOwnerActions is MixinActions {
    /// @dev We keep this check to prevent accidental failure in Nav calculations.
    modifier notPriceError(uint256 _newUnitaryValue) {
        /// @notice most typical error is adding/removing one 0, we check by a factory of 5 for safety.
        require(
            _newUnitaryValue < _getUnitaryValue() * 5 && _newUnitaryValue > _getUnitaryValue() / 5,
            "POOL_INPUT_VALUE_ERROR"
        );
        _;
    }

    // TODO: remove owner import
    modifier onlyOwner() {
        require(msg.sender == pool.owner, "POOL_CALLER_IS_NOT_OWNER_ERROR");
        _;
    }

    // TODO: consider updating all struct values in one call. Also consider initializing unitialized params at first mint
    /// @inheritdoc IRigoblockV3PoolOwnerActions
    function changeFeeCollector(address _feeCollector) external override onlyOwner {
        poolParams.feeCollector = _feeCollector;
        emit NewCollector(msg.sender, address(this), _feeCollector);
    }

    /// @inheritdoc IRigoblockV3PoolOwnerActions
    function changeMinPeriod(uint48 _minPeriod) external override onlyOwner {
        /// @notice minimum period is always at least 1 to prevent flash txs.
        require(_minPeriod >= MIN_LOCKUP && _minPeriod <= MAX_LOCKUP, "POOL_CHANGE_MIN_LOCKUP_PERIOD_ERROR");
        poolParams.minPeriod = _minPeriod;
        emit MinimumPeriodChanged(address(this), _minPeriod);
    }

    /// @inheritdoc IRigoblockV3PoolOwnerActions
    function changeSpread(uint16 _newSpread) external override onlyOwner {
        // new spread must always be != 0, otherwise default spread from immutable storage will be returned
        require(_newSpread > 0, "POOL_SPREAD_NULL_ERROR");
        require(_newSpread <= MAX_SPREAD, "POOL_SPREAD_TOO_HIGH_ERROR");
        poolParams.spread = _newSpread;
        emit SpreadChanged(address(this), _newSpread);
    }

    /// @inheritdoc IRigoblockV3PoolOwnerActions
    function setKycProvider(address _kycProvider) external override onlyOwner {
        require(_isContract(_kycProvider), "POOL_INPUT_NOT_CONTRACT_ERROR");
        poolParams.kycProvider = _kycProvider;
        emit KycProviderSet(address(this), _kycProvider);
    }

    /// @inheritdoc IRigoblockV3PoolOwnerActions
    function setTransactionFee(uint16 _transactionFee) external override onlyOwner {
        require(_transactionFee <= MAX_TRANSACTION_FEE, "POOL_FEE_HIGHER_THAN_ONE_PERCENT_ERROR"); //fee cannot be higher than 1%
        poolParams.transactionFee = _transactionFee;
        emit NewFee(msg.sender, address(this), _transactionFee);
    }

    /// @inheritdoc IRigoblockV3PoolOwnerActions
    function setUnitaryValue(uint256 _unitaryValue) external override onlyOwner notPriceError(_unitaryValue) {
        // unitary value can be updated only after first mint. we require positive value as would
        //  return to default value if storage cleared
        require(poolTokens.totalSupply > 0, "POOL_SUPPLY_NULL_ERROR");

        // This will underflow with small decimals tokens at some point, which is ok
        uint256 minimumLiquidity = ((_unitaryValue * totalSupply()) / 10**decimals() / 100) * 3;

        if (pool.baseToken == address(0)) {
            require(address(this).balance >= minimumLiquidity, "POOL_CURRENCY_BALANCE_TOO_LOW_ERROR");
        } else {
            require(
                IERC20(pool.baseToken).balanceOf(address(this)) >= minimumLiquidity,
                "POOL_TOKEN_BALANCE_TOO_LOW_ERROR"
            );
        }

        poolTokens.unitaryValue = _unitaryValue;
        emit NewNav(msg.sender, address(this), _unitaryValue);
    }

    function setOwner(address _newOwner) public override onlyOwner {
        require(_newOwner != address(0), "POOL_NULL_OWNER_INPUT_ERROR");
        address oldOwner = pool.owner;
        pool.owner = _newOwner;
        emit NewOwner(oldOwner, _newOwner);
    }

    function totalSupply() public view virtual override returns (uint256) {}

    function decimals() public view virtual override returns (uint8) {}

    function _getUnitaryValue() internal view virtual override returns (uint256);

    function _isContract(address _target) private view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_target)
        }
        return size > 0;
    }
}
