// SPDX-License-Identifier: Apache 2.0

pragma solidity >0.8.0 <0.9.0;

import "../governance/IRigoblockGovernance.sol";
import "../governance/interfaces/governance/IGovernanceVoting.sol";
import "../staking/interfaces/IStaking.sol";
import "../staking/interfaces/IStructs.sol";
import "../tokens/ERC20/IERC20.sol";

/// @notice The following contract simulates a flash transaction.
/// @dev Flash loan of GRG is emulated by transferring GRG to this contract before attack.
contract FlashGovernance {
    event CatchStringEvent(string reason);

    address private immutable _stakingProxy;
    address private immutable _governance;
    address private immutable _grgTransferProxy;

    constructor(
        address stakingProxy,
        address governance,
        address grgTransferProxy
    ) {
        _grgTransferProxy = grgTransferProxy;
        _stakingProxy = stakingProxy;
        _governance = governance;
    }

    function flashAttack(bytes32 poolId, uint256 stakeAmount) external {
        IERC20(IStaking(_stakingProxy).getGrgContract()).approve(_grgTransferProxy, stakeAmount);
        IStaking(_stakingProxy).stake(stakeAmount);
        IStaking(_stakingProxy).moveStake(
            IStructs.StakeInfo(IStructs.StakeStatus.UNDELEGATED, poolId),
            IStructs.StakeInfo(IStructs.StakeStatus.DELEGATED, poolId),
            stakeAmount
        );
        IStaking(_stakingProxy).endEpoch();
        IRigoblockGovernance(_governance).castVote(1, IGovernanceVoting.VoteType.For);
        try IRigoblockGovernance(_governance).castVote(1, IGovernanceVoting.VoteType.For) {} catch Error(
            string memory revertReason
        ) {
            emit CatchStringEvent(revertReason);
        }
        try IRigoblockGovernance(_governance).execute(1) {} catch Error(string memory revertReason) {
            emit CatchStringEvent(revertReason);
        }
    }
}
