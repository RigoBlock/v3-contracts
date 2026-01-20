// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.0;

// TODO: check if could remove uv,ntv,nlv from NavComponents and use NetAssetsValue directly
struct NavComponents {
    uint256 unitaryValue;
    uint256 totalSupply;
    address baseToken;
    uint8 decimals;
    uint256 netTotalValue; // Total pool value in base token units
    uint256 netTotalLiabilities; // Positive only when netTotalValue is negative
}

struct NetAssetsValue {
    uint256 unitaryValue;
    uint256 netTotalValue;
    uint256 netTotalLiabilities;
}
