// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2023 Rigo Intl.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.

*/

pragma solidity >=0.8.0 <0.9.0;

import "../../staking/interfaces/IStaking.sol";
import "../../staking/interfaces/IStorage.sol";
import "../IRigoblockGovernance.sol";
import "../interfaces/IGovernanceStrategy.sol";

contract RigoblockGovernanceStrategy is IGovernanceStrategy {
    address private immutable _stakingProxy;
    uint256 private immutable _votingPeriod;

    constructor(address stakingProxy) {
        _stakingProxy = stakingProxy;
        _votingPeriod = 7 days;
    }

    // TODO: check as in the context of rigoblock, a proposal could be made after the epoch expired and voted immediately
    function votingTimestamps() public view override returns (uint256 startTime, uint256 endTime) {
        startTime = IStaking(_stakingProxy).getCurrentEpochEarliestEndTimeInSeconds();
        // TODO: check if there should be delay to prevent instant upgrade
        startTime = block.timestamp > startTime ? block.timestamp : startTime;
        endTime = startTime + votingPeriod();
    }

    function votingPeriod() public view override returns (uint256) {
        uint256 stakingEpochDuration = IStorage(_getStakingProxy()).epochDurationInSeconds();
        return stakingEpochDuration < _votingPeriod ? stakingEpochDuration : _votingPeriod;
    }

    function getVotingPower(address account) public view override returns (uint256) {
        return
            IStaking(_getStakingProxy())
                .getOwnerStakeByStatus(account, IStructs.StakeStatus.DELEGATED)
                .currentEpochBalance;
    }

    /// @inheritdoc IGovernanceStrategy
    function hasProposalPassed(IRigoblockGovernance.Proposal calldata proposal, uint256 minimumQuorum) public view override returns (bool) {
        if (!_hasVoteEnded(proposal.endTime)) {
            // Proposal is immediately executable if votes in favor higher than two thirds of total delegated GRG
            if (
                3 * proposal.votesFor >
                2 *
                    IStaking(_getStakingProxy())
                        .getGlobalStakeByStatus(IStructs.StakeStatus.DELEGATED)
                        .currentEpochBalance
            ) {
                return true;
            // Proposal is not passed until the vote is over.
            } else {
                return false;
            }
        }
        // TODO: check if we want to use else if
        // Must have >= 2/3 support (≃66.7%).
        if (2 * proposal.votesFor <= proposal.votesAgainst) {
            return false;
        }
        // Must reach quorum threshold.
        if (proposal.votesFor < minimumQuorum) {
            return false;
        }
        return true;
    }

    /// @notice It is more gas efficient at deploy to reading immutable from internal method.
    function _getStakingProxy() private view returns (address) {
        return _stakingProxy;
    }

    /// @notice Checks whether a vote starting at the given epoch has ended or not.
    /// @dev Epoch start and end are stored as startTime and endTime at proposal creation.
    /// @param endTime Time after which proposal can be executed.
    /// @return Boolean the vote has ended.
    function _hasVoteEnded(uint256 endTime) private view returns (bool) {
        return block.timestamp > endTime;
    }
}
