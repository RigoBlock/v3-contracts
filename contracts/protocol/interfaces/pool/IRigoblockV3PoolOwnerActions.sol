// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0;

interface IRigoblockV3PoolOwnerActions {

    function setPrices(
        uint256 _newSellPrice,
        uint256 _newBuyPrice,
        uint256 _signaturevaliduntilBlock,
        bytes32 _hash,
        bytes calldata _signedData
    )
        external;

    function changeMinPeriod(uint32 _minPeriod)
        external;

    
    function setTransactionFee(uint256 _transactionFee)
        external;

    function changeFeeCollector(address _feeCollector)
        external;
    
    function setAllowance(
        address _tokenTransferProxy,
        address _token,
        uint256 _amount
    )
        external;

    function setMultipleAllowances(
        address _tokenTransferProxy,
        address[] calldata _tokens,
        uint256[] calldata _amounts
    )
        external;

    struct Transaction {
        bytes assembledData;
    }

    function operateOnExchange(address _exchange, Transaction memory transaction)
        external
        returns (bool success);

    function batchOperateOnExchange(address _exchange, Transaction[] memory transactions) external;
}