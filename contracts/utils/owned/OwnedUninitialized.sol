// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.7.0 <0.9.0;

import {IOwnedUninitialized} from "./IOwnedUninitialized.sol";

abstract contract OwnedUninitialized is IOwnedUninitialized {
    /// @inheritdoc IOwnedUninitialized
    address public override owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "OWNED_CALLER_IS_NOT_OWNER_ERROR");
        _;
    }

    /// @inheritdoc IOwnedUninitialized
    function setOwner(address _new) public override onlyOwner {
        require(_new != address(0));
        address old = owner;
        owner = _new;
        emit NewOwner(old, _new);
    }
}
