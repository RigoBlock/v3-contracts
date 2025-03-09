// SPDX-License-Identifier: Apache 2.0

pragma solidity 0.8.17;

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

library Allowance {
    function updateAmountAndExpiration(
        IAllowanceTransfer.PackedAllowance storage allowed,
        uint160 amount,
        uint48 expiration
    ) internal {
        // If the inputted expiration is 0, the allowance only lasts the duration of the block.
        allowed.expiration = expiration == 0 ? uint48(block.timestamp) : expiration;
        allowed.amount = amount;
    }
}

contract TestPermit2 {
    event Approval(
        address indexed owner, address indexed token, address indexed spender, uint160 amount, uint48 expiration
    );

    using Allowance for IAllowanceTransfer.PackedAllowance;

    mapping(address => mapping(address => mapping(address => IAllowanceTransfer.PackedAllowance))) public allowance;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        IAllowanceTransfer.PackedAllowance storage allowed = allowance[msg.sender][token][spender];
        allowed.updateAmountAndExpiration(amount, expiration);
        emit Approval(msg.sender, token, spender, amount, expiration);
    }
}
