// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.0;

struct NavData {
    uint256 totalValue; // Total pool value in base token
    uint256 unitaryValue; // NAV per share
    uint256 timestamp; // Block timestamp when calculated
}
