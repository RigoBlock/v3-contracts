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

pragma solidity 0.5.0;

/// @title Drago Eventful Interface contract.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
interface DragoEventfulFace {

    /*
     * EVENTS
     */
    event BuyDrago(address indexed drago, address indexed from, address indexed to, uint256 amount, uint256 revenue, bytes name, bytes symbol);
    event SellDrago(address indexed drago, address indexed from, address indexed to, uint256 amount, uint256 revenue, bytes name, bytes symbol);
    event NewRatio(address indexed drago, address indexed from, uint256 newRatio);
    event NewNAV(address indexed drago, address indexed from, address indexed to, uint256 sellPrice, uint256 buyPrice);
    event NewFee(address indexed drago, address indexed group, address indexed who, uint256 transactionFee);
    event NewCollector( address indexed drago, address indexed group, address indexed who, address feeCollector);
    event DragoDao(address indexed drago, address indexed from, address indexed to, address dragoDao);
    event DepositExchange(address indexed drago, address indexed exchange, address indexed token, uint256 value, uint256 amount);
    event WithdrawExchange(address indexed drago, address indexed exchange, address indexed token, uint256 value, uint256 amount);
    event OrderExchange(address indexed drago, address indexed exchange, address indexed cfd, uint256 value, uint256 revenue);
    event TradeExchange(address indexed drago, address indexed exchange, address tokenGet, address tokenGive, uint256 amountGet, uint256 amountGive, address get);
    event CancelOrder(address indexed drago, address indexed exchange, address indexed cfd, uint256 value, uint256 id);
    event DealFinalized(address indexed drago, address indexed exchange, address indexed cfd, uint256 value, uint256 id);
    event CustomDragoLog(bytes4 indexed methodHash, bytes encodedParams);
    event CustomDragoLog2(bytes4 indexed methodHash,  bytes32 topic2, bytes32 topic3, bytes encodedParams);
    event DragoCreated(address indexed drago, address indexed group, address indexed owner, uint256 dragoId, string name, string symbol);

    /*
     * CORE FUNCTIONS
     */
    function buyDrago(address _who, address _targetDrago, uint256 _value, uint256 _amount, bytes calldata _name, bytes calldata _symbol) external returns (bool success);
    function sellDrago(address _who, address _targetDrago, uint256 _amount, uint256 _revenue, bytes calldata _name, bytes calldata _symbol) external returns(bool success);
    function changeRatio(address _who, address _targetDrago, uint256 _ratio) external returns(bool success);
    function changeFeeCollector(address _who, address _targetDrago, address _feeCollector) external returns(bool success);
    function changeDragoDao(address _who, address _targetDrago, address _dragoDao) external returns(bool success);
    function setDragoPrice(address _who, address _targetDrago, uint256 _sellPrice, uint256 _buyPrice) external returns(bool success);
    function setTransactionFee(address _who, address _targetDrago, uint256 _transactionFee) external returns(bool success);
    function depositToExchange(address _who, address _targetDrago, address _exchange, address _token, uint256 _value) external returns(bool success);
    function withdrawFromExchange(address _who, address _targetDrago, address _exchange, address _token, uint256 _value) external returns(bool success);
    function customDragoLog(bytes4 _methodHash, bytes calldata _encodedParams) external returns (bool success);
    function customDragoLog2(bytes4 _methodHash, bytes32 topic2, bytes32 topic3, bytes calldata _encodedParams) external returns (bool success);
    function customExchangeLog(bytes4 _methodHash, bytes calldata _encodedParams) external returns (bool success);
    function customExchangeLog2(bytes4 _methodHash, bytes32 topic2, bytes32 topic3,bytes calldata _encodedParams) external returns (bool success);
    function createDrago(address _who, address _newDrago, string calldata _name, string calldata _symbol, uint256 _dragoId) external returns(bool success);
}
