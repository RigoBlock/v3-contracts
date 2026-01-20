// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.0;

struct NavComponents {
    uint256 unitaryValue;
    uint256 totalSupply;
    address baseToken;
    uint8 decimals;
    uint256 netTotalValue; // Total pool value in base token units
    uint256 netTotalLiabilities; // Positive only when netTotalValue is negative
}
