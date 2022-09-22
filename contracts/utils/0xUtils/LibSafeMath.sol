// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.5.9 <0.9.0;

library LibSafeMath {
    function safeMul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }
        uint256 c = a * b;
        require(c / a == b, "LIBSAFEMATH_MULTIPLICATION_OVERFLOW_ERROR");
        return c;
    }

    function safeDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b != 0, "LIBSAFEMATH_DIVISION_BY_ZERO_ERROR");
        uint256 c = a / b;
        return c;
    }

    function safeSub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "LIBSAFEMATH_SUBTRACTION_UNDERFLOW_ERROR");
        return a - b;
    }

    function safeAdd(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "LIBSAFEMATH_ADDITION_OVERFLOW_ERROR");
        return c;
    }

    function max256(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }

    function min256(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
