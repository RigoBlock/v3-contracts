// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0;

import "../protocol/interfaces/IAuthority.sol";
import {IERC20 as Token} from "../tokens/ERC20/IERC20.sol";

interface MockProxyWhitelist {
    function isWhitelistedProxy(address proxy) external view returns (bool);
}

/// @notice moved from pool to this non-implemented contract to benchmark gas cost.
abstract contract AToken {
    /* solhint-disable var-name-mixedcase */
    address private immutable AUTHORITY;
    bytes4 private immutable APPROVE_SELECTOR = bytes4(keccak256(bytes("approve(address,uint256)")));

    /* solhint-enable var-name-mixedcase */

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
        require(MockProxyWhitelist(address(this)).isWhitelistedProxy(_proxy), "ATOKEN_NOT_APPROVED_PROXY_ERROR");
    }

    function _assertCallerIsPoolOwner() internal view {
        // 0x8da5cb5b = bytes4(keccak256(bytes("owner()")))
        (bool success, bytes memory data) = address(this).staticcall(abi.encodeWithSelector(0x8da5cb5b));
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
