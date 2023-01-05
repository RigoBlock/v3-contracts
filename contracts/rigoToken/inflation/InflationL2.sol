// SPDX-License-Identifier: Apache 2.0

/*

 Copyright 2017-2019 RigoBlock, Rigo Investment Sagl, 2020-2022 Rigo Intl.

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
pragma solidity 0.8.17;
pragma experimental ABIEncoderV2;

import {IInflation} from "../interfaces/IInflation.sol";
import {IRigoToken} from "../interfaces/IRigoToken.sol";
import {IStaking} from "../../staking/interfaces/IStaking.sol";

/// @title Inflation - Allows ProofOfPerformance to mint tokens.
/// @author Gabriele Rigo - <gab@rigoblock.com>
/// @notice Inflation on L2s is only produced by distributing tokens owned by this contract.
/// @dev excess tokens are held in this contract until fully distributed.
// solhint-disable-next-line
contract InflationL2 is IInflation {
    /// @inheritdoc IInflation
    address public immutable override rigoToken;

    /// @inheritdoc IInflation
    address public immutable override stakingProxy;

    /// @inheritdoc IInflation
    uint48 public override epochLength;

    /// @inheritdoc IInflation
    uint32 public override slot;

    uint32 internal constant _ANNUAL_INFLATION_RATE = 2 * 10**4; // 2% annual inflation
    uint32 internal constant _PPM_DENOMINATOR = 10**6; // 100% in parts-per-million

    uint48 private _epochEndTime;

    modifier onlyStakingProxy() {
        _assertCallerIsStakingProxy();
        _;
    }

    constructor(address newRigoToken, address newStakingProxy) {
        rigoToken = newRigoToken;
        stakingProxy = newStakingProxy;
        epochLength = 0;
        slot = 0;
    }

    /*
     * CORE FUNCTIONS
     */
    /// @inheritdoc IInflation
    function mintInflation() external override onlyStakingProxy returns (uint256 mintedInflation) {
        // solhint-disable-next-line not-rely-on-time
        require(block.timestamp >= _getEpochEndTime(), "INFLATION_EPOCH_END_ERROR");
        (uint256 epochDuration, , , , ) = IStaking(_getStakingProxy()).getParams();

        // sanity check for epoch length queried from staking
        if (_getEpochLength() != epochDuration) {
            require(epochDuration >= 5 days && epochDuration <= 90 days, "INFLATION_TIME_ANOMALY_ERROR");

            // we update epoch length in storage
            epochLength = uint48(epochDuration);
        }

        uint256 epochInflation = getEpochInflation();

        // we update epoch end time in storage
        // solhint-disable-next-line not-rely-on-time
        _epochEndTime = uint48(block.timestamp + _getEpochLength());
        slot += 1;

        uint256 tokenBalance = IRigoToken(_getRigoToken()).balanceOf(address(this));

        // TODO: test what happens in the staking system when token balance is null
        // distribute rewards, we skip transfer if null amount
        if (tokenBalance == 0) {
            mintedInflation = 0;
        } else {
            mintedInflation = tokenBalance > epochInflation ? epochInflation : tokenBalance;
            IRigoToken(_getRigoToken()).transfer(_getStakingProxy(), mintedInflation);
        }

        return mintedInflation;
    }

    /*
     * CONSTANT PUBLIC FUNCTIONS
     */
    /// @inheritdoc IInflation
    function epochEnded() external view override returns (bool) {
        // solhint-disable-next-line not-rely-on-time
        return block.timestamp >= _getEpochEndTime();
    }

    /// @inheritdoc IInflation
    function getEpochInflation() public view override returns (uint256) {
        // 2% of GRG total supply
        // total supply * annual percentage inflation * time period (1 epoch)
        uint256 grgSupply = IRigoToken(_getRigoToken()).totalSupply();
        return ((_ANNUAL_INFLATION_RATE * _getEpochLength() * grgSupply) / _PPM_DENOMINATOR / 365 days);
    }

    /// @inheritdoc IInflation
    function timeUntilNextClaim() external view override returns (uint256) {
        uint256 epochEndTime = _getEpochEndTime();

        // solhint-disable-next-line not-rely-on-time
        return block.timestamp < epochEndTime ? epochEndTime - block.timestamp : 0;
    }

    /*
     * INTERNAL METHODS
     */
    /// @dev Asserts that the caller is the Staking Proxy.
    function _assertCallerIsStakingProxy() private view {
        require(msg.sender == _getStakingProxy(), "CALLER_NOT_STAKING_PROXY_ERROR");
    }

    function _getEpochEndTime() private view returns (uint256) {
        return uint256(_epochEndTime);
    }

    function _getEpochLength() private view returns (uint256) {
        return uint256(epochLength);
    }

    function _getRigoToken() private view returns (address) {
        return rigoToken;
    }

    function _getStakingProxy() private view returns (address) {
        return stakingProxy;
    }
}
