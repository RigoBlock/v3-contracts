// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import "../../interfaces/IERC20.sol";

/// @notice This contract makes it easy for clients to track ERC20.
abstract contract MixinAbstract is IERC20 {
    /// @dev Non-implemented ERC20 method.
    function transfer(address _to, uint256 _value) external override returns (bool success) {}

    /// @dev Non-implemented ERC20 method.
    function transferFrom(
        address _from,
        address _to,
        uint256 _value
    ) external override returns (bool success) {}

    /// @dev Non-implemented ERC20 method.
    function approve(address _spender, uint256 _value) external override returns (bool success) {}

    /// @dev Non-implemented ERC20 method.
    function allowance(address _owner, address _spender) external view override returns (uint256) {}
}
