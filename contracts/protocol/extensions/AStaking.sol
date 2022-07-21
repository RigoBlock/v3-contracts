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
pragma solidity =0.8.14;

import "../../staking/interfaces/IStaking.sol";
import "../../staking/interfaces/IStorage.sol";
import { IRigoToken as GRG } from "../../rigoToken/interfaces/IRigoToken.sol";

/// @title Self Custody adapter - A helper contract for self custody.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
contract AStaking {

    address private immutable STAKING_PROXY_ADDRESS;
    address private immutable GRG_TOKEN_ADDRESS;
    address private immutable GRG_TRASFER_PROXY_ADDRESS;

    constructor(address _stakingProxy, address _grgToken, address _grgTransferProxy) {
        STAKING_PROXY_ADDRESS = _stakingProxy;
        GRG_TOKEN_ADDRESS = _grgToken;
        GRG_TRASFER_PROXY_ADDRESS = _grgTransferProxy;
    }

    /// @notice Creating staking pool if doesn't exist effectively locks direct call.
    function stake(uint256 _amount)
        external
    {
        require(_amount != uint256(0), "STAKE_AMOUNT_NULL_ERROR");
        IStaking staking = IStaking(STAKING_PROXY_ADDRESS);
        bytes32 id = IStorage(STAKING_PROXY_ADDRESS).poolIdByRbPoolAccount(address(this));

        // create staking pool if doesn't exist.
        bytes32 poolId;
        if (id == bytes32(0)) {
            poolId = staking.createStakingPool(address(this));
            require(poolId != 0, "ASTAKING_POOL_CREATION_ERROR");
        } else { poolId = id; }

        GRG(GRG_TOKEN_ADDRESS).approve(GRG_TRASFER_PROXY_ADDRESS, type(uint256).max);
        staking.stake(_amount);
        staking.moveStake(
            IStructs.StakeInfo({
                status: IStructs.StakeStatus.UNDELEGATED,
                poolId: poolId
            }),
            IStructs.StakeInfo({
                status: IStructs.StakeStatus.DELEGATED,
                poolId: poolId
            }),
            _amount
        );

        // we make sure we remove allowance but do not clear storage
        GRG(GRG_TOKEN_ADDRESS).approve(GRG_TRASFER_PROXY_ADDRESS, uint256(1));
    }
}
