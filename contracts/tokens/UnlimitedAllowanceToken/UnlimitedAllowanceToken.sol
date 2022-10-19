// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import {ERC20} from "../ERC20/ERC20.sol";

abstract contract UnlimitedAllowanceToken is ERC20 {
    uint256 private constant _MAX_UINT = type(uint256).max;

    /// @dev ERC20 transferFrom, modified such that an allowance of _MAX_UINT represents an unlimited allowance.
    /// @param from Address to transfer from.
    /// @param to Address to transfer to.
    /// @param value Amount to transfer.
    /// @return Success of transfer.
    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external override returns (bool) {
        uint256 allowance = _allowed[from][msg.sender];
        require(_balances[from] >= value && allowance >= value && _balances[to] + value >= _balances[to]);
        _balances[to] += value;
        _balances[from] -= value;
        if (allowance < _MAX_UINT) {
            _allowed[from][msg.sender] -= value;
        }
        emit Transfer(from, to, value);
        return true;
    }
}
