// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

/// @title Rigoblock V3 Pool Owner Actions Interface - Interface of the owner methods.
/// @author Gabriele Rigo - <gab@rigoblock.com>
interface IRigoblockV3PoolOwnerActions {
    /// @notice Allows owner to decide where to receive the fee.
    /// @param _feeCollector Address of the fee receiver.
    function changeFeeCollector(address _feeCollector) external;

    /// @notice Allows pool owner to change the minimum holding period.
    /// @param _minPeriod Time in seconds.
    function changeMinPeriod(uint48 _minPeriod) external;

    /// @notice Allows pool owner to change the mint/burn spread.
    /// @param _newSpread Number between 0 and 1000, in basis points.
    function changeSpread(uint16 _newSpread) external;

    /// @notice Kyc provider can be set to null, removing user whitelist requirement.
    function setKycProvider(address _kycProvider) external;

    // TODO: add natspec docs
    function setOwner(address _newOwner) external;

    /// @notice Allows pool owner to set the transaction fee.
    /// @param _transactionFee Value of the transaction fee in basis points.
    function setTransactionFee(uint16 _transactionFee) external;

    /// @notice Allows pool owner to set the pool price.
    /// @param _unitaryValue Value of 1 token in wei units.
    function setUnitaryValue(uint256 _unitaryValue) external;
}
