// SPDX-License-Identifier: Apache 2.0

pragma solidity 0.8.17;

interface IEWhitelist  {
    event Whitelisted(address indexed token, bool isWhitelisted);

    function whitelistToken(address _token) external;

    function removeToken(address _token) external;

    function batchUpdateTokens(address[] calldata _tokens, bool[] memory _whitelisted) external;

    function isWhitelistedToken(address _token) external view returns (bool);

    function getAuthority() external view returns (address);
}