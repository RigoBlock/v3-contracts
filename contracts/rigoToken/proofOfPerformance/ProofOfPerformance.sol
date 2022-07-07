// SPDX-License-Identifier: Apache 2.0

/*

 Copyright 2017-2019 RigoBlock, Rigo Investment Sagl, 2020 Rigo Intl.

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
pragma solidity 0.8.9;

import { IAuthorityCore } from "../../protocol/interfaces/IAuthorityCore.sol";
import { IPool } from "../../utils/pool/IPool.sol";
import { IProofOfPerformance } from "../interfaces/IProofOfPerformance.sol";
import { IPoolRegistry } from "../../protocol/interfaces/IPoolRegistry.sol";
import { IStaking } from "../../staking/interfaces/IStaking.sol";
import { IStorage } from "../../staking/interfaces/IStorage.sol";
import { IStructs } from "../../staking/interfaces/IStructs.sol";


/// @title Proof of Performance - Controls parameters of inflation.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
contract ProofOfPerformance is
    IProofOfPerformance
{
    address private immutable STAKING_PROXY_ADDRESS;

    mapping (bytes32 => uint256) private highWaterMark;

    constructor(address _stakingProxyAddress)
    {
        STAKING_PROXY_ADDRESS = _stakingProxyAddress;
    }

    /// @dev Credits the pop reward to the Staking Proxy contract.
    /// @param _poolAddress Address of the pool.
    function creditPopRewardToStakingProxy(
        address _poolAddress
    )
        external
        override
    {
        bytes32 poolId = IStorage(STAKING_PROXY_ADDRESS).poolIdByRbPoolAccount(_poolAddress);

        require(
            poolId != bytes32(0),
            "POOL_NOT_FOUND_IN_REGISTRY_ERROR"
        );

        // TODO: we store HWM but do not use it in calculations. Either we credit reward only in case of
        //  positive performance, or we may just remove storage.
        // initialization is not necessary but explicit as to prevent failure in case of a future upgrade
        _initializeHwmIfUninitialized(poolId);

        // pop assets component is always positive, therefore we must update the hwm if positive performance
        _updateHwmIfPositivePerformance(
            IPool(_poolAddress).calcSharePrice(),
            poolId
        );

        IStaking(STAKING_PROXY_ADDRESS).creditPopReward(
            _poolAddress,
            _proofOfPerformanceInternal(_poolAddress)
        );
    }

    /*
     * CONSTANT PUBLIC FUNCTIONS
     */
    /// @dev Returns the highwatermark of a pool.
    /// @param poolId Id of the pool.
    /// @return Value of the all-time-high pool nav.
    function getHwm(bytes32 poolId)
        external
        view
        override
        returns (uint256)
    {
        return _getHwmInternal(poolId);
    }

    /// @dev Returns the proof of performance reward for a pool.
    /// @param _poolAddress Address of the pool.
    /// @return Value of the pop reward in Rigo tokens.
    function proofOfPerformance(address _poolAddress)
        external
        view
        override
        returns (uint256)
    {
        return _proofOfPerformanceInternal(_poolAddress);
    }

    /*
     * INTERNAL FUNCTIONS
     */
    /// @dev Initializes the High Watermark if unitialized.
    /// @param poolId Number of the pool Id in registry.
    function _initializeHwmIfUninitialized(bytes32 poolId)
        internal
    {
        if (highWaterMark[poolId] == uint256(0)) {
            highWaterMark[poolId] = 1 ether;
        }
    }

    /// @dev Updates high-water mark if positive performance.
    /// @param poolPrice Value of the pool price.
    /// @param poolId Number of the pool Id in registry.
    function _updateHwmIfPositivePerformance(
        uint256 poolPrice,
        bytes32 poolId
    )
        internal
    {
        if (poolPrice > highWaterMark[poolId]) {
            highWaterMark[poolId] = poolPrice;
        }
    }

    /// @dev Returns the proof of performance reward for a pool.
    /// @param _poolAddress Address of the pool.
    /// @return Value of the pop reward base in Rigo tokens.
    function _proofOfPerformanceInternal(
        address _poolAddress
    )
        internal
        view
        returns (uint256)
    {
        return IStaking(STAKING_PROXY_ADDRESS).getOwnerStakeByStatus(
            _poolAddress,
            IStructs.StakeStatus.DELEGATED
        ).currentEpochBalance;
    }

    /// @dev Returns the high-watermark of the pool.
    /// @param poolId Number of the pool in registry.
    /// @return Number high-watermark.
    function _getHwmInternal(bytes32 poolId)
        internal
        view
        returns (uint256)
    {
        if (highWaterMark[poolId] == uint256(0)) {
            return (1 ether);

        } else {
            return highWaterMark[poolId];
        }
    }
}
