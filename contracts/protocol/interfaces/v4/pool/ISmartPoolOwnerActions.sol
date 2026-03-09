// SPDX-License-Identifier: Apache 2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {Delegation} from "../../../types/Delegation.sol";

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

    /// @notice Allows the owner to set acceptable mint tokens other than the base token.
    /// @param token Address of the target token.
    /// @param isAccepted Boolean to indicate whether the token is to be added or removed from storage.
    function setAcceptableMintToken(address token, bool isAccepted) external;

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

    /// @notice Allows pool owner to batch grant or revoke delegated adapter write access.
    /// @dev Each entry independently adds or removes one (selector, address) pair.
    ///      Emits DelegationUpdated only for entries that change storage (idempotent operations emit no event).
    /// @param delegations Array of delegation operations to apply.
    function updateDelegation(Delegation[] calldata delegations) external;


    /// @notice Revokes all selector delegations for a given address in a single call.
    /// @dev Useful when a delegated wallet is compromised.
    /// @param delegated Address whose full delegation is to be revoked.
    function revokeAllDelegations(address delegated) external;

    /// @notice Revokes all address delegations for a given selector in a single call.
    /// @dev Useful when an adapter is being replaced by governance and stale delegates should be cleaned.
    /// @param selector Selector whose full delegation list is to be cleared.
    function revokeAllDelegationsForSelector(bytes4 selector) external;
}
