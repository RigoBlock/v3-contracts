// SPDX-License-Identifier: Apache 2.0

pragma solidity >0.7.0 <0.9.0;

import "../staking/libs/LibCobbDouglas.sol";

contract TestCobbDouglas {
    function getCobbDouglasReward(
        uint256 totalRewards,
        uint256 fees,
        uint256 totalFees,
        uint256 stake,
        uint256 totalStake,
        uint32 alphaNumerator,
        uint32 alphaDenominator
    ) external pure returns (uint256 rewards) {
        rewards = LibCobbDouglas.cobbDouglas(
            totalRewards,
            fees,
            totalFees,
            stake,
            totalStake,
            alphaNumerator,
            alphaDenominator
        );
    }
}
