// SPDX-License-Identifier: Apache 2.0

pragma solidity 0.8.17;

/// @title EWhitelist Interface - Allows interaction with the whitelist extension contract.
/// @author Gabriele Rigo - <gab@rigoblock.com>
interface IEWhitelist  {
    /// @notice Emitted when a token is whitelisted or removed.
    /// @param token Address pf the target token.
    /// @param isWhitelisted Boolean the token is added or removed.
    event Whitelisted(address indexed token, bool isWhitelisted);

    /// @dev Allows a whitelister to whitelist a token.
    /// @param _token Address of the target token.
    function whitelistToken(address _token) external;

    /// @dev Allows a whitelister to remove a token.
    /// @param _token Address of the target token.
    function removeToken(address _token) external;

    /// @dev Allows a whitelister to whitelist/remove a list of tokens.
    /// @param _tokens Address array to tokens.
    /// @param _whitelisted Bollean array the token is to be whitelisted or removed.
    function batchUpdateTokens(address[] calldata _tokens, bool[] memory _whitelisted) external;

    /// @dev Returns whether a token has been whitelisted.
    /// @param _token Address of the target token.
    /// @return Boolean the token is whitelisted.
    function isWhitelistedToken(address _token) external view returns (bool);

    /// @dev Returns the address of the authority contract.
    /// @return Address of the authority contract.
    function getAuthority() external view returns (address);
}