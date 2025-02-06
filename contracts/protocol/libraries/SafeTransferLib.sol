// SPDX-License-Identifier: Apache3.0-or-later
pragma solidity >=0.8.28;

import {IERC20} from "../interfaces/IERC20.sol";

type Currency is address;

/// @title SafeTransferLib
/// @dev This library allows for safe transfer of tokens without using assembly
library SafeTransferLib {
    error ApprovalFailed(address token);
    error ETHTransferFailed();
    error TokenTransferFailed();
    error TokenTransferFromFailed();

    function safeTransferNative(address to, uint256 amount) internal {
        (bool success, ) = to.call{gas: 2300, value: amount}("");
        require(success, ETHTransferFailed());
    }

    function safeTransfer(address token, address to, uint256 amount) internal {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        require(success && (data.length == 0 || abi.decode(data, (bool))), TokenTransferFailed());
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) = token.call(
            abi.encodeCall(IERC20.transferFrom, (from, to, amount))
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), TokenTransferFromFailed());
    }

    /// @dev There is no advantage in making a low-level call here, as old ERC20s require resetting approval.
    function safeApprove(address token, address spender, uint256 amount) internal {
        try IERC20(token).approve(spender, amount) returns (bool success) {
            // will revert in case of silent failure (i.e. an address without code)
            assert(success);
        } catch {
            // USDT on mainnet requires approval to be set to 0 before being reset again
            try IERC20(token).approve(spender, 0) {
                IERC20(token).approve(spender, amount);
            } catch {
                revert ApprovalFailed(token);
            }
        }
    }

    function isAddressZero(address target) internal pure returns (bool) {
        return target == address(0);
    }
}