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
pragma experimental ABIEncoderV2;

import { IInflation } from "../interfaces/IInflation.sol";
import { IRigoToken } from "../interfaces/IRigoToken.sol";
import { IStaking } from "../../staking/interfaces/IStaking.sol";


/// @title Inflation - Allows ProofOfPerformance to mint tokens.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
contract Inflation is
    IInflation
{
    /// @inheritdoc IInflation
    address public immutable override RIGO_TOKEN_ADDRESS;

    /// @inheritdoc IInflation
    address public immutable override STAKING_PROXY_ADDRESS;

    /// @inheritdoc IInflation
    uint256 public override epochLength;

    /// @inheritdoc IInflation
    uint256 public override slot;

    uint256 internal immutable ANNUAL_INFLATION_RATE = 2 * 10**4; // 2% annual inflation
    uint32 internal immutable PPM_DENOMINATOR = 10**6; // 100% in parts-per-million

    uint256 private epochEndTime;

    modifier onlyStakingProxy {
        _assertCallerIsStakingProxy();
        _;
    }

    constructor(
        address _rigoTokenAddress,
        address _stakingProxyAddress
    ) {
        RIGO_TOKEN_ADDRESS = _rigoTokenAddress;
        STAKING_PROXY_ADDRESS = _stakingProxyAddress;
    }

    /*
     * CORE FUNCTIONS
     */
    /// @inheritdoc IInflation
    function mintInflation()
        external
        override
        onlyStakingProxy
        returns (uint256 mintedInflation)
    {
        // solhint-disable-next-line not-rely-on-time
        require(block.timestamp >= epochEndTime, "INFLATION_EPOCH_END_ERROR");
        (uint256 epochDurationInSeconds, , , , ) = IStaking(STAKING_PROXY_ADDRESS).getParams();

        // sanity check for epoch length queried from staking
        if (epochLength != epochDurationInSeconds) {
            require(
                epochDurationInSeconds >= 5 days &&
                    epochDurationInSeconds <= 90 days,
                "INFLATION_TIME_ANOMALY_ERROR"
            );
            epochLength = epochDurationInSeconds;
        }

        uint256 epochInflation = getEpochInflation();

        // solhint-disable-next-line not-rely-on-time
        epochEndTime = block.timestamp + epochLength;
        slot = slot + 1;

        // mint rewards
        IRigoToken(RIGO_TOKEN_ADDRESS).mintToken(
            STAKING_PROXY_ADDRESS,
            epochInflation
        );
        return (mintedInflation = epochInflation);
    }

    /*
     * CONSTANT PUBLIC FUNCTIONS
     */
    /// @inheritdoc IInflation
    function epochEnded()
        external
        override
        view
        returns (bool)
    {
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp >= epochEndTime) {
            return true;
        } else return false;
    }

    /// @inheritdoc IInflation
    function getEpochInflation()
        public
        view
        override
        returns (uint256)
    {
        // 2% of GRG total supply
        // total supply * annual percentage inflation * time period (1 epoch)
        return (
            ANNUAL_INFLATION_RATE * epochLength * _getGRGTotalSupply()
            / PPM_DENOMINATOR / 365 days
        );
    }

    /// @inheritdoc IInflation
    function timeUntilNextClaim()
        external
        view
        override
        returns (uint256)
    {
        /* solhint-disable not-rely-on-time */
        if (block.timestamp < epochEndTime) {
            return (epochEndTime - block.timestamp);
        } else return (uint256(0));
        /* solhint-disable not-rely-on-time */
    }

    /*
     * INTERNAL METHODS
     */
    /// @dev Asserts that the caller is the Staking Proxy.
    function _assertCallerIsStakingProxy()
        private
        view
    {
        if (msg.sender != STAKING_PROXY_ADDRESS) {
            revert("CALLER_NOT_STAKING_PROXY_ERROR");
        }
    }

    function _getGRGTotalSupply()
        private
        view
        returns (uint256)
    {
        return IRigoToken(RIGO_TOKEN_ADDRESS).totalSupply();
    }
}
