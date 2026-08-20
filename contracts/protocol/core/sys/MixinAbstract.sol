// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import {IERC20} from "../../interfaces/IERC20.sol";

/// @notice This contract exposes the pool as an ERC20 token while keeping shares non-transferable.
abstract contract MixinAbstract is IERC20 {
    error PoolTokenOperationNotAllowed();

    function transfer(address, uint256) external override returns (bool) {
        revert PoolTokenOperationNotAllowed();
    }

    function transferFrom(address, address, uint256) external override returns (bool) {
        revert PoolTokenOperationNotAllowed();
    }

    function approve(address, uint256) external override returns (bool) {
        revert PoolTokenOperationNotAllowed();
    }

    function allowance(address, address) external view override returns (uint256) {
        return 0;
    }
}
