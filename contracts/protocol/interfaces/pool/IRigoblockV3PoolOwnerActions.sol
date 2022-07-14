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

    function changeRatio(uint256 _ratio)
        external;

    function enforceKyc(bool _enforced, address _kycProvider)
        external;
}
