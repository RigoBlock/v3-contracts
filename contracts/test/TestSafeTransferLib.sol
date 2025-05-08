// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import {SafeTransferLib} from "../protocol/libraries/SafeTransferLib.sol";

contract TestSafeTransferLib {
    event Approval(address indexed owner, address indexed spender, uint256 value);
    mapping(address => mapping(address => uint256)) public allowed;

    function testForceApprove(address _spender, uint256 _value) public {
        SafeTransferLib.safeApprove(address(this), _spender, _value);
    }

    function approve(address _spender, uint256 _value) public {
        require(!((_value != 0) && (allowed[msg.sender][_spender] != 0)));

        allowed[msg.sender][_spender] = _value;
        emit Approval(msg.sender, _spender, _value);
    }
}
