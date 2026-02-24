// SPDX-License-Identifier: Apache-2.0-or-later

pragma solidity 0.8.28;

contract MockUniUniversalRouter {
    event UniCallExecuted(address caller);

    error MockCustomError(string reason);

    string public constant requiredVersion = "4.0.0";
    address public immutable univ4Posm;

    // 0 = no revert, 1 = revert with string, 2 = revert with custom error
    uint256 public revertMode;

    constructor(address univ4PosmAddress) {
        univ4Posm = univ4PosmAddress;
    }

    function setRevertMode(uint256 mode) external {
        revertMode = mode;
    }

    function execute(bytes calldata /*commands*/, bytes[] calldata /*inputs*/, uint256 /*deadline*/) external payable {
        _maybeRevert();
        emit UniCallExecuted(msg.sender);
    }

    function execute(bytes calldata /*commands*/, bytes[] calldata /*inputs*/) external payable {
        _maybeRevert();
        emit UniCallExecuted(msg.sender);
    }

    function _maybeRevert() private view {
        if (revertMode == 1) {
            revert("MockRouterStringError");
        } else if (revertMode == 2) {
            revert MockCustomError("MockRouterCustomError");
        }
    }
}
