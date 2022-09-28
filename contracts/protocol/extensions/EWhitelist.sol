// SPDX-License-Identifier: Apache 2.0

pragma solidity 0.8.17;

//import "./interfaces/IEWhitelist.sol";
import "../interfaces/IAuthorityCore.sol";

contract EWhitelist /*is IEWhitelist*/ {
    address immutable AUTHORITY;

    mapping(address => bool) public isWhitelisted;

    modifier onlyAuthority() {
        require(msg.sender == AUTHORITY, "EWHITELIST_CALLER_NOT_AUTHORITY_ERROR");
        _;
    }

    constructor(address _authority) {
        AUTHORITY = _authority;
    }

    function whitelistToken(address _token) public onlyAuthority {
        isWhitelisted[_token] = true;
    }

    function batchWhitelistTokens(address[] calldata _tokens) external {
        for (uint256 i = 0; i < _tokens.length; i++) {
            // if upgrading, i.e. using an internal method, always assert only authority can call batch method
            whitelistToken(_tokens[i]);
        }
    }
}