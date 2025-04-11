// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2022-2025 Rigo Intl.

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

import {IAGovernance} from "./IAGovernance.sol";
import {IAMulticall} from "./IAMulticall.sol";
import {IAStaking} from "./IAStaking.sol";
import {IAUniswap} from "./IAUniswap.sol";
import {IAUniswapRouter} from "./IAUniswapRouter.sol";
import {IEApps} from "./IEApps.sol";
import {IEOracle} from "./IEOracle.sol";
import {IEUpgrade} from "./IEUpgrade.sol";

/// @title Rigoblock Extensions Interface - Groups together the extensions' methods.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
interface IRigoblockExtensions is
    IAGovernance,
    IAMulticall,
    IAStaking,
    IAUniswap,
    IAUniswapRouter,
    IEApps,
    IEOracle,
    IEUpgrade
{}
