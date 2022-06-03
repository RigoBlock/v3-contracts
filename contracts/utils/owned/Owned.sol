// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

abstract contract Owned {

    address public owner;

    event NewOwner(address indexed old, address indexed current);

    modifier onlyOwner {
        require(msg.sender == owner);
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setOwner(address _new)
        public
        onlyOwner
    {
        require(_new != address(0));
        owner = _new;
        emit NewOwner(owner, _new);
    }
}
