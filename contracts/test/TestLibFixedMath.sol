// SPDX-License-Identifier: Apache 2.0

pragma solidity >0.7.0 <0.9.0;

import "../staking/libs/LibFixedMath.sol";

contract TestLibFixedMath {
    function mul(int256 a, int256 b) external pure returns (int256 c) {
        c = LibFixedMath.mul(a, b);
    }

    function div(int256 a, int256 b) external pure returns (int256 c) {
        c = LibFixedMath.div(a, b);
    }

    function mulDiv(
        int256 a,
        int256 n,
        int256 d
    ) external pure returns (int256 c) {
        c = LibFixedMath.mulDiv(a, n, d);
    }

    function uintMul(int256 f, uint256 u) external pure returns (uint256) {
        return LibFixedMath.uintMul(f, u);
    }

    function toFixed(uint256 n, uint256 d) external pure returns (int256 f) {
        return LibFixedMath.toFixed(n, d);
    }

    function ln(int256 x) external pure returns (int256 r) {
        return LibFixedMath.ln(x);
    }

    function exp(int256 x) external pure returns (int256 r) {
        return LibFixedMath.exp(x);
    }
}
