// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0;

interface IRigoblockV3PoolOwnerActions {
    function setUnitaryValue(
        uint256 _unitaryValue,
        uint256 _signaturevaliduntilBlock,
        bytes32 _hash,
        bytes calldata _signedData
    ) external;

    function changeMinPeriod(uint32 _minPeriod) external;

    function changeSpread(uint256 _newSpread) external;

    function setTransactionFee(uint256 _transactionFee) external;

    function changeFeeCollector(address _feeCollector) external;

    function setKycProvider(address _kycProvider) external;
}
