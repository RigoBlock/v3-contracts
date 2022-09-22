// SPDX-License-Identifier: Apache 2.0

pragma solidity >=0.8.0 <0.9.0;

interface IAMulticall {
    /// @notice Enables calling multiple methods in a single call to the contract
    function multicall(bytes[] calldata data) external returns (bytes[] memory results);
}
