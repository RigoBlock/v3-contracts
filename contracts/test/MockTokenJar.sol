// SPDX-License-Identifier: Apache 2.0

pragma solidity >0.8.0 <0.9.0;

contract MockTokenJar {
    bytes public constant name = "TokenJar";

    receive() external payable {}
}
