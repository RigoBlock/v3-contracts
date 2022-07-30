// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

/// @title Rigoblock V3 Pool Owner Actions Interface - Interface of the owner methods.
/// @author Gabriele Rigo - <gab@rigoblock.com>
interface IRigoblockV3PoolOwnerActions {
    /// @dev Allows owner to decide where to receive the fee.
    /// @param _feeCollector Address of the fee receiver.
    function changeFeeCollector(address _feeCollector) external;

    /// @dev Allows pool owner to change the minimum holding period.
    /// @param _minPeriod Time in seconds.
    function changeMinPeriod(uint32 _minPeriod) external;

    /// @dev Allows pool owner to change the mint/burn spread.
    /// @param _newSpread Number between 0 and 1000, in basis points.
    function changeSpread(uint256 _newSpread) external;

    /// @notice Kyc provider can be set to null, removing user whitelist requirement.
    function setKycProvider(address _kycProvider) external;

    /// @dev Allows pool owner to set the transaction fee.
    /// @param _transactionFee Value of the transaction fee in basis points.
    function setTransactionFee(uint256 _transactionFee) external;

    /// @dev Allows pool owner to set the pool price.
    /// @param _unitaryValue Value of 1 token in wei units.
    /// @param _signaturevaliduntilBlock Number of blocks until expiry of new poolData.
    /// @param _hash Bytes32 of the transaction hash.
    /// @param _signedData Bytes of extradata and signature.
    function setUnitaryValue(
        uint256 _unitaryValue,
        uint256 _signaturevaliduntilBlock,
        bytes32 _hash,
        bytes calldata _signedData
    ) external;

}
