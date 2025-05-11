// SPDX-License-Identifier: Apache-2.0-or-later

pragma solidity 0.8.28;

contract MockUniUniversalRouter {
    event UniCallExecuted(address caller);

    string public constant requiredVersion = "4.0.0";
    address public immutable univ4Posm;

    constructor(address univ4PosmAddress) {
        univ4Posm = univ4PosmAddress;
    }

    function execute(bytes calldata /*commands*/, bytes[] calldata /*inputs*/, uint256 /*deadline*/) external payable {
        emit UniCallExecuted(msg.sender);
    }

    function execute(bytes calldata /*commands*/, bytes[] calldata /*inputs*/) external payable {
        emit UniCallExecuted(msg.sender);
    }
}
