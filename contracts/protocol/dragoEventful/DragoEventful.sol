// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2017-2018 RigoBlock, Rigo Investment Sagl.

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

import { IAuthority as Authority } from "../interfaces/IAuthority.sol";
import { IExchangesAuthority as DexAuth } from "../interfaces/IExchangesAuthority.sol";
import { IDragoEventful } from "../interfaces/IDragoEventful.sol";

/// @title Drago Eventful contract.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
contract DragoEventful is IDragoEventful {

    string public constant VERSION = 'DH0.4.2';

    address public AUTHORITY;

    modifier approvedFactoryOnly(address _factory) {
        Authority auth = Authority(AUTHORITY);
        require(auth.isWhitelistedFactory(_factory));
        _;
    }

    modifier approvedDragoOnly(address _drago) {
        Authority auth = Authority(AUTHORITY);
        require(auth.isWhitelistedDrago(_drago));
        _;
    }

    modifier approvedExchangeOnly(address _exchange) {
        Authority auth = Authority(AUTHORITY);
        require(
            DexAuth(auth.getExchangesAuthority())
                .isWhitelistedExchange(_exchange));
        _;
    }

    modifier approvedUserOnly(address _user) {
        Authority auth = Authority(AUTHORITY);
        require(auth.isWhitelistedUser(_user));
        _;
    }

    modifier approvedAsset(address _asset) {
        Authority auth = Authority(AUTHORITY);
        require(
            DexAuth(auth.getExchangesAuthority())
                .isWhitelistedAsset(_asset));
        _;
    }

    constructor(address _authority) {
        AUTHORITY = _authority;
    }

    /*
     * CORE FUNCTIONS
     */
    /// @dev Logs a Buy Drago event.
    /// @param _who Address of who is buying
    /// @param _targetDrago Address of the target drago
    /// @param _value Value of the transaction in Ether
    /// @param _amount Number of shares purchased
    /// @return Bool the transaction executed successfully
    function buyDrago(
        address _who,
        address _targetDrago,
        uint256 _value,
        uint256 _amount,
        bytes calldata _name,
        bytes calldata _symbol
    )
        external
        approvedDragoOnly(msg.sender)
        returns (bool)
    {
        buyDragoInternal(
            _targetDrago,
            _who,
            msg.sender,
            _value,
            _amount,
            _name,
            _symbol
        );
        return true;
    }

    /// @dev Logs a Sell Drago event.
    /// @param _who Address of who is selling
    /// @param _targetDrago Address of the target drago
    /// @param _amount Number of shares purchased
    /// @param _revenue Value of the transaction in Ether
    /// @return success Bool the transaction executed successfully
    function sellDrago(
        address _who,
        address _targetDrago,
        uint256 _amount,
        uint256 _revenue,
        bytes calldata _name,
        bytes calldata _symbol
    )
        external
        approvedDragoOnly(msg.sender)
        returns(bool)
    {
        require(_amount > 0);
        sellDragoInternal(
            _targetDrago,
            _who,
            msg.sender,
            _amount,
            _revenue,
            _name,
            _symbol
        );
        return true;
    }

    /// @dev Logswhen rigoblock dao changes fee split.
    /// @param _who Address of the caller
    /// @param _targetDrago Address of the target drago
    /// @param _ratio Ratio number from 0 to 100
    /// @return Bool the transaction executed successfully
    function changeRatio(
        address _who,
        address _targetDrago,
        uint256 _ratio
    )
        external
        approvedDragoOnly(msg.sender)
        returns(bool)
    {
        require(_ratio > 0);
        emit NewRatio(_targetDrago, _who, _ratio);
        return true;
    }

    /// @dev Logs when wizard changes fee collector address
    /// @param _who Address of the caller
    /// @param _targetDrago Address of the target Drago
    /// @param _feeCollector Address of the new fee collector
    /// @return Bool the transaction executed successfully
    function changeFeeCollector(
        address _who,
        address _targetDrago,
        address _feeCollector)
        external
        approvedDragoOnly(msg.sender)
        approvedUserOnly(_who)
        returns(bool)
    {
        emit NewCollector(_targetDrago, msg.sender, _who, _feeCollector);
        return true;
    }

    /// @dev Logs a change in the drago dao of an approved vault
    /// @param _who Address of the caller
    /// @param _targetDrago Address of the drago
    /// @param _dragoDao Address of the new drago dao
    /// @return Bool the transaction executed successfully
    function changeDragoDao(
        address _who,
        address _targetDrago,
        address _dragoDao)
        external
        approvedDragoOnly(msg.sender)
        approvedUserOnly(_who)
        returns(bool)
    {
        emit DragoDao(_targetDrago, msg.sender, _who, _dragoDao);
        return true;
    }

    /// @dev Logs a Set Drago Price event
    /// @param _who Address of the caller
    /// @param _targetDrago Address of the target Drago
    /// @param _sellPrice Value of the price of one share in wei
    /// @param _buyPrice Value of the price of one share in wei
    /// @return Bool the transaction executed successfully
    function setDragoPrice(
        address _who,
        address _targetDrago,
        uint256 _sellPrice,
        uint256 _buyPrice)
        external
        approvedDragoOnly(msg.sender)
        returns(bool)
    {
        // TODO: check why we are making this check in logger contract
        // if initial price is 1ETH, whenever price goes down 99%, cannot be updated
        require(_sellPrice > 1e16 && _buyPrice > 1e16); // 1e16 = 10 finney
        emit NewNAV(_targetDrago, msg.sender, _who, _sellPrice, _buyPrice);
        return true;
    }

    /// @dev Logs a modification of the transaction fee event
    /// @param _who Address of the caller
    /// @param _targetDrago Address of the target Drago
    /// @param _transactionFee Value of the transaction fee in basis points
    /// @return Bool the transaction executed successfully
    function setTransactionFee(
        address _who,
        address _targetDrago,
        uint256 _transactionFee)
        external
        approvedDragoOnly(msg.sender)
        approvedUserOnly(_who)
        returns(bool)
    {
        emit NewFee(_targetDrago, msg.sender, _who, _transactionFee);
        return true;
    }

    /// @dev Logs a Drago Deposit To Exchange event
    /// @param _who Address of the caller
    /// @param _targetDrago Address of the target Drago
    /// @param _exchange Address of the exchange
    /// @param _token Address of the deposited token
    /// @param _value Number of deposited tokens
    /// @return Bool the transaction executed successfully
    function depositToExchange(
        address _who,
        address _targetDrago,
        address _exchange,
        address _token,
        uint256 _value)
        external
        approvedUserOnly(_who)
        approvedDragoOnly(msg.sender)
        approvedExchangeOnly(_exchange)
        returns(bool)
    {
        emit DepositExchange(_targetDrago, _exchange, _token, _value, 0);
        return true;
    }

    /// @dev Logs a Drago Withdraw From Exchange event
    /// @param _who Address of the caller
    /// @param _targetDrago Address of the target Drago
    /// @param _exchange Address of the exchange
    /// @param _token Address of the withdrawn token
    /// @param _value Number of withdrawn tokens
    /// @return Bool the transaction executed successfully
    function withdrawFromExchange(
        address _who,
        address _targetDrago,
        address _exchange,
        address _token,
        uint256 _value)
        external
        approvedUserOnly(_who)
        approvedDragoOnly(msg.sender)
        approvedExchangeOnly(_exchange)
        returns(bool)
    {
        emit WithdrawExchange(_targetDrago, _exchange, _token, _value, 0);
        return true;
    }

    /// @dev Logs an event sent from a drago
    /// @param _methodHash the method of the call
    /// @param _encodedParams the arbitrary data array
    /// @return Bool the transaction executed successfully
    function customDragoLog(
        bytes4 _methodHash,
        bytes calldata _encodedParams)
        external
        approvedDragoOnly(msg.sender)
        returns (bool)
    {
        emit CustomDragoLog(_methodHash, _encodedParams);
        return true;
    }

    /// @dev Logs an event sent from a drago
    /// @param _methodHash the method of the call
    /// @param _encodedParams the arbitrary data array
    /// @return Bool the transaction executed successfully
    function customDragoLog2(
        bytes4 _methodHash,
        bytes32 topic2,
        bytes32 topic3,
        bytes calldata _encodedParams)
        external
        approvedDragoOnly(msg.sender)
        returns (bool)
    {
        emit CustomDragoLog2(_methodHash, topic2, topic3, _encodedParams);
        return true;
    }

    /// @dev Logs an event sent from an approved exchange
    /// @param _methodHash the method of the call
    /// @param _encodedParams the arbitrary data array
    /// @return Bool the transaction executed successfully
    function customExchangeLog(
        bytes4 _methodHash,
        bytes calldata _encodedParams)
        external
        approvedExchangeOnly(msg.sender)
        returns (bool)
    {
        emit CustomDragoLog(_methodHash, _encodedParams);
        return true;
    }

    /// @dev Logs an event sent from an approved exchange
    /// @param _methodHash the method of the call
    /// @param _encodedParams the arbitrary data array
    /// @return Bool the transaction executed successfully
    function customExchangeLog2(
        bytes4 _methodHash,
        bytes32 topic2,
        bytes32 topic3,
        bytes calldata _encodedParams)
        external
        approvedExchangeOnly(msg.sender)
        returns (bool)
    {
        emit CustomDragoLog2(_methodHash, topic2, topic3, _encodedParams);
        return true;
    }

    /// @dev Logs a new Drago creation by factory
    /// @param _who Address of the caller
    /// @param _newDrago Address of the new Drago
    /// @param _name String of the name of the new drago
    /// @param _symbol String of the symbol of the new drago
    /// @param _dragoId Number of the new drago Id
    /// @return Bool the transaction executed successfully
    function createDrago(
        address _who,
        address _newDrago,
        string calldata _name,
        string calldata _symbol,
        uint256 _dragoId)
        external
        approvedFactoryOnly(msg.sender)
        returns(bool)
    {
        createDragoInternal(_newDrago, msg.sender, _who, _dragoId, _name, _symbol);
        return true;
    }

    /*
     * INTERNAL FUNCTIONS
     */
    /// @dev Logs a purchase event
    /// @param _who Address of the caller
    /// @param _targetDrago Address of the drago
    /// @param _factory Address of the factory
    /// @param _value Value of transaction in wei
    /// @param _amount Number of new tokens
    /// @param _name Hex encoded bytes of the name
    /// @param _symbol Hex encoded bytes of the symbol
    function buyDragoInternal(
        address _targetDrago,
        address _who,
        address _factory,
        uint256 _value,
        uint256 _amount,
        bytes memory _name,
        bytes memory _symbol)
        internal
    {
        emit BuyDrago(_targetDrago, _who, _factory, _value, _amount, _name, _symbol);
    }

    /// @dev Logs a sale event
    /// @param _who Address of the caller
    /// @param _targetDrago Address of the drago
    /// @param _factory Address of the factory
    /// @param _amount Number of burnt tokens
    /// @param _revenue Value of transaction in wei
    /// @param _name Hex encoded bytes of the name
    /// @param _symbol Hex encoded bytes of the symbol
    function sellDragoInternal(
        address _targetDrago,
        address _who,
        address _factory,
        uint256 _amount,
        uint256 _revenue,
        bytes memory _name,
        bytes memory _symbol)
        internal
    {
        emit SellDrago(_targetDrago, _who, _factory, _amount, _revenue, _name, _symbol);
    }

    /// @dev Logs a new drago creation by factory
    /// @param _who Address of the caller
    /// @param _newDrago Address of the new drago
    /// @param _factory Address of the factory
    /// @param _name Bytes array of the name
    /// @param _symbol Bytes array of the symbol
    /// @param _dragoId Number of the pool in registry
    function createDragoInternal(
        address _newDrago,
        address _factory,
        address _who,
        uint256 _dragoId,
        string memory _name,
        string memory _symbol)
        internal
    {
        emit DragoCreated(_newDrago, _factory, _who, _dragoId, _name, _symbol);
    }
}
