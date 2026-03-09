// SPDX-License-Identifier: Apache 2.0-or-later
pragma solidity 0.8.28;

/// @notice Minimal adapter used exclusively in delegation tests.
/// @dev When called via delegatecall the write succeeds; under staticcall the write reverts.
contract MockDelegationAdapter {
    address private immutable _IMPLEMENTATION = address(this);

    error NotDelegateCall();

    modifier onlyDelegateCall() {
        require(address(this) != _IMPLEMENTATION, NotDelegateCall());
        _;
    }

    /// @notice Dummy write method registered in Authority for delegation tests.
    function delegationTestWrite() external onlyDelegateCall {}
}
