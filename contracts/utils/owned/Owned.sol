// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

abstract contract Owned {
    /// @notice Address of the owner.
    address public owner;

    /// @notice Emitted when new owner is set.
    /// @param old Address of the previous owner.
    /// @param current Address of the new owner.
    event NewOwner(address indexed old, address indexed current);

    modifier onlyOwner() {
        require(msg.sender == owner, "OWNED_CALLER_IS_NOT_OWNER_ERROR");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /// @notice Allows current owner to set a new owner address.
    /// @dev Method restricted to owner.
    /// @param _new Address of the new owner.
    function setOwner(address _new) public onlyOwner {
        require(_new != address(0));
        address old = owner;
        owner = _new;
        emit NewOwner(old, _new);
    }
}
