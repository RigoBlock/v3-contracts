// SPDX-License-Identifier: Apache 2.0
pragma solidity 0.8.28;

import {IPeripheryPayments} from "@uniswap/v3-periphery/contracts/interfaces/IPeripheryPayments.sol";

contract MockPeripheryPayments is IPeripheryPayments {
    function unwrapWETH9(uint256 amountMinimum, address recipient) external payable {}
    function refundETH() external payable {}
    function sweepToken(
        address token,
        uint256 amountMinimum,
        address recipient
    ) external payable {}
}