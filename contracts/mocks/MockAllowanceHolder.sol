// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "../protocol/interfaces/IERC20.sol";

/// @notice Mock 0x AllowanceHolder for testing.
/// @dev Simulates the AllowanceHolder.exec flow: sets ephemeral allowance, forwards data to target, transfers tokens.
contract MockAllowanceHolder {
    /// @notice Thrown when target has ERC20 transfer/approve selector (confused deputy check).
    error ERC20Rejected();

    /// @notice Mode for controlling mock behavior in tests.
    enum MockMode {
        Normal,
        Revert,
        RevertWithReason,
        RevertWithCustomError
    }

    error MockCustomError(string reason);

    MockMode public mockMode;
    string public revertReason;

    // Track last exec call parameters for test assertions
    address public lastOperator;
    address public lastToken;
    uint256 public lastAmount;
    address public lastTarget;
    bytes public lastData;
    uint256 public lastValue;

    function setMockMode(MockMode mode, string calldata reason) external {
        mockMode = mode;
        revertReason = reason;
    }

    function exec(
        address operator,
        address token,
        uint256 amount,
        address payable target,
        bytes calldata data
    ) external payable returns (bytes memory) {
        // Store for assertions
        lastOperator = operator;
        lastToken = token;
        lastAmount = amount;
        lastTarget = target;
        lastData = data;
        lastValue = msg.value;

        if (mockMode == MockMode.Revert) {
            revert();
        } else if (mockMode == MockMode.RevertWithReason) {
            revert(revertReason);
        } else if (mockMode == MockMode.RevertWithCustomError) {
            revert MockCustomError(revertReason);
        }

        // Simulate the AllowanceHolder flow:
        // 1. Pull sellToken from the caller (the pool in delegatecall context)
        if (token != address(0) && amount > 0) {
            IERC20(token).transferFrom(msg.sender, target, amount);
        }

        // 2. Forward data to target (simulate the Settler call)
        // In real AllowanceHolder, this appends 20 bytes of sender for ERC-2771.
        // For testing, we just call directly.
        (bool success, bytes memory result) = target.call{value: msg.value}(data);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }

        return result;
    }
}
