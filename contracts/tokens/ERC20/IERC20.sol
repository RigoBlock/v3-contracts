// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.5.0;

interface IERC20 {
    /// @notice Emitted when a token is transferred.
    /// @param from Address transferring the tokens.
    /// @param to Address receiving the tokens.
    /// @param value Number of token units.
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Emitted when a token holder sets and approval.
    /// @param owner Address of the account setting the approval.
    /// @param spender Address of the allowed account.
    /// @param value Number of approved units.
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice Transfers token from holder to another address.
    /// @param _to Address to send tokens to.
    /// @param _value Number of token units to send.
    /// @return success Bool the transaction was successful.
    function transfer(address _to, uint256 _value) external returns (bool success);

    /// @notice Allows spender to transfer tokens from the holder.
    /// @param _from Address of the token holder.
    /// @param _to Address to send tokens to.
    /// @param _value Number of units to transfer.
    /// @return success Bool the transaction was successful.
    function transferFrom(
        address _from,
        address _to,
        uint256 _value
    ) external returns (bool success);

    /// @notice Allows a holder to approve a spender.
    /// @param _spender Address of the token spender.
    /// @param _value Number of units to be approved.
    /// @return success Bool the transaction was successful.
    function approve(address _spender, uint256 _value) external returns (bool success);

    /// @notice Returns token balance for an address.
    /// @param _who Address to query balance for.
    /// @return Number of units held.
    function balanceOf(address _who) external view returns (uint256);

    /// @notice Returns token allowance of an address to another address.
    /// @param _owner Address of token hodler.
    /// @param _spender Address of the token spender.
    /// @return Number of allowed units.
    function allowance(address _owner, address _spender) external view returns (uint256);

    /// @notice Returns the total supply of the token.
    /// @return Number of issued units.
    function totalSupply() external view returns (uint256);
}
