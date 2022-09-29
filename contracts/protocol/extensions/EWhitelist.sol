// SPDX-License-Identifier: Apache 2.0

pragma solidity 0.8.17;

import "./adapters/interfaces/IEWhitelist.sol";
import "../interfaces/IAuthorityCore.sol";

/// @title EWhitelist - Allows whitelisting of tokens.
/// @author Gabriele Rigo - <gab@rigoblock.com>
/// @notice This contract has its own storage, which could potentially clash with pool storage if its methods were accessible by pool, which are not.
/// Warning: careful with upgrades as pool only accesses isWhitelistedToken view method. Other methods are locked and should never be approved by governance.
contract EWhitelist is IEWhitelist {
    address private immutable AUTHORITY;

    mapping(address => bool) private isWhitelisted;

    modifier onlyAuthorized() {
        _assertCallerIsAuthorized();
        _;
    }

    constructor(address _authority) {
        AUTHORITY = _authority;
    }

    /// @inheritdoc IEWhitelist
    function whitelistToken(address _token) public override onlyAuthorized {
        require(!isWhitelisted[_token], "EWHITELIST_TOKEN_ALREADY_WHITELISTED_ERROR");
        isWhitelisted[_token] = true;
        emit Whitelisted(_token, true);
    }

    /// @inheritdoc IEWhitelist
    function removeToken(address _token) public override onlyAuthorized {
        require(isWhitelisted[_token], "EWHITELIST_TOKEN_ALREADY_REMOVED_ERROR");
        isWhitelisted[_token] = false;
        emit Whitelisted(_token, false);
    }

    /// @inheritdoc IEWhitelist
    function batchUpdateTokens(address[] calldata _tokens, bool[] memory _whitelisted) external override {
        for (uint256 i = 0; i < _tokens.length; i++) {
            // if upgrading (to i.e. using an internal method), always assert only authority can call batch method
            _whitelisted[i] == true ? whitelistToken(_tokens[i]) : removeToken(_tokens[i]);
        }
    }

    /// @inheritdoc IEWhitelist
    function isWhitelistedToken(address _token) external view override returns (bool) {
        return isWhitelisted[_token];
    }

    /// @inheritdoc IEWhitelist
    function getAuthority() public view override returns (address) {
        return AUTHORITY;
    }

    function _assertCallerIsAuthorized() private view {
        require(
            IAuthorityCore(getAuthority()).isWhitelister(msg.sender),
            "EWHITELIST_CALLER_NOT_WHITELISTER_ERROR"
        );
    }
}
