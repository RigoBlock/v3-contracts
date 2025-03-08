// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {IImmutableState} from "@uniswap/swap-router-contracts/contracts/interfaces/IImmutableState.sol";
import {IPeripheryPaymentsWithFeeExtended} from "@uniswap/swap-router-contracts/contracts/interfaces/IPeripheryPaymentsWithFeeExtended.sol";

import {IV2SwapRouter} from "./IV2SwapRouter.sol";
import {IV3SwapRouter} from "./IV3SwapRouter.sol";

/// @title Router token swapping functionality
interface ISwapRouter02 is IV2SwapRouter, IV3SwapRouter, IImmutableState, IPeripheryPaymentsWithFeeExtended {

}
