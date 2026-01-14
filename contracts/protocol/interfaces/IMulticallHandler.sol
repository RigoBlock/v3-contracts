// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

interface IMulticallHandler {
    function drainLeftoverTokens(address token, address payable destination) external;
}