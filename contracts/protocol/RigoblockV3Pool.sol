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
import { IExchangesAuthority as ExtensionsAuthority } from "./interfaces/IExchangesAuthority.sol";
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
    uint256 public constant override decimals = 1e18;

    address public immutable override AUTHORITY;

    // minimum order size to avoid dust clogging things up
    uint256 private constant MINIMUM_ORDER = 1e15; // 1e15 = 1 finney

    uint256 private constant INITIAL_SELL_PRICE = 1e18;
    uint256 private constant INITIAL_BUY_PRICE = 1e18;
    uint256 private constant INITIAL_RATIO = 80;  // 80 is 80%

    /// @notice Must be immutable to be compile-time constant.
    address private immutable _implementation;

    // TODO: dao should not individually claim fee, remove dao fee or pay to dao at mint/burn (requires transfer()).
    address private immutable RIGOBLOCK_DAO;

    mapping(address => Account) internal accounts;

    PoolData poolData;
    Admin admin;

    struct Receipt {
        uint256 units;
        uint32 activation;
    }

    struct Account {
        uint256 balance;
        Receipt receipt;
        mapping(address => address[]) approvedAccount;
    }

    struct PoolData {
        string name;
        string symbol;
        // TODO: merge sell and buy price, set spread
        uint256 buyPrice;   // initially 1e18 = 1 ether
        uint256 sellPrice;  // initially 1e18 = 1 ether
        uint256 totalSupply;
        uint256 transactionFee; // in basis points 1 = 0.01%
        uint32 minPeriod;
    }

    struct Admin {
        uint256 ratio;  // initial ratio is 80%
        address feeCollector;
        address kycProvider;
        bool kycEnforced;
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

    // TODO: do not inline when reading immutables as they are copied anywhere
    //  the modifier is used, rather call to private/internal method.
    modifier minimumStake(uint256 amount) {
        require (
            amount >= MINIMUM_ORDER,
            "POOL_AMOUNT_SMALLER_THAN_MINIMUM_ERROR"
        );
        _;
    }

    modifier hasEnough(uint256 _amount) {
        require(
            accounts[msg.sender].balance >= _amount,
            "101"
        );
        _;
    }

    modifier positiveAmount(uint256 _amount) {
        require(
            accounts[msg.sender].balance + _amount > accounts[msg.sender].balance,
            "102"
        );
        _;
    }

    modifier minimumPeriodPast() {
        require(
            block.timestamp >= accounts[msg.sender].receipt.activation,
            "103"
        );
        _;
    }

    modifier buyPriceHigherOrEqual(uint256 _sellPrice, uint256 _buyPrice) {
        require(
            _sellPrice <= _buyPrice,
            "104"
        );
        _;
    }

    // TODO: fix and move to nav verifier
    modifier notPriceError(uint256 _sellPrice, uint256 _buyPrice) {
        require(
            _sellPrice > _getSellPrice() / 10 && _buyPrice < _getBuyPrice() * 10,
            "105"
        );
        _;
    }

    // owner is initialized to 0 to lock owner actions in this implementation.
    // kycEnforced set to true as will prevent mint/burn actions, effectively
    // making this implementation unusable by itself.
    constructor(address _authority, address _rigoblockDao) {
        AUTHORITY = _authority;
        RIGOBLOCK_DAO = _rigoblockDao;
        _implementation = address(this);
        // must lock implementation after initializing _implementation
        owner = address(0);
        admin.kycEnforced == true;
    }

    /*
     * CORE FUNCTIONS
     */
    // permission of methods that change state are checked in the target adapter
    //  effectively locking direct calls to this implementation contract.
    fallback() external payable {
        address adapter = _getApplicationAdapter(msg.sig);
        // we check that the method is approved by governance
        require(adapter != address(0), "POOL_METHOD_NOT_ALLOWED_ERROR");

        // perform a delegatecall to extension
        // msg.sender permission must be checked at single extension method level
        assembly {
            calldatacopy(0, 0, calldatasize())
            let success := delegatecall(gas(), adapter, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
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
        string memory _poolName,
        string memory _poolSymbol,
        address _owner
    )
        onlyUninitialized
        external
        override
    {
        poolData.name = _poolName;
        poolData.symbol = _poolSymbol;
        owner = _owner;

        emit PoolInitialized(msg.sender, _owner, _poolName, _poolSymbol);
    }

    /// @dev Allows a user to mint pool tokens.
    /// @return Value of minted tokens.
    // TODO merge with following, as holder can just mint for himself
    function mint()
        external
        payable
        minimumStake(msg.value)
        returns (uint256)
    {
        return _mint(msg.sender);
    }

    /// @dev Allows a user to mint pool tokens on behalf of an address.
    /// @param _hodler Address of the target user.
    /// @return Value of minted tokens.
    function mintOnBehalf(address _hodler)
        external
        payable
        minimumStake(msg.value)
        returns (uint256)
    {
        return _mint(_hodler);
    }

    /// @dev Allows a pool holder to burn pool tokens.
    /// @param _amount Number of tokens to burn.
    /// @return Bool the function executed correctly.
    function burn(uint256 _amount)
        external
        nonReentrant
        hasEnough(_amount)
        positiveAmount(_amount)
        minimumPeriodPast
        returns (uint256)
    {
        (
            uint256 feePool,
            uint256 feeRigoblockDao,
            uint256 netAmount,
            uint256 netRevenue
        ) = _getBurnAmounts(_amount);

        _allocateBurnTokens(msg.sender, _amount, feePool, feeRigoblockDao);
        poolData.totalSupply -= netAmount;
        payable(msg.sender).transfer(netRevenue);
        emit Burn(msg.sender, address(this), _amount, netRevenue, bytes(poolData.name), bytes(poolData.symbol));
        return netRevenue;
    }

    /// @dev Allows pool owner to set the pool price.
    /// @param _newSellPrice Price in wei.
    /// @param _newBuyPrice Price in wei.
    /// @param _signaturevaliduntilBlock Number of blocks till expiry of new poolData.
    /// @param _hash Bytes32 of the transaction hash.
    /// @param _signedData Bytes of extradata and signature.
    function setPrices(
        uint256 _newSellPrice,
        uint256 _newBuyPrice,
        uint256 _signaturevaliduntilBlock,
        bytes32 _hash,
        bytes calldata _signedData)
        external
        nonReentrant
        onlyOwner
        buyPriceHigherOrEqual(_newSellPrice, _newBuyPrice)
        notPriceError(_newSellPrice, _newBuyPrice)
    {
        require(
            _isValidNav(
                _newSellPrice,
                _newBuyPrice,
                _signaturevaliduntilBlock,
                _hash,
                _signedData
            ),
            "POOL_NAV_NOT_VALID_ERROR"
        );
        poolData.sellPrice = _newSellPrice;
        poolData.buyPrice = _newBuyPrice;
        emit NewNav(msg.sender, address(this), _newSellPrice, _newBuyPrice);
    }

    /// @dev Allows pool owner to change fee split ratio between fee collector and Dao.
    /// @param _ratio Number of ratio for fee collector, from 0 to 100.
    // TODO: this method should be delegated to DAO and universal for all pools.
    function changeRatio(uint256 _ratio)
        external
        onlyOwner
    {
        require(
            _ratio != uint256(0),
            "POOL_RATIO_NULL_ERROR"
        );
        admin.ratio = _ratio;
        emit NewRatio(msg.sender, address(this), _ratio);
    }

    /// @dev Allows pool owner to set the transaction fee.
    /// @param _transactionFee Value of the transaction fee in basis points.
    function setTransactionFee(uint256 _transactionFee)
        external
        onlyOwner
    {
        require(
            _transactionFee <= 100,
            "POOL_FEE_HIGHER_THAN_ONE_PERCENT_ERROR"
            ); //fee cannot be higher than 1%
        poolData.transactionFee = _transactionFee;
        emit NewFee(msg.sender, address(this), _transactionFee);
    }

    /// @dev Allows owner to decide where to receive the fee.
    /// @param _feeCollector Address of the fee receiver.
    function changeFeeCollector(address _feeCollector)
        external
        onlyOwner
    {
        admin.feeCollector = _feeCollector;
        emit NewCollector(msg.sender, address(this), _feeCollector);
    }

    /// @dev Allows pool owner to change the minimum holding period.
    /// @param _minPeriod Time in seconds.
    function changeMinPeriod(uint32 _minPeriod)
        external
        onlyOwner
    {
        require(
            _minPeriod <= 15 days,
            "POOL_LOCKUP_LONGER_THAN_15_DAYS_ERROR"
        );
        poolData.minPeriod = _minPeriod;
    }

    function enforceKyc(
        bool _enforced,
        address _kycProvider)
        external
        onlyOwner
    {
        admin.kycEnforced = _enforced;
        admin.kycProvider = _kycProvider;
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
        return accounts[_who].balance;
    }

    /// @dev Finds details of this pool.
    /// @return poolName String name of this pool.
    /// @return poolSymbol String symbol of this pool.
    /// @return Value of the token price in wei.
    /// @return Value of the token price in wei.
    function getData()
        external
        view
        returns (
            string memory poolName,
            string memory poolSymbol,
            uint256,    // sellPrice
            uint256     // buyPrice
        )
    {
        return(
            poolName = poolData.name,
            poolSymbol = poolData.symbol,
            _getSellPrice(),
            _getBuyPrice()
        );
    }

    /// @dev Returns the price of a pool.
    /// @return Value of the token price in wei.
    function calcTokenPrice()
        external
        view
        returns (uint256)
    {
        return _getSellPrice();
    }

    /// @dev Finds the administrative data of the pool.
    /// @return Address of the owner.
    /// @return feeCollector Address of the account where a user collects fees.
    /// @return Address of the Rigoblock DAO.
    /// @return Number of the fee split ratio.
    /// @return transactionFee Value of the transaction fee in basis points.
    /// @return minPeriod Number of the minimum holding period for tokens.
    function getAdminData()
        external
        view
        returns (
            address,  //owner
            address feeCollector,
            address,  // rigoblockDao
            uint256,  // ratio
            uint256 transactionFee,
            uint32 minPeriod
        )
    {
        return (
            owner,
            admin.feeCollector,
            RIGOBLOCK_DAO,
            _getRatio(),
            poolData.transactionFee,
            poolData.minPeriod
        );
    }

    function getExtensionsAuthority()
        external
        view
        returns (address)
    {
        return _getExtensionsAuthority();
    }

    function getKycProvider()
        external
        view
        returns (address kycProviderAddress)
    {
        if(admin.kycEnforced) {
            return kycProviderAddress = admin.kycProvider;
        }
    }

    /// @dev Returns the total amount of issued tokens for this pool.
    /// @return Number of tokens.
    function totalSupply()
        external view
        returns (uint256)
    {
        return poolData.totalSupply;
    }

    function name()
        external
        view
        override
        returns (string memory)
    {
        return poolData.name;
    }

    function symbol()
        external
        view
        override
        returns (string memory)
    {
        return poolData.symbol;
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

    /// @dev Executes the pool purchase.
    /// @param _hodler Address of the target user.
    /// @return Value of minted tokens.
    function _mint(address _hodler)
        internal
        returns (uint256)
    {
        // require whitelisted user if kyc is enforced
        if (admin.kycEnforced == true) {
            require(
                Kyc(admin.kycProvider).isWhitelistedUser(_hodler),
                "POOL_CALLER_NOT_WHITELISTED_ERROR"
            );
        }

        (
            uint256 grossAmount,
            uint256 feePool,
            uint256 feeRigoblockDao,
            uint256 amount
        ) = _getMintAmounts();

        _allocateMintTokens(_hodler, amount, feePool, feeRigoblockDao);

        require(
            amount > uint256(0),
            "POOL_MINT_RETURNED_AMOUNT_NULL_ERROR"
        );

        poolData.totalSupply += grossAmount;
        // TODO: save space, we are returning pool address in event
        emit Mint(msg.sender, address(this), _hodler, msg.value, amount);
        return amount;
    }

    /// @dev Allocates tokens to buyer, splits fee in tokens to wizard and dao.
    /// @param _hodler Address of the buyer.
    /// @param _amount Value of issued tokens.
    /// @param _feePool Number of tokens as fee.
    /// @param _feeRigoblockDao Number of tokens as fee to dao.
    function _allocateMintTokens(
        address _hodler,
        uint256 _amount,
        uint256 _feePool,
        uint256 _feeRigoblockDao)
        internal
    {
        accounts[_hodler].balance = accounts[_hodler].balance + _amount;
        if (_feePool != uint256(0)) {
            // TODO: test
            address feeCollector = admin.feeCollector != address(0) ? admin.feeCollector : owner;
            accounts[feeCollector].balance = accounts[feeCollector].balance + _feePool;
            accounts[RIGOBLOCK_DAO].balance = accounts[RIGOBLOCK_DAO].balance + _feeRigoblockDao;
        }
        unchecked { accounts[_hodler].receipt.activation = uint32(block.timestamp) + poolData.minPeriod; }
    }

    /// @dev Destroys tokens of seller, splits fee in tokens to wizard and dao.
    /// @param _hodler Address of the seller.
    /// @param _amount Value of burnt tokens.
    /// @param _feePool Number of tokens as fee.
    /// @param _feeRigoblockDao Number of tokens as fee to dao.
    function _allocateBurnTokens(
        address _hodler,
        uint256 _amount,
        uint256 _feePool,
        uint256 _feeRigoblockDao)
        internal
    {
        accounts[_hodler].balance = accounts[_hodler].balance - _amount;
        if (_feePool != uint256(0)) {
            address feeCollector = admin.feeCollector != address(0) ? admin.feeCollector : owner;
            accounts[feeCollector].balance = accounts[feeCollector].balance + _feePool;
            accounts[RIGOBLOCK_DAO].balance = accounts[RIGOBLOCK_DAO].balance + _feeRigoblockDao;
        }
    }

    /// @dev Calculates the correct purchase amounts.
    /// @return grossAmount Number of new tokens.
    /// @return feePool Value of fee in tokens.
    /// @return feeRigoblockDao Value of fee in tokens to dao.
    /// @return amount Value of net minted tokens.
    function _getMintAmounts()
        internal
        view
        returns (
            uint256 grossAmount,
            uint256 feePool,
            uint256 feeRigoblockDao,
            uint256 amount
        )
    {
        grossAmount = msg.value * decimals / _getBuyPrice();
        uint256 fee; // fee is in basis points

        if (poolData.transactionFee != uint256(0)) {
            fee = grossAmount * poolData.transactionFee / 10000;
            // TODO: check if ratio returned correctly
            feePool = fee * _getRatio() / 100;
            feeRigoblockDao = fee - feePool;
            amount = grossAmount - fee;
        } else {
            feePool = uint256(0);
            feeRigoblockDao = uint256(0);
            amount = grossAmount;
        }
    }

    function _getBuyPrice() internal view returns (uint256) {
        if (poolData.buyPrice == uint256(0)) {
            return INITIAL_BUY_PRICE;
        } else return poolData.buyPrice;
    }

    function _getSellPrice() internal view returns (uint256) {
        if (poolData.sellPrice == uint256(0)) {
            return INITIAL_SELL_PRICE;
        } else return poolData.sellPrice;
    }

    function _getRatio() private view returns (uint256) {
        if (admin.ratio == uint256(0)) {
            return INITIAL_RATIO;
        } else return admin.ratio;
    }

    /// @dev Calculates the correct sale amounts.
    /// @return feePool Value of fee in tokens.
    /// @return feeRigoblockDao Value of fee in tokens to dao.
    /// @return netAmount Value of net burnt tokens.
    /// @return netRevenue Value of revenue for hodler.
    function _getBurnAmounts(uint256 _amount)
        internal
        view
        returns (
            uint256 feePool,
            uint256 feeRigoblockDao,
            uint256 netAmount,
            uint256 netRevenue
        )
    {
        uint256 fee = _amount * poolData.transactionFee / 10000; //fee is in basis points
        return (
            feePool = fee * _getRatio() / 100,
            feeRigoblockDao = fee - feeRigoblockDao,
            netAmount = _amount - fee,
            netRevenue = netAmount * _getSellPrice() / decimals
        );
    }

    /// @dev Verifies that a signature is valid.
    /// @param _sellPrice Price in wei.
    /// @param _buyPrice Price in wei.
    /// @param _signaturevaliduntilBlock Number of blocks till price expiry.
    /// @param _hash Message hash that is signed.
    /// @param _signedData Proof of nav validity.
    /// @return isValid Bool validity of signed price update.
    function _isValidNav(
        uint256 _sellPrice,
        uint256 _buyPrice,
        uint256 _signaturevaliduntilBlock,
        bytes32 _hash,
        bytes memory _signedData)
        internal
        view
        returns (bool)
    {
        // TODO: check if we can define isValidNav internal virtual and
        //  simplify following statement.
        return NavVerifier(address(this)).isValidNav(
            _sellPrice,
            _buyPrice,
            _signaturevaliduntilBlock,
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
        return ExtensionsAuthority(
            _getExtensionsAuthority()
        ).getApplicationAdapter(_selector);
    }

    function _checkDelegateCall() private view {
        require(
            address(this) != _implementation,
            "POOL_IMPLEMENTATION_DIRECT_CALL_NOT_ALLOWED_ERROR"
        );
    }

    /// @dev Finds the extensions authority.
    /// @return Address of the extensions authority.
    // TODO: check under what circumstances we call this method, as can
    //  initialize externsions authority address as well as authority, and skip
    //  1 read operation in this call. Governance must upgrade implementation
    //   when it upgrades extensions authority.
    function _getExtensionsAuthority()
        private
        view
        returns (address)
    {
        return Authority(AUTHORITY).getExtensionsAuthority();
    }
}
