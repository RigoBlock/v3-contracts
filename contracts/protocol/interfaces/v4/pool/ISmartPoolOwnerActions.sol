// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

/// @title Rigoblock V3 Pool Owner Actions Interface - Interface of the owner methods.
/// @author Gabriele Rigo - <gab@rigoblock.com>
interface ISmartPoolOwnerActions {
    /// @notice Allows owner to decide where to receive the fee.
    /// @param feeCollector Address of the fee receiver.
    function changeFeeCollector(address feeCollector) external;

    /// @notice Allows pool owner to change the minimum holding period.
    /// @param minPeriod Time in seconds.
    function changeMinPeriod(uint48 minPeriod) external;

    /// @notice Allows pool owner to change the mint/burn spread.
    /// @param newSpread Number between 0 and 1000, in basis points.
    function changeSpread(uint16 newSpread) external;

    /// @notice Allows the owner to remove all inactive token and applications.
    /// @dev This is the only endpoint that has access to removing a token from the active tokens tuple.
    /// @dev Used to reduce cost of mint/burn as more tokens are traded, and allow lower gas for hft.
    function purgeInactiveTokensAndApps() external;

    /// @notice Allows pool owner to set/update the user whitelist contract.
    /// @dev Kyc provider can be set to null, removing user whitelist requirement.
    /// @param kycProvider Address if the kyc provider.
    function setKycProvider(address kycProvider) external;

    /// @notice Allows pool owner to set a new owner address.
    /// @dev Method restricted to owner.
    /// @param newOwner Address of the new owner.
    function setOwner(address newOwner) external;

    /// @notice Allows pool owner to set the transaction fee.
    /// @param transactionFee Value of the transaction fee in basis points.
    function setTransactionFee(uint16 transactionFee) external;
}
