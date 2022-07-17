// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2022 Rigo Intl.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.

*/

pragma solidity 0.8.14;

import { IAuthorityCore as Authority } from "./interfaces/IAuthorityCore.sol";
// TODO: modify import after contracts renaming
import { IAuthorityExtensions as AuthorityExtensions } from "./interfaces/IAuthorityExtensions.sol";
import { INavVerifier as NavVerifier } from "./interfaces/INavVerifier.sol";
import { IKyc as Kyc } from "./interfaces/IKyc.sol";
import { IERC20 as Token } from "./interfaces/IERC20.sol";
import { OwnedUninitialized as Owned } from "../utils/owned/OwnedUninitialized.sol";
import { ReentrancyGuard } from "../utils/reentrancyGuard/ReentrancyGuard.sol";

import { IRigoblockV3Pool } from "./IRigoblockV3Pool.sol";

/// @title RigoblockV3Pool - A set of rules for Rigoblock pools.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
contract RigoblockV3Pool is Owned, ReentrancyGuard, IRigoblockV3Pool {
    // TODO: move owned methods into rigoblock v3 subcontracts, move reentrancy guard to subcontracts.
    // TODO: add immutable base token and mint/burn in base token

    string public constant override VERSION = "HF 3.0.2";

    /// @notice Standard ERC20

    address public immutable override AUTHORITY;

    // minimum order size to avoid dust clogging things up
    uint256 private constant MINIMUM_ORDER = 1e15; // 1e15 = 1 finney

    // TODO: we could probably reduce deploy size by declaring smaller constants as uint32
    uint256 private constant FEE_BASE = 10000;
    uint256 private constant INITIAL_SPREAD = 500; // +-5%, in basis points
    uint256 private constant MAX_SPREAD = 1000; // +-10%, in basis points
    uint256 private constant MAX_TRANSACTION_FEE = 100; // maximum 1%
    uint256 private constant SPREAD_BASE = 10000;

    uint32 private constant INITIAL_LOCKUP = 1;

    // notice Must be immutable to be compile-time constant.
    // eip1967 standard
    address private immutable _implementation;

    uint8 private immutable COINBASE_DECIMALS;
    uint256 private immutable COINBASE_UNITARY_VALUE;

    // TODO: hardcode selector to save gas
    bytes4 immutable private TRANSFER_FROM_SELECTOR = bytes4(
        keccak256(bytes("transferFrom(address,address,uint256)"))
    );

    mapping(address => Account) internal userAccount;

    PoolData poolData;
    Admin admin;

    struct Account {
        uint256 balance;
        uint32 activation;
    }

    struct PoolData {
        string name;
        string symbol;
        uint256 unitaryValue;   // initially = 1 * 10**decimals
        // TODO: check if we get benefit as storing spread as uint32
        uint256 spread;  // in basis points 1 = 0.01%
        uint256 totalSupply;
        uint256 transactionFee; // in basis points 1 = 0.01%
        uint32 minPeriod;
        uint8 decimals;
    }

    struct Admin {
        address feeCollector;
        address kycProvider;
        address baseToken; // TODO: check where best to store
    }

    // reading immutable through internal method more gas efficient
    modifier onlyDelegateCall() {
        _checkDelegateCall();
        _;
    }

    modifier onlyUninitialized() {
        // pool proxy is always initialized in the constructor, therefore
        // empty extcodesize means the pool has not been initialized
        address self = address(this);
        uint256 size;
        assembly {
            size := extcodesize(self)
        }
        require(
            size == 0,
            "POOL_ALREADY_INITIALIZED_ERROR"
        );
        _;
    }

    modifier hasEnough(uint256 _amount) {
        require(
            userAccount[msg.sender].balance >= _amount,
            "POOL_BURN_NOT_ENOUGH_ERROR"
        );
        _;
    }

    modifier minimumPeriodPast() {
        require(
            block.timestamp >= userAccount[msg.sender].activation,
            "POOL_MINIMUM_PERIOD_NOT_ENOUGH_ERROR"
        );
        _;
    }

    /// @dev We keep this check to prevent accidental failure in Nav calculations.
    modifier notPriceError(uint256 _newUnitaryValue) {
        /// @notice most typical error is adding/removing one 0, we check by a factory of 5 for safety.
        require(
            _newUnitaryValue < _getUnitaryValue() * 5 &&
            _newUnitaryValue > _getUnitaryValue() / 5,
            "POOL_INPUT_VALUE_ERROR"
        );
        _;
    }

    /// @notice Owner is initialized to 0 to lock owner actions in this implementation.
    /// @notice Kyc provider set as will effectively lock direct mint/burn actions.
    constructor(address _authority) {
        AUTHORITY = _authority;
        COINBASE_DECIMALS = 18;
        COINBASE_UNITARY_VALUE = 1 * 10**COINBASE_DECIMALS;
        _implementation = address(this);
        // must lock implementation after initializing _implementation
        owner = address(0);
        admin.kycProvider == address(1);
    }

    /*
     * CORE FUNCTIONS
     */
    /// @dev Delegate calls to extension.
    // restricting delegatecall to owner effectively locks direct calls
    fallback() external payable {
        address adapter = _getApplicationAdapter(msg.sig);
        // we check that the method is approved by governance
        require(adapter != address(0), "POOL_METHOD_NOT_ALLOWED_ERROR");

        address poolOwner = owner;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let success
            // pool owner can execute a delegatecall to extension, any other caller will perform a staticcall
            if eq(caller(), poolOwner) {
                success := delegatecall(gas(), adapter, 0, calldatasize(), 0, 0)
                returndatacopy(0, 0, returndatasize())
                if eq(success, 0) {
                    revert(0, returndatasize())
                }
                return(0, returndatasize())
            }
            success := staticcall(gas(), adapter, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            // TODO: view methods will never be restricted as onchain data are public, should never revert. We could skip this check
            if eq(success, 0) {
                revert(0, returndatasize())
            }
            return(0, returndatasize())
        }
    }

    // prevent accidental transfer to implementation
    receive() external payable onlyDelegateCall {
        assert(msg.value > 0);
    }

    // pool can only be initialized at creation, meaning this method cannot be
    //  called directly to implementation.
    function _initializePool(
        string calldata _poolName,
        string calldata _poolSymbol,
        address _baseToken,
        address _owner
    )
        onlyUninitialized
        external
        override
    {
        // TODO: check gas savings in batching variables | and returning individually
        // uint256 | uint256
        // TODO: check if initialize smaller uints at smaller higher cost
        poolData.name = _poolName;
        poolData.symbol = _poolSymbol;
        owner = _owner;
        /// @notice We only initialize if different from default values.
        /// @notice Be very careful with new releases as default values must be returned unless poolData overwritten.
        // TODO: test different initialization scenarios
        if (_baseToken != address(0)) {
            admin.baseToken = _baseToken;
            uint8 tokenDecimals = Token(_baseToken).decimals();
            if (tokenDecimals != COINBASE_DECIMALS) {
                poolData.decimals = tokenDecimals;
                poolData.unitaryValue = 1 * 10**tokenDecimals; // initial value is 1
            }
        } // we do not initialize unless values different from default ones.

        emit PoolInitialized(msg.sender, _owner, _poolName, _poolSymbol);
    }

    /// @dev Allows a user to mint pool tokens on behalf of an address.
    /// @param _recipient Address receiving the tokens.
    /// @param _amountIn Amount of base tokens.
    /// @return recipientAmount Number of tokens minted to recipient.
    function mint(address _recipient, uint256 _amountIn)
        public
        payable
        override
        returns (uint256 recipientAmount)
    {
        // require whitelisted user if kyc is enforced
        if (_isKycEnforced() == true) {
            require(
                Kyc(admin.kycProvider).isWhitelistedUser(_recipient),
                "POOL_CALLER_NOT_WHITELISTED_ERROR"
            );
        }

        uint256 mintPrice = _getUnitaryValue();
        mintPrice += _getUnitaryValue() * _getSpread() / SPREAD_BASE;
        uint256 mintedAmount;
        if (admin.baseToken == address(0)) {
            _assertBiggerThanMinimum(msg.value);
            mintedAmount = msg.value * decimals() / mintPrice;
        } else {
            _assertBiggerThanMinimum(_amountIn);
            _safeTransferFrom(msg.sender, address(this), _amountIn);
            mintedAmount = _amountIn * decimals() / mintPrice;
        }
        poolData.totalSupply += mintedAmount;
        recipientAmount = _allocateMintTokens(_recipient, mintedAmount);
    }

    /// @dev Allows a pool holder to burn pool tokens.
    /// @param _amountIn Number of tokens to burn.
    /// @return netRevenue Net amount of burnt pool tokens.
    function burn(uint256 _amountIn)
        external
        override
        nonReentrant
        hasEnough(_amountIn)
        minimumPeriodPast
        returns (uint256 netRevenue)
    {
        require(_amountIn > 0, "POOL_BURN_NULL_AMOUNT_ERROR");
        uint256 buntAmount = _allocateBurnTokens(_amountIn);
        uint256 burnPrice = _getUnitaryValue();
        burnPrice -= _getUnitaryValue() * _getSpread() / SPREAD_BASE;
        netRevenue = buntAmount * burnPrice / decimals();

        // TODO: implement in base token
        payable(msg.sender).transfer(netRevenue);
    }

    /// @dev Allows pool owner to set the pool price.
    /// @param _unitaryValue Value of 1 token in wei units.
    /// @param _signaturevaliduntilBlock Number of blocks until expiry of new poolData.
    /// @param _hash Bytes32 of the transaction hash.
    /// @param _signedData Bytes of extradata and signature.
    function setUnitaryValue(
        uint256 _unitaryValue,
        uint256 _signaturevaliduntilBlock,
        bytes32 _hash,
        bytes calldata _signedData)
        external
        override
        onlyOwner
        notPriceError(_unitaryValue)
    {
        /// @notice Value can be updated only after first mint.
        // TODO: fix tests to apply following
        //require(poolData.totalSupply > 0, "POOL_SUPPLY_NULL_ERROR");
        require(
            _isValidNav(
                _unitaryValue,
                _signaturevaliduntilBlock,
                _hash,
                _signedData
            ),
            "POOL_NAV_NOT_VALID_ERROR"
        );
        poolData.unitaryValue = _unitaryValue;
        emit NewNav(msg.sender, address(this), _unitaryValue);
    }

    /// @dev Allows pool owner to set the transaction fee.
    /// @param _transactionFee Value of the transaction fee in basis points.
    function setTransactionFee(uint256 _transactionFee)
        external
        override
        onlyOwner
    {
        require(
            _transactionFee <= MAX_TRANSACTION_FEE,
            "POOL_FEE_HIGHER_THAN_ONE_PERCENT_ERROR"
            ); //fee cannot be higher than 1%
        poolData.transactionFee = _transactionFee;
        emit NewFee(msg.sender, address(this), _transactionFee);
    }

    /// @dev Allows owner to decide where to receive the fee.
    /// @param _feeCollector Address of the fee receiver.
    function changeFeeCollector(address _feeCollector)
        external
        override
        onlyOwner
    {
        admin.feeCollector = _feeCollector;
        emit NewCollector(msg.sender, address(this), _feeCollector);
    }

    /// @dev Allows pool owner to change the minimum holding period.
    /// @param _minPeriod Time in seconds.
    function changeMinPeriod(uint32 _minPeriod)
        external
        override
        onlyOwner
    {
        /// @notice minimum period is always at least 1 to prevent flash txs.
        require(
            _minPeriod > 0 && _minPeriod <= 30 days,
            "POOL_CHANGE_MIN_LOCKUP_PERIOD_ERROR"
        );
        poolData.minPeriod = _minPeriod;
        // TODO: should emit event
    }

    function changeSpread(uint256 _newSpread) external override onlyOwner {
        // TODO: check what happens with value 0
        require(
            _newSpread < MAX_SPREAD,
            "POOL_SPREAD_TOO_HIGH_ERROR"
        );
        poolData.spread = _newSpread;
        // TODO: should emit event
    }

    /// @notice Kyc provider can be set to null, removing user whitelist requirement.
    function setKycProvider(address _kycProvider) external override onlyOwner {
        admin.kycProvider = _kycProvider;
        // TODO: should emit event
    }

    /*
     * CONSTANT PUBLIC FUNCTIONS
     */
    /// @dev Returns how many pool tokens a user holds.
    /// @param _who Address of the target account.
    /// @return Number of pool.
    function balanceOf(address _who)
        external
        view
        override
        returns (uint256)
    {
        return userAccount[_who].balance;
    }

    /// @dev Finds details of this pool.
    /// @return poolName String name of this pool.
    /// @return poolSymbol String symbol of this pool.
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
            uint256 unitaryValue,
            uint256 spread
        )
    {
        // TODO: check if we should reorg return data for client efficiency
        return(
            poolName = poolData.name,
            poolSymbol = poolData.symbol,
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
            address,  //owner
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

    function getKycProvider()
        external
        view
        override
        returns (address kycProviderAddress)
    {
        return kycProviderAddress = admin.kycProvider;
    }

    /// @dev Returns the total amount of issued tokens for this pool.
    /// @return Number of tokens.
    function totalSupply() external view override returns (uint256) {
        return poolData.totalSupply;
    }

    function name() external view override returns (string memory) {
        return poolData.name;
    }

    function symbol() external view override returns (string memory) {
        return poolData.symbol;
    }

    /// @dev Decimals are initialized at proxy creation only if base token not null.
    /// @return Number of decimals.
    /// @notice We use this method to save gas on base currency pools.
    function decimals() public view override returns (uint8) {
        if (admin.baseToken != address(0)) {
            return Token(admin.baseToken).decimals();
        } else return COINBASE_DECIMALS;
    }

    /*
     * NON-IMPLEMENTED INTERFACE FUNCTIONS
     */
    function transfer(
        address _to,
        uint256 _value
    )
        external
        virtual
        override
        returns (bool success)
    {}

    function transferFrom(
        address _from,
        address _to,
        uint256 _value
    )
        external
        virtual
        override
        returns (bool success)
    {}

    function approve(
        address _spender,
        uint256 _value
    )
        external
        virtual
        override
        returns (bool success)
    {}

    function allowance(
        address _owner,
        address _spender)
        external
        view
        virtual
        override
        returns (uint256)
    {}

    /*
     * INTERNAL FUNCTIONS
     */
    /// @dev Allocates tokens to recipient.
    /// @param _recipient Address of the recipient.
    /// @param _mintedAmount Value of issued tokens.
    /// @return recipientAmount Number of new tokens issued to recipient.
    function _allocateMintTokens(
        address _recipient,
        uint256 _mintedAmount
    )
        internal
        returns (uint256 recipientAmount)
    {
        /// @notice Each mint on same recipient resets prior activation.
        /// @notice Lock receipient tokens.
        unchecked {
            userAccount[_recipient].activation = (
                uint32(block.timestamp) + _getMinPeriod()
            );
        }

        if (poolData.transactionFee != uint256(0)) {
            // TODO: test
            address feeCollector = (
                admin.feeCollector != address(0) ? admin.feeCollector : owner
            );

            if (feeCollector == _recipient) {
                recipientAmount = _mintedAmount;
                userAccount[feeCollector].balance += recipientAmount;
                emit Transfer(address(0), feeCollector, recipientAmount);
            } else {
                /// @notice Lock fee tokens as well.
                unchecked {
                    userAccount[feeCollector].activation = (
                        uint32(block.timestamp) + _getMinPeriod()
                    );
                }
                uint256 feePool = _mintedAmount * poolData.transactionFee / FEE_BASE;
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
    function _allocateBurnTokens(
        uint256 _amountIn
    )
        internal
        returns (uint256 buntAmount)
    {
        if (poolData.transactionFee != uint256(0)) {
            address feeCollector = (
                admin.feeCollector != address(0) ? admin.feeCollector : owner
            );
            if (msg.sender == feeCollector) {
                buntAmount = _amountIn;
                userAccount[msg.sender].balance -= buntAmount;
                emit Transfer(msg.sender, address(0), buntAmount);
            } else {
                uint256 feePool = _amountIn * poolData.transactionFee / FEE_BASE;
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
        poolData.totalSupply -= buntAmount;
    }

    /// @dev Verifies that a signature is valid.
    /// @param _unitaryValue Value of 1 token in wei units.
    /// @param _signatureValidUntilBlock Number of blocks.
    /// @param _hash Message hash that is signed.
    /// @param _signedData Proof of nav validity.
    /// @return isValid Bool validity of signed price update.
    function _isValidNav(
        uint256 _unitaryValue,
        uint256 _signatureValidUntilBlock,
        bytes32 _hash,
        // TODO: check are we are using calldata instead of memory
        bytes calldata _signedData)
        internal
        view
        returns (bool)
    {
        return NavVerifier(address(this)).isValidNav(
            _unitaryValue,
            _signatureValidUntilBlock,
            _hash,
            _signedData
        );
    }

    /// @dev Returns the address of the application adapter.
    /// @param _selector Hash of the method signature.
    /// @return Address of the application adapter.
    function _getApplicationAdapter(bytes4 _selector)
        internal
        view
        returns (address)
    {
        return AuthorityExtensions(
            _getAuthorityExtensions()
        ).getApplicationAdapter(_selector);
    }

    function _checkDelegateCall() private view {
        require(
            address(this) != _implementation,
            "POOL_IMPLEMENTATION_DIRECT_CALL_NOT_ALLOWED_ERROR"
        );
    }

    function _assertBiggerThanMinimum(uint256 _amount) private pure {
        require (
            _amount >= MINIMUM_ORDER,
            "POOL_AMOUNT_SMALLER_THAN_MINIMUM_ERROR"
        );
    }

    /// @dev Finds the extensions authority.
    /// @return Address of the extensions authority.
    // TODO: check under what circumstances we call this method, as can
    //  initialize extensions authority address as well as authority, and skip
    //  1 read operation in this call. Governance must upgrade implementation
    //   when it upgrades extensions authority.
    function _getAuthorityExtensions()
        private
        view
        returns (address)
    {
        return Authority(AUTHORITY).getAuthorityExtensions();
    }

    function _getMinPeriod() private view returns (uint32) {
        return poolData.minPeriod == 0 ? INITIAL_LOCKUP : poolData.minPeriod;
    }

    function _getSpread() private view returns (uint256) {
        return poolData.spread == 0 ? INITIAL_SPREAD : poolData.spread;
    }

    function _getUnitaryValue() private view returns (uint256) {
        return (
            poolData.unitaryValue == 0 ? COINBASE_UNITARY_VALUE
            : poolData.unitaryValue
        );
    }

    function _isKycEnforced() private view returns (bool) {
        return admin.kycProvider != address(0);
    }

    function _safeTransferFrom(
        address _from,
        address _to,
        uint256 _amount
    )
        private
    {
        // solhint-disable-next-line avoid-low-level-calls
        // TODO: we may want to use assembly here
        (bool success, bytes memory data) = admin.baseToken.call(
            abi.encodeWithSelector(
                TRANSFER_FROM_SELECTOR,
                _from,
                _to,
                _amount
            )
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "POOL_TRANSFER_FROM_FAILED_ERROR"
        );
    }
}
