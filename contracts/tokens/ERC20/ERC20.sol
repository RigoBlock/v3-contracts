// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import {IERC20} from "./IERC20.sol";

abstract contract ERC20 is IERC20 {
    function transfer(address to, uint256 value) external override returns (bool success) {
        require(_balances[msg.sender] >= value && _balances[to] + value > _balances[to]);
        _balances[msg.sender] -= value;
        _balances[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external virtual override returns (bool success) {
        require(
            _balances[from] >= value && _allowed[from][msg.sender] >= value && _balances[to] + value > _balances[to]
        );
        _balances[to] += value;
        _balances[from] -= value;
        _allowed[from][msg.sender] -= value;
        emit Transfer(from, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external override returns (bool success) {
        _allowed[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function balanceOf(address owner) external view override returns (uint256) {
        return _balances[owner];
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowed[owner][spender];
    }

    uint256 public override totalSupply;
    mapping(address => uint256) internal _balances;
    mapping(address => mapping(address => uint256)) internal _allowed;
}
