// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import "../immutable/MixinConstants.sol";
import "../immutable/MixinImmutables.sol";
import "../immutable/MixinStorage.sol";
import "../../interfaces/IKyc.sol";

abstract contract MixinActions is MixinConstants, MixinImmutables, MixinStorage {
    /*
     * MODIFIERS
     */
    modifier hasEnough(uint256 _amount) {
        require(userAccount[msg.sender].balance >= _amount, "POOL_BURN_NOT_ENOUGH_ERROR");
        _;
    }

    modifier minimumPeriodPast() {
        require(block.timestamp >= userAccount[msg.sender].activation, "POOL_MINIMUM_PERIOD_NOT_ENOUGH_ERROR");
        _;
    }

    /*
     * EXTERNAL METHODS
     */
    /// @inheritdoc IRigoblockV3PoolActions
    function burn(uint256 _amountIn)
        external
        override
        nonReentrant
        hasEnough(_amountIn)
        minimumPeriodPast
        returns (uint256 netRevenue)
    {
        require(_amountIn > 0, "POOL_BURN_NULL_AMOUNT_ERROR");

        /// @notice allocate pool token transfers and log events.
        uint256 buntAmount = _allocateBurnTokens(_amountIn);
        poolData.totalSupply -= buntAmount;

        uint256 markup = (buntAmount * _getSpread()) / SPREAD_BASE;
        buntAmount -= markup;
        netRevenue = (buntAmount * _getUnitaryValue()) / 10**decimals();

        if (admin.baseToken == address(0)) {
            payable(msg.sender).transfer(netRevenue);
        } else {
            _safeTransfer(msg.sender, netRevenue);
        }
    }

    /// @inheritdoc IRigoblockV3PoolActions
    function mint(address _recipient, uint256 _amountIn) public payable override returns (uint256 recipientAmount) {
        // require whitelisted user if kyc is enforced
        if (_isKycEnforced()) {
            require(IKyc(admin.kycProvider).isWhitelistedUser(_recipient), "POOL_CALLER_NOT_WHITELISTED_ERROR");
        }

        _assertBiggerThanMinimum(_amountIn);

        if (admin.baseToken == address(0)) {
            require(msg.value == _amountIn, "POOL_MINT_AMOUNTIN_ERROR");
        } else {
            _safeTransferFrom(msg.sender, address(this), _amountIn);
        }

        uint256 markup = (_amountIn * _getSpread()) / SPREAD_BASE;
        _amountIn -= markup;
        uint256 mintedAmount = (_amountIn * 10**decimals()) / _getUnitaryValue();
        poolData.totalSupply += mintedAmount;

        /// @notice allocate pool token transfers and log events.
        recipientAmount = _allocateMintTokens(_recipient, mintedAmount);
    }

    /*
     * PUBLIC METHODS
     */
    function decimals() public view virtual override returns (uint8);

    /*
     * INTERNAL METHODS
     */
    function _getMinPeriod() internal view virtual returns (uint32);

    function _getSpread() internal view virtual returns (uint256);

    function _getUnitaryValue() internal view virtual returns (uint256);

    /*
     * PRIVATE METHODS
     */
    /// @dev Allocates tokens to recipient.
    /// @param _recipient Address of the recipient.
    /// @param _mintedAmount Value of issued tokens.
    /// @return recipientAmount Number of new tokens issued to recipient.
    function _allocateMintTokens(address _recipient, uint256 _mintedAmount) private returns (uint256 recipientAmount) {
        /// @notice Each mint on same recipient resets prior activation.
        /// @notice Lock recipient tokens, max lockup 30 days cannot overflow.
        unchecked {userAccount[_recipient].activation = uint32(block.timestamp) + _getMinPeriod();}

        if (poolData.transactionFee != uint256(0)) {
            // TODO: test
            address feeCollector = (admin.feeCollector != address(0) ? admin.feeCollector : owner);

            if (feeCollector == _recipient) {
                recipientAmount = _mintedAmount;
                userAccount[feeCollector].balance += recipientAmount;
                emit Transfer(address(0), feeCollector, recipientAmount);
            } else {
                /// @notice Lock fee tokens as well.
                unchecked {userAccount[feeCollector].activation = (uint32(block.timestamp) + _getMinPeriod());}
                uint256 feePool = (_mintedAmount * poolData.transactionFee) / FEE_BASE;
                recipientAmount = _mintedAmount - feePool;
                userAccount[feeCollector].balance += feePool;
                userAccount[_recipient].balance += recipientAmount;
                emit Transfer(address(0), feeCollector, feePool);
                emit Transfer(address(0), _recipient, recipientAmount);
            }
        } else {
            recipientAmount = _mintedAmount;
            userAccount[_recipient].balance += recipientAmount;
            emit Transfer(address(0), _recipient, recipientAmount);
        }
    }

    /// @dev Destroys tokens of holder.
    /// @param _amountIn Value of tokens to be burnt.
    /// @return buntAmount Number of net burnt tokens.
    /// @notice Fee is paid in pool tokens.
    function _allocateBurnTokens(uint256 _amountIn) private returns (uint256 buntAmount) {
        if (poolData.transactionFee != uint256(0)) {
            address feeCollector = (admin.feeCollector != address(0) ? admin.feeCollector : owner);
            if (msg.sender == feeCollector) {
                buntAmount = _amountIn;
                userAccount[msg.sender].balance -= buntAmount;
                emit Transfer(msg.sender, address(0), buntAmount);
            } else {
                uint256 feePool = (_amountIn * poolData.transactionFee) / FEE_BASE;
                buntAmount = _amountIn - feePool;
                userAccount[feeCollector].balance += feePool;
                userAccount[msg.sender].balance -= buntAmount;
                emit Transfer(msg.sender, feeCollector, feePool);
                emit Transfer(msg.sender, address(0), buntAmount);
            }
        } else {
            buntAmount = _amountIn;
            userAccount[msg.sender].balance -= buntAmount;
            emit Transfer(msg.sender, address(0), buntAmount);
        }
    }

    function _assertBiggerThanMinimum(uint256 _amount) private view {
        require(_amount >= 10**decimals() / MINIMUM_ORDER_DIVISOR, "POOL_AMOUNT_SMALLER_THAN_MINIMUM_ERROR");
    }

    function _isKycEnforced() private view returns (bool) {
        return admin.kycProvider != address(0);
    }

    function _safeTransfer(address _to, uint256 _amount) private {
        // solhint-disable-next-line avoid-low-level-calls
        // TODO: we may want to use assembly here
        (bool success, bytes memory data) =
            admin.baseToken.call(abi.encodeWithSelector(TRANSFER_SELECTOR, _to, _amount));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "POOL_TRANSFER_FAILED_ERROR");
    }

    function _safeTransferFrom(
        address _from,
        address _to,
        uint256 _amount
    ) private {
        // solhint-disable-next-line avoid-low-level-calls
        // TODO: we may want to use assembly here
        (bool success, bytes memory data) =
            admin.baseToken.call(abi.encodeWithSelector(TRANSFER_FROM_SELECTOR, _from, _to, _amount));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "POOL_TRANSFER_FROM_FAILED_ERROR");
    }
}
