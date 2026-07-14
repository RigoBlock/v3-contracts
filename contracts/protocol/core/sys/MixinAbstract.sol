// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import {IERC20} from "../../interfaces/IERC20.sol";

/// @notice This contract exposes the pool as an ERC20 token while keeping shares non-transferable.
abstract contract MixinAbstract is IERC20 {
    /// @notice Thrown when a non-transferable pool token operation is requested.
    error PoolTokenOperationNotAllowed();

    /// @dev Pool tokens are not transferable. Reverts as required by the ERC-20 standard.
    function transfer(address to, uint256 value) external override returns (bool success) {
        revert PoolTokenOperationNotAllowed();
    }

    /// @dev Pool tokens are not transferable. Reverts as required by the ERC-20 standard.
    function transferFrom(address from, address to, uint256 value) external override returns (bool success) {
        revert PoolTokenOperationNotAllowed();
    }

    /// @dev Pool tokens do not support approvals. Reverts as required by the ERC-20 standard.
    function approve(address spender, uint256 value) external override returns (bool success) {
        revert PoolTokenOperationNotAllowed();
    }

    /// @dev Pool tokens do not support approvals. Allowance is always zero.
    function allowance(address owner, address spender) external view override returns (uint256) {
        return 0;
    }
}
