// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2019 RigoBlock, Gabriele Rigo.

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

// solhint-disable-next-line
pragma solidity =0.8.17;

import "./interfaces/IAStaking.sol";
import "../../../staking/interfaces/IStaking.sol";
import "../../../staking/interfaces/IStorage.sol";
import {IRigoToken as GRG} from "../../../rigoToken/interfaces/IRigoToken.sol";

/// @title Self Custody adapter - A helper contract for self custody.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
contract AStaking is IAStaking {
    address private immutable STAKING_PROXY_ADDRESS;
    address private immutable GRG_TOKEN_ADDRESS;
    address private immutable GRG_TRASFER_PROXY_ADDRESS;

    constructor(
        address _stakingProxy,
        address _grgToken,
        address _grgTransferProxy
    ) {
        STAKING_PROXY_ADDRESS = _stakingProxy;
        GRG_TOKEN_ADDRESS = _grgToken;
        GRG_TRASFER_PROXY_ADDRESS = _grgTransferProxy;
    }

    /// @inheritdoc IAStaking
    function stake(uint256 _amount) external override {
        require(_amount != uint256(0), "STAKE_AMOUNT_NULL_ERROR");
        IStaking staking = IStaking(STAKING_PROXY_ADDRESS);
        bytes32 id = IStorage(STAKING_PROXY_ADDRESS).poolIdByRbPoolAccount(address(this));

        // create staking pool if doesn't exist.
        bytes32 poolId;
        if (id == bytes32(0)) {
            poolId = staking.createStakingPool(address(this));
            assert(poolId != 0);
        } else {
            poolId = id;
        }

        GRG(_getGrgToken()).approve(_getGrgTransferProxy(), type(uint256).max);
        staking.stake(_amount);
        staking.moveStake(
            IStructs.StakeInfo({status: IStructs.StakeStatus.UNDELEGATED, poolId: poolId}),
            IStructs.StakeInfo({status: IStructs.StakeStatus.DELEGATED, poolId: poolId}),
            _amount
        );

        // we make sure we remove allowance but do not clear storage
        GRG(_getGrgToken()).approve(_getGrgTransferProxy(), uint256(1));
    }

    /// @inheritdoc IAStaking
    function undelegateStake(uint256 _amount) external override {
        bytes32 poolId = IStorage(_getStakingProxy()).poolIdByRbPoolAccount(address(this));
        IStaking(_getStakingProxy()).moveStake(
            IStructs.StakeInfo({status: IStructs.StakeStatus.DELEGATED, poolId: poolId}),
            IStructs.StakeInfo({status: IStructs.StakeStatus.UNDELEGATED, poolId: poolId}),
            _amount
        );
    }

    /// @inheritdoc IAStaking
    function unstake(uint256 _amount) external override {
        IStaking(_getStakingProxy()).unstake(_amount);
    }

    /// @inheritdoc IAStaking
    function withdrawDelegatorRewards() external override {
        bytes32 poolId = IStorage(_getStakingProxy()).poolIdByRbPoolAccount(address(this));
        // we finalize the pool in case it has not been finalized, won't do anything otherwise
        IStaking(_getStakingProxy()).finalizePool(poolId);
        IStaking(_getStakingProxy()).withdrawDelegatorRewards(poolId);
    }

    function _getGrgToken() private view returns (address) {
        return GRG_TOKEN_ADDRESS;
    }

    function _getGrgTransferProxy() private view returns (address) {
        return GRG_TRASFER_PROXY_ADDRESS;
    }

    function _getStakingProxy() private view returns (address) {
        return STAKING_PROXY_ADDRESS;
    }
}
