// SPDX-License-Identifier: Apache 2.0

pragma solidity >=0.8.0 <0.9.0;

interface IAStaking {
    /// @notice Stakes an amount of GRG to own staking pool. Creates staking pool if doesn't exist.
    /// @dev Creating staking pool if doesn't exist effectively locks direct call.
    /// @param _amount Amount of GRG to stake.
    function stake(uint256 _amount) external;

    /// @notice Undelegates stake for the pool.
    /// @param _amount Number of GRG units with undelegate.
    function undelegateStake(uint256 _amount) external;

    /// @notice Unstakes staked undelegated tokens for the pool.
    /// @param _amount Number of GRG units to unstake.
    function unstake(uint256 _amount) external;

    /// @notice Withdraws delegator rewards of the pool.
    function withdrawDelegatorRewards() external;
}
