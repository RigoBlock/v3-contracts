// SPDX-License-Identifier: Apache 2.0

pragma solidity >=0.8.0 <0.9.0;

interface IAStaking {
    /// @notice Creating staking pool if doesn't exist effectively locks direct call.
    function stake(uint256 _amount) external;

    function undelegateStake(uint256 _amount) external;

    function unstake(uint256 _amount) external;

    function withdrawDelegatorRewards() external;
}