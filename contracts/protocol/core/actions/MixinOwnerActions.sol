// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import "./MixinActions.sol";
import "../../interfaces/INavVerifier.sol";

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

    /// @inheritdoc IRigoblockV3PoolOwnerActions
    function changeFeeCollector(address _feeCollector) external override onlyOwner {
        admin.feeCollector = _feeCollector;
        emit NewCollector(msg.sender, address(this), _feeCollector);
    }

    /// @inheritdoc IRigoblockV3PoolOwnerActions
    function changeMinPeriod(uint32 _minPeriod) external override onlyOwner {
        /// @notice minimum period is always at least 1 to prevent flash txs.
        require(_minPeriod >= MIN_LOCKUP && _minPeriod <= MAX_LOCKUP, "POOL_CHANGE_MIN_LOCKUP_PERIOD_ERROR");
        poolData.minPeriod = _minPeriod;
        // TODO: should emit event
    }

    /// @inheritdoc IRigoblockV3PoolOwnerActions
    function changeSpread(uint256 _newSpread) external override onlyOwner {
        // TODO: check what happens with value 0
        require(_newSpread < MAX_SPREAD, "POOL_SPREAD_TOO_HIGH_ERROR");
        poolData.spread = _newSpread;
        // TODO: should emit event
    }

    /// @inheritdoc IRigoblockV3PoolOwnerActions
    function setKycProvider(address _kycProvider) external override onlyOwner {
        admin.kycProvider = _kycProvider;
        // TODO: should emit event
    }

    /// @inheritdoc IRigoblockV3PoolOwnerActions
    function setTransactionFee(uint256 _transactionFee) external override onlyOwner {
        require(_transactionFee <= MAX_TRANSACTION_FEE, "POOL_FEE_HIGHER_THAN_ONE_PERCENT_ERROR"); //fee cannot be higher than 1%
        poolData.transactionFee = _transactionFee;
        emit NewFee(msg.sender, address(this), _transactionFee);
    }

    /// @inheritdoc IRigoblockV3PoolOwnerActions
    function setUnitaryValue(
        uint256 _unitaryValue,
        uint256 _signaturevaliduntilBlock,
        bytes32 _hash,
        bytes calldata _signedData
    ) external override onlyOwner notPriceError(_unitaryValue) {
        /// @notice Value can be updated only after first mint.
        // TODO: fix tests to apply following
        //require(poolData.totalSupply > 0, "POOL_SUPPLY_NULL_ERROR");
        require(
            _isValidNav(INavVerifier(address(this)), _unitaryValue, _signaturevaliduntilBlock, _hash, _signedData),
            "POOL_NAV_NOT_VALID_ERROR"
        );
        poolData.unitaryValue = _unitaryValue;
        emit NewNav(msg.sender, address(this), _unitaryValue);
    }

    function _getUnitaryValue() internal view virtual override returns (uint256);

    /// @dev Verifies that a signature is valid.
    /// @param _unitaryValue Value of 1 token in wei units.
    /// @param _signatureValidUntilBlock Number of blocks.
    /// @param _hash Message hash that is signed.
    /// @param _signedData Proof of nav validity.
    /// @return isValid Bool validity of signed price update.
    function _isValidNav(
        INavVerifier this_,
        uint256 _unitaryValue,
        uint256 _signatureValidUntilBlock,
        bytes32 _hash,
        bytes calldata _signedData
    ) private pure returns (bool) {
        return this_.isValidNav(_unitaryValue, _signatureValidUntilBlock, _hash, _signedData);
    }
}
