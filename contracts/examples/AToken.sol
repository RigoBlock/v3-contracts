// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0;

interface Authority {
    function getExchangesAuthority() external view returns (address);
}

interface ExchangesAuthority {
    function isWhitelistedProxy(address proxy) external view returns (bool);
}

interface Pool {
    function owner() external view returns (address);
}

interface Token {
    function approve(address _spender, uint256 _value) external returns (bool success);

    function allowance(address _owner, address _spender) external view returns (uint256);

    function balanceOf(address _who) external view returns (uint256);
}

/// @notice moved from pool to this non-implemented contract to benchmark gas cost.
abstract contract AToken {
    address private immutable AUTHORITY;
    bytes4 private immutable APPROVE_SELECTOR = bytes4(keccak256(bytes("approve(address,uint256)")));

    constructor(address _authority) {
        AUTHORITY = _authority;
    }

    /// @dev Allows owner to set an allowance to an approved token transfer proxy.
    /// @param _tokenTransferProxy Address of the proxy to be approved.
    /// @param _token Address of the token to receive allowance for.
    /// @param _amount Number of tokens approved for spending.
    // TODO: test gas difference in declaring external vs public
    function setAllowance(
        address _tokenTransferProxy,
        address _token,
        uint256 _amount
    ) external {
        _assertCallerIsPoolOwner();
        _assertApprovedProxy(_tokenTransferProxy);

        require(_safeApprove(_token, _tokenTransferProxy, _amount), "POOL_ALLOWANCE_SETTING_ERROR");
    }

    /// @dev Allows owner to set allowances to multiple approved tokens with one call.
    /// @param _tokenTransferProxy Address of the proxy to be approved.
    /// @param _tokens Address of the token to receive allowance for.
    function resetMultipleAllowances(address _tokenTransferProxy, address[] calldata _tokens) external {
        _assertCallerIsPoolOwner();
        _assertApprovedProxy(_tokenTransferProxy);

        // TODO:
        for (uint256 i = 0; i < _tokens.length; i++) {
            if (!_safeApprove(_tokens[i], _tokenTransferProxy, uint256(1))) continue;
        }
    }

    function _assertApprovedProxy(address _proxy) internal view {
        require(_getExchangesAuthorityInstance().isWhitelistedProxy(_proxy), "ATOKEN_NOT_APPROVED_PROXY_ERROR");
    }

    /// @dev Finds the exchanges authority.
    /// @return Address of the exchanges authority.
    function _getExchangesAuthorityInstance() internal view returns (ExchangesAuthority) {
        return ExchangesAuthority(Authority(AUTHORITY).getExchangesAuthority());
    }

    function _assertCallerIsPoolOwner() internal view {
        (bool success, bytes memory data) = address(this).staticcall(abi.encodeWithSelector(Pool.owner.selector));
        require(success && msg.sender == abi.decode(data, (address)), "CALLER_NOT_POOL_OWNER_ERROR");
    }

    function _safeApprove(
        address token,
        address spender,
        uint256 value
    ) internal returns (bool) {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(APPROVE_SELECTOR, spender, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "ATOKEN_TOKEN_APPROVE_FAILED_ERROR");
        return true;
    }
}
