// SPDX-License-Identifier: Apache 2.0

pragma solidity >=0.8.14;

interface IAStaking {
    /// @notice Creating staking pool if doesn't exist effectively locks direct call.
    function stake(uint256 _amount) external;
}