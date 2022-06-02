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
pragma experimental ABIEncoderV2;

import { AuthorityFace as Authority } from "../authorities/Authority/AuthorityFace.sol";
import { ExchangesAuthorityFace as ExchangesAuthority } from "../authorities/ExchangesAuthority/ExchangesAuthorityFace.sol";
import { SigVerifierFace as SigVerifier } from "../extensions/SigVerifier/SigVerifierFace.sol";
import { NavVerifierFace as NavVerifier } from "../extensions/NavVerifier/NavVerifierFace.sol";
import { KycFace as Kyc } from "../Kyc/KycFace.sol";
import { DragoEventfulFace as DragoEventful } from "../DragoEventful/DragoEventfulFace.sol";
import { ERC20Face as Token } from "../../tokens/ERC20/ERC20Face.sol";
import { ReentrancyGuard } from "../../utils/ReentrancyGuard//ReentrancyGuard.sol";
import { OwnedUninitialized as Owned } from "../../utils/Owned/OwnedUninitialized.sol";
import { SafeMathLight as SafeMath } from "../../utils/SafeMath/SafeMathLight.sol";
import { LibFindMethod } from "../../utils/LibFindMethod/LibFindMethod.sol";

/// @title Drago - A set of rules for a drago.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
contract Drago is Owned, SafeMath, ReentrancyGuard {

    using LibFindMethod for *;

    string constant VERSION = 'HF 0.5.2';
    uint256 constant BASE = 1000000; // tokens are divisible by 1 million

    mapping (address => Account) accounts;

    DragoData data;
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

    struct Transaction {
        bytes assembledData;
    }

    struct DragoData {
        string name;
        string symbol;
        uint256 dragoId;
        uint256 totalSupply;
        uint256 sellPrice;
        uint256 buyPrice;
        uint256 transactionFee; // in basis points 1 = 0.01%
        uint32 minPeriod;
    }

    struct Admin {
        address authority;
        address dragoDao;
        address feeCollector;
        address kycProvider;
        bool kycEnforced;
        uint256 minOrder; // minimum stake to avoid dust clogging things up
        uint256 ratio; // ratio is 80%
    }

    modifier onlyDragoDao() {
        require(msg.sender == admin.dragoDao);
        _;
    }

    modifier onlyOwnerOrAuthority() {
        Authority auth = Authority(admin.authority);
        require(auth.isAuthority(msg.sender) || msg.sender == owner);
        _;
    }

    modifier whenApprovedExchangeOrWrapper(address _target) {
        bool approvedExchange = ExchangesAuthority(getExchangesAuthority())
            .isWhitelistedExchange(_target);
        bool approvedWrapper = ExchangesAuthority(getExchangesAuthority())
            .isWhitelistedWrapper(_target);
        require(approvedWrapper || approvedExchange);
        _;
    }

    modifier whenApprovedProxy(address _proxy) {
        bool approved = ExchangesAuthority(getExchangesAuthority())
            .isWhitelistedProxy(_proxy);
        require(approved);
        _;
    }

    modifier minimumStake(uint256 amount) {
        require (amount >= admin.minOrder);
        _;
    }

    modifier hasEnough(uint256 _amount) {
        require(accounts[msg.sender].balance >= _amount);
        _;
    }

    modifier positiveAmount(uint256 _amount) {
        require(accounts[msg.sender].balance + _amount > accounts[msg.sender].balance);
        _;
    }

    modifier minimumPeriodPast() {
        require(block.timestamp >= accounts[msg.sender].receipt.activation);
        _;
    }

    modifier buyPriceHigherOrEqual(uint256 _sellPrice, uint256 _buyPrice) {
        require(_sellPrice <= _buyPrice);
        _;
    }

    modifier notPriceError(uint256 _sellPrice, uint256 _buyPrice) {
        if (_sellPrice <= data.sellPrice / 10 || _buyPrice >= data.buyPrice * 10) return;
        _;
    }

    constructor(
        string memory _dragoName,
        string memory _dragoSymbol,
        uint256 _dragoId,
        address _owner,
        address _authority)
        public
    {
        data.name = _dragoName;
        data.symbol = _dragoSymbol;
        data.dragoId = _dragoId;
        data.sellPrice = 1 ether;
        data.buyPrice = 1 ether;
        owner = _owner;
        admin.authority = _authority;
        admin.dragoDao = msg.sender;
        admin.minOrder = 1 finney;
        admin.feeCollector = _owner;
        admin.ratio = 80;
    }

    /*
     * CORE FUNCTIONS
     */
    /// @dev Allows Ether to be received.
    /// @notice Used for settlements and withdrawals.
    function()
        external
        payable
    {
        require(msg.value != 0);
    }

    /// @dev Allows a user to buy into a drago.
    /// @return Bool the function executed correctly.
    function buyDrago()
        external
        payable
        minimumStake(msg.value)
        returns (bool success)
    {
        require(buyDragoInternal(msg.sender));
        return true;
    }

    /// @dev Allows a user to buy into a drago on behalf of an address.
    /// @param _hodler Address of the target user.
    /// @return Bool the function executed correctly.
    function buyDragoOnBehalf(address _hodler)
        external
        payable
        minimumStake(msg.value)
        returns (bool success)
    {
        require(buyDragoInternal(_hodler));
        return true;
    }

    /// @dev Allows a user to sell from a drago.
    /// @param _amount Number of shares to sell.
    /// @return Bool the function executed correctly.
    function sellDrago(uint256 _amount)
        external
        nonReentrant
        hasEnough(_amount)
        positiveAmount(_amount)
        minimumPeriodPast
        returns (bool success)
    {
        uint256 feeDrago;
        uint256 feeDragoDao;
        uint256 netAmount;
        uint256 netRevenue;
        (feeDrago, feeDragoDao, netAmount, netRevenue) = getSaleAmounts(_amount);
        addSaleLog(_amount, netRevenue);
        allocateSaleTokens(msg.sender, _amount, feeDrago, feeDragoDao);
        data.totalSupply = safeSub(data.totalSupply, netAmount);
        msg.sender.transfer(netRevenue);
        return true;
    }

    /// @dev Allows drago owner or authority to set the price for a drago.
    /// @param _newSellPrice Price in wei.
    /// @param _newBuyPrice Price in wei.
    /// @param _signaturevaliduntilBlock Number of blocks till expiry of new data.
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
        onlyOwnerOrAuthority
        buyPriceHigherOrEqual(_newSellPrice, _newBuyPrice)
        notPriceError(_newSellPrice, _newBuyPrice)
    {
        require(
            isValidNav(
                _newSellPrice,
                _newBuyPrice,
                _signaturevaliduntilBlock,
                _hash,
                _signedData
            )
        );
        DragoEventful events = DragoEventful(getDragoEventful());
        require(events.setDragoPrice(msg.sender, address(this), _newSellPrice, _newBuyPrice));
        data.sellPrice = _newSellPrice;
        data.buyPrice = _newBuyPrice;
    }

    /// @dev Allows drago dao/factory to change fee split ratio.
    /// @param _ratio Number of ratio for wizard, from 0 to 100.
    function changeRatio(uint256 _ratio)
        external
        onlyDragoDao
    {
        DragoEventful events = DragoEventful(getDragoEventful());
        require(events.changeRatio(msg.sender, address(this), _ratio));
        admin.ratio = _ratio;
    }

    /// @dev Allows drago owner to set the transaction fee.
    /// @param _transactionFee Value of the transaction fee in basis points.
    function setTransactionFee(uint256 _transactionFee)
        external
        onlyOwner
    {
        require(_transactionFee <= 100); //fee cannot be higher than 1%
        DragoEventful events = DragoEventful(getDragoEventful());
        require(events.setTransactionFee(msg.sender, address(this), _transactionFee));
        data.transactionFee = _transactionFee;
    }

    /// @dev Allows owner to decide where to receive the fee.
    /// @param _feeCollector Address of the fee receiver.
    function changeFeeCollector(address _feeCollector)
        external
        onlyOwner
    {
        DragoEventful events = DragoEventful(getDragoEventful());
        events.changeFeeCollector(msg.sender, address(this), _feeCollector);
        admin.feeCollector = _feeCollector;
    }

    /// @dev Allows drago dao/factory to upgrade its address.
    /// @param _dragoDao Address of the new drago dao.
    function changeDragoDao(address _dragoDao)
        external
        onlyDragoDao
    {
        DragoEventful events = DragoEventful(getDragoEventful());
        require(events.changeDragoDao(msg.sender, address(this), _dragoDao));
        admin.dragoDao = _dragoDao;
    }

    /// @dev Allows drago dao/factory to change the minimum holding period.
    /// @param _minPeriod Time in seconds.
    function changeMinPeriod(uint32 _minPeriod)
        external
        onlyDragoDao
    {
        data.minPeriod = _minPeriod;
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

    /// @dev Allows owner to set an allowance to an approved token transfer proxy.
    /// @param _tokenTransferProxy Address of the proxy to be approved.
    /// @param _token Address of the token to receive allowance for.
    /// @param _amount Number of tokens approved for spending.
    function setAllowance(
        address _tokenTransferProxy,
        address _token,
        uint256 _amount)
        external
        onlyOwner
        whenApprovedProxy(_tokenTransferProxy)
    {
        require(setAllowancesInternal(_tokenTransferProxy, _token, _amount));
    }

    /// @dev Allows owner to set allowances to multiple approved tokens with one call.
    /// @param _tokenTransferProxy Address of the proxy to be approved.
    /// @param _tokens Address of the token to receive allowance for.
    /// @param _amounts Array of number of tokens to be approved.
    function setMultipleAllowances(
        address _tokenTransferProxy,
        address[] calldata _tokens,
        uint256[] calldata _amounts)
        external
        onlyOwner
        whenApprovedProxy(_tokenTransferProxy)
    {
        for (uint256 i = 0; i < _tokens.length; i++) {
            if (!setAllowancesInternal(_tokenTransferProxy, _tokens[i], _amounts[i])) continue;
        }
    }

    /// @dev Allows owner to operate on exchange through extension.
    /// @param _exchange Address of the target exchange.
    /// @param transaction ABIencoded transaction.
    function operateOnExchange(
        address _exchange,
        Transaction memory transaction)
        public
        onlyOwner
        nonReentrant
        whenApprovedExchangeOrWrapper(_exchange)
        returns (bool success)
    {
        address adapter = getExchangeAdapter(_exchange);
        bytes memory transactionData = transaction.assembledData;
        require(
            methodAllowedOnExchange(
                findMethod(transactionData),
                adapter
            )
        );

        bytes memory response;
        bool failed = true;

        assembly {

            let succeeded := delegatecall(
                sub(gas, 5000),
                adapter,
                add(transactionData, 0x20),
                mload(transactionData),
                0,
                32) // 0x0

            // load delegatecall output
            response := mload(0)
            failed := iszero(succeeded)

            switch failed
            case 1 {
                // throw if delegatecall failed
                revert(0, 0)
            }
        }

        return (success = true);
    }

    /// @dev Allows owner or approved exchange to send a transaction to exchange
    /// @dev With data of signed/unsigned transaction
    /// @param _exchange Address of the exchange
    /// @param transactions Array of ABI encoded transactions
    function batchOperateOnExchange(
        address _exchange,
        Transaction[] memory transactions)
        public
        onlyOwner
        nonReentrant
        whenApprovedExchangeOrWrapper(_exchange)
    {
        for (uint256 i = 0; i < transactions.length; i++) {
            if (!operateOnExchange(_exchange, transactions[i])) continue;
        }
    }

    /*
     * CONSTANT PUBLIC FUNCTIONS
     */
    /// @dev Calculates how many shares a user holds.
    /// @param _who Address of the target account.
    /// @return Number of shares.
    function balanceOf(address _who)
        external
        view
        returns (uint256)
    {
        return accounts[_who].balance;
    }

    /// @dev Gets the address of the logger contract.
    /// @return Address of the logger contrac.
    function getEventful()
        external
        view
        returns (address)
    {
        Authority auth = Authority(admin.authority);
        return auth.getDragoEventful();
    }

    /// @dev Finds details of a drago pool.
    /// @return String name of a drago.
    /// @return String symbol of a drago.
    /// @return Value of the share price in wei.
    /// @return Value of the share price in wei.
    function getData()
        external
        view
        returns (
            string memory name,
            string memory symbol,
            uint256 sellPrice,
            uint256 buyPrice
        )
    {
        name = data.name;
        symbol = data.symbol;
        sellPrice = data.sellPrice;
        buyPrice = data.buyPrice;
    }

    /// @dev Returns the price of a pool.
    /// @return Value of the share price in wei.
    function calcSharePrice()
        external
        view
        returns (uint256)
    {
        return data.sellPrice;
    }

    /// @dev Finds the administrative data of the pool.
    /// @return Address of the account where a user collects fees.
    /// @return Address of the drago dao/factory.
    /// @return Number of the fee split ratio.
    /// @return Value of the transaction fee in basis points.
    /// @return Number of the minimum holding period for shares.
    function getAdminData()
        external
        view
        returns (
            address, //owner
            address feeCollector,
            address dragoDao,
            uint256 ratio,
            uint256 transactionFee,
            uint32 minPeriod
        )
    {
        return (
            owner,
            admin.feeCollector,
            admin.dragoDao,
            admin.ratio,
            data.transactionFee,
            data.minPeriod
        );
    }

    function getKycProvider()
        external
        view
        returns (address)
    {
        if(admin.kycEnforced) {
            return admin.kycProvider;
        }
    }

    /// @dev Verifies that a signature is valid.
    /// @param hash Message hash that is signed.
    /// @param signature Proof of signing.
    /// @return Validity of order signature.
    function isValidSignature(
        bytes32 hash,
        bytes calldata signature
    )
        external
        view
        returns (bool isValid)
    {
        isValid = SigVerifier(getSigVerifier())
            .isValidSignature(hash, signature);
        return isValid;
    }

    /// @dev Finds the exchanges authority.
    /// @return Address of the exchanges authority.
    function getExchangesAuth()
        external
        view
        returns (address)
    {
        return getExchangesAuthority();
    }

    /// @dev Returns the total amount of issued tokens for this drago.
    /// @return Number of shares.
    function totalSupply()
        external view
        returns (uint256)
    {
        return data.totalSupply;
    }

    /*
     * INTERNAL FUNCTIONS
     */

    /// @dev Executes the pool purchase.
    /// @param _hodler Address of the target user.
    /// @return Bool the function executed correctly.
    function buyDragoInternal(address _hodler)
        internal
        returns (bool success)
    {
        if (admin.kycProvider != address(0)) {
            require(Kyc(admin.kycProvider).isWhitelistedUser(_hodler));
        }
        uint256 grossAmount;
        uint256 feeDrago;
        uint256 feeDragoDao;
        uint256 amount;
        (grossAmount, feeDrago, feeDragoDao, amount) = getPurchaseAmounts();
        addPurchaseLog(amount);
        allocatePurchaseTokens(_hodler, amount, feeDrago, feeDragoDao);
        data.totalSupply = safeAdd(data.totalSupply, grossAmount);
        return true;
    }

    /// @dev Allocates tokens to buyer, splits fee in tokens to wizard and dao.
    /// @param _hodler Address of the buyer.
    /// @param _amount Value of issued tokens.
    /// @param _feeDrago Number of shares as fee.
    /// @param _feeDragoDao Number of shares as fee to dao.
    function allocatePurchaseTokens(
        address _hodler,
        uint256 _amount,
        uint256 _feeDrago,
        uint256 _feeDragoDao)
        internal
    {
        accounts[_hodler].balance = safeAdd(accounts[_hodler].balance, _amount);
        accounts[admin.feeCollector].balance = safeAdd(accounts[admin.feeCollector].balance, _feeDrago);
        accounts[admin.dragoDao].balance = safeAdd(accounts[admin.dragoDao].balance, _feeDragoDao);
        accounts[_hodler].receipt.activation = uint32(now) + data.minPeriod;
    }

    /// @dev Destroys tokens of seller, splits fee in tokens to wizard and dao.
    /// @param _hodler Address of the seller.
    /// @param _amount Value of burnt tokens.
    /// @param _feeDrago Number of shares as fee.
    /// @param _feeDragoDao Number of shares as fee to dao.
    function allocateSaleTokens(
        address _hodler,
        uint256 _amount,
        uint256 _feeDrago,
        uint256 _feeDragoDao)
        internal
    {
        accounts[_hodler].balance = safeSub(accounts[_hodler].balance, _amount);
        accounts[admin.feeCollector].balance = safeAdd(accounts[admin.feeCollector].balance, _feeDrago);
        accounts[admin.dragoDao].balance = safeAdd(accounts[admin.dragoDao].balance, _feeDragoDao);
    }

    /// @dev Sends a buy log to the eventful contract.
    /// @param _amount Number of purchased shares.
    function addPurchaseLog(uint256 _amount)
        internal
    {
        bytes memory name = bytes(data.name);
        bytes memory symbol = bytes(data.symbol);
        Authority auth = Authority(admin.authority);
        DragoEventful events = DragoEventful(auth.getDragoEventful());
        require(events.buyDrago(msg.sender, address(this), msg.value, _amount, name, symbol));
    }

    /// @dev Sends a sell log to the eventful contract.
    /// @param _amount Number of sold shares.
    /// @param _netRevenue Value of sale for hodler.
    function addSaleLog(uint256 _amount, uint256 _netRevenue)
        internal
    {
        bytes memory name = bytes(data.name);
        bytes memory symbol = bytes(data.symbol);
        Authority auth = Authority(admin.authority);
        DragoEventful events = DragoEventful(auth.getDragoEventful());
        require(events.sellDrago(msg.sender, address(this), _amount, _netRevenue, name, symbol));
    }

    /// @dev Allows owner to set an infinite allowance to an approved exchange.
    /// @param _tokenTransferProxy Address of the proxy to be approved.
    /// @param _token Address of the token to receive allowance for.
    function setAllowancesInternal(
        address _tokenTransferProxy,
        address _token,
        uint256 _amount)
        internal
        returns (bool)
    {
        require(Token(_token)
            .approve(_tokenTransferProxy, _amount));
        return true;
    }

    /// @dev Calculates the correct purchase amounts.
    /// @return Number of new shares.
    /// @return Value of fee in shares.
    /// @return Value of fee in shares to dao.
    /// @return Value of net purchased shares.
    function getPurchaseAmounts()
        internal
        view
        returns (
            uint256 grossAmount,
            uint256 feeDrago,
            uint256 feeDragoDao,
            uint256 amount
        )
    {
        grossAmount = safeDiv(msg.value * BASE, data.buyPrice);
        uint256 fee = safeMul(grossAmount, data.transactionFee) / 10000; //fee is in basis points
        return (
            grossAmount,
            feeDrago = safeMul(fee , admin.ratio) / 100,
            feeDragoDao = safeSub(fee, feeDrago),
            amount = safeSub(grossAmount, fee)
        );
    }

    /// @dev Calculates the correct sale amounts.
    /// @return Value of fee in shares.
    /// @return Value of fee in shares to dao.
    /// @return Value of net sold shares.
    /// @return Value of sale amount for hodler.
    function getSaleAmounts(uint256 _amount)
        internal
        view
        returns (
            uint256 feeDrago,
            uint256 feeDragoDao,
            uint256 netAmount,
            uint256 netRevenue
        )
    {
        uint256 fee = safeMul(_amount, data.transactionFee) / 10000; //fee is in basis points
        return (
            feeDrago = safeMul(fee, admin.ratio) / 100,
            feeDragoDao = safeSub(fee, feeDragoDao),
            netAmount = safeSub(_amount, fee),
            netRevenue = (safeMul(netAmount, data.sellPrice) / BASE)
        );
    }

    /// @dev Gets the address of the logger contract.
    /// @return Address of the logger contrac.
    function getDragoEventful()
        internal
        view
        returns (address)
    {
        Authority auth = Authority(admin.authority);
        return auth.getDragoEventful();
    }

    /// @dev Returns the address of the signature verifier.
    /// @return Address of the verifier contract.
    function getSigVerifier()
        internal
        view
        returns (address)
    {
        return ExchangesAuthority(
            Authority(admin.authority)
            .getExchangesAuthority())
            .getSigVerifier();
    }

    /// @dev Returns the address of the price verifier.
    /// @return Address of the verifier contract.
    function getNavVerifier()
        internal
        view
        returns (address)
    {
        return Authority(admin.authority)
            .getNavVerifier();
    }

    /// @dev Verifies that a signature is valid.
    /// @param sellPrice Price in wei.
    /// @param buyPrice Price in wei.
    /// @param signaturevaliduntilBlock Number of blocks till price expiry.
    /// @param hash Message hash that is signed.
    /// @param signedData Proof of nav validity.
    /// @return Bool validity of signed price update.
    function isValidNav(
        uint256 sellPrice,
        uint256 buyPrice,
        uint256 signaturevaliduntilBlock,
        bytes32 hash,
        bytes memory signedData)
        internal
        view
        returns (bool isValid)
    {
        isValid = NavVerifier(getNavVerifier()).isValidNav(
            sellPrice,
            buyPrice,
            signaturevaliduntilBlock,
            hash,
            signedData
        );
        return isValid;
    }

    /// @dev Finds the exchanges authority.
    /// @return Address of the exchanges authority.
    function getExchangesAuthority()
        internal
        view
        returns (address)
    {
        return Authority(admin.authority).getExchangesAuthority();
    }

    /// @dev Returns the address of the exchange adapter.
    /// @param _exchange Address of the target exchange.
    /// @return Address of the exchange adapter.
    function getExchangeAdapter(address _exchange)
        internal
        view
        returns (address)
    {
        return ExchangesAuthority(
            Authority(admin.authority)
            .getExchangesAuthority())
            .getExchangeAdapter(_exchange);
    }

    /// @dev Returns the method of a call.
    /// @param assembledData Bytes of the encoded transaction.
    /// @return Bytes4 function signature.
    function findMethod(bytes memory assembledData)
        internal
        pure
        returns (bytes4 method)
    {
        return method = LibFindMethod.findMethod(assembledData);
    }

    /// @dev Finds if a method is allowed on an exchange.
    /// @param _adapter Address of the target exchange.
    /// @return Bool the method is allowed.
    function methodAllowedOnExchange(
        bytes4 _method,
        address _adapter)
        internal
        view
        returns (bool)
    {
        return ExchangesAuthority(
            Authority(admin.authority)
            .getExchangesAuthority())
            .isMethodAllowed(_method, _adapter);
    }
}
