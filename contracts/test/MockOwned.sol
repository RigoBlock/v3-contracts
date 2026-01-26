// SPDX-License-Identifier: Apache 2.0

pragma solidity >0.8.0 <0.9.0;

contract MockOwned {
    function owner() external view returns (address) {
        return address(this);
    }
}
