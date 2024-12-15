// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import "./MixinActions.sol";

abstract contract MixinOwnerActions is MixinActions {
    /// @dev We keep this check to prevent accidental failure in Nav calculations.
    modifier notPriceError(uint256 newUnitaryValue) {
        /// @notice most typical error is adding/removing one 0, we check by a factory of 5 for safety.
        require(
            newUnitaryValue < _getUnitaryValue() * 5 && newUnitaryValue > _getUnitaryValue() / 5,
            "POOL_INPUT_VALUE_ERROR"
        );
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == pool().owner, "POOL_CALLER_IS_NOT_OWNER_ERROR");
        _;
    }

    /// @inheritdoc IRigoblockV3PoolOwnerActions
    function changeFeeCollector(address feeCollector) external override onlyOwner {
        poolParams().feeCollector = feeCollector;
        emit NewCollector(msg.sender, address(this), feeCollector);
    }

    /// @inheritdoc IRigoblockV3PoolOwnerActions
    // TODO: as max is 1 months, we can simply set variable spread and remove this method
    function changeMinPeriod(uint48 minPeriod) external override onlyOwner {
        /// @notice minimum period is always at least 1 to prevent flash txs.
        require(minPeriod >= _MIN_LOCKUP && minPeriod <= _MAX_LOCKUP, "POOL_CHANGE_MIN_LOCKUP_PERIOD_ERROR");
        poolParams().minPeriod = minPeriod;
        emit MinimumPeriodChanged(address(this), minPeriod);
    }

    /// @inheritdoc IRigoblockV3PoolOwnerActions
    // TODO: check if this method should be deprecated for an automated spread.
    function changeSpread(uint16 newSpread) external override onlyOwner {
        // new spread must always be != 0, otherwise default spread from immutable storage will be returned
        require(newSpread > 0, "POOL_SPREAD_NULL_ERROR");
        require(newSpread <= _MAX_SPREAD, "POOL_SPREAD_TOO_HIGH_ERROR");
        poolParams().spread = newSpread;
        emit SpreadChanged(address(this), newSpread);
    }

    /// @inheritdoc IRigoblockV3PoolOwnerActions
    // TODO: we can add storage mapping as canonical whitelist, with a flag for canonical list
    // TODO: remove ability to set custom kyc provider, as it is not a demanded feature and there is no
    // guarantee kyc provider will use same interface. We could instead develop a userWhitelist extension
    // to support known kyc providers in the future
    function setKycProvider(address kycProvider) external override onlyOwner {
        require(_isContract(kycProvider), "POOL_INPUT_NOT_CONTRACT_ERROR");
        poolParams().kycProvider = kycProvider;
        emit KycProviderSet(address(this), kycProvider);
    }

    /// @inheritdoc IRigoblockV3PoolOwnerActions
    function setTransactionFee(uint16 transactionFee) external override onlyOwner {
        require(transactionFee <= _MAX_TRANSACTION_FEE, "POOL_FEE_HIGHER_THAN_ONE_PERCENT_ERROR"); //fee cannot be higher than 1%
        poolParams().transactionFee = transactionFee;
        emit NewFee(msg.sender, address(this), transactionFee);
    }

    /// @inheritdoc IRigoblockV3PoolOwnerActions
    function setOwner(address newOwner) public override onlyOwner {
        require(newOwner != address(0), "POOL_NULL_OWNER_INPUT_ERROR");
        address oldOwner = pool().owner;
        pool().owner = newOwner;
        emit NewOwner(oldOwner, newOwner);
    }

    function totalSupply() public view virtual override returns (uint256);

    function decimals() public view virtual override returns (uint8);

    function _getUnitaryValue() internal view virtual override returns (uint256);

    function _isContract(address target) private view returns (bool) {
        return target.code.length > 0;
    }
}
