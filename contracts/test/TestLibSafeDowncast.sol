// SPDX-License-Identifier: Apache 2.0

pragma solidity >0.7.0 <0.9.0;

import "../staking/libs/LibSafeDowncast.sol";

contract TestLibSafeDowncast {

    function downcastToUint96(uint256 a) external pure returns (uint96 b) {
        b = LibSafeDowncast.downcastToUint96(a);
    }

    function downcastToUint64(uint256 a) external pure returns (uint64 b) {
        b = LibSafeDowncast.downcastToUint64(a);
    } 
}