// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "../protocol/interfaces/IERC20.sol";

/// @notice Mock 0x Settler for testing.
/// @dev Simulates Settler.execute: pulls tokens via AllowanceHolder, performs a mock swap, sends buyToken to recipient.
contract MockSettler {
    /// @notice AllowedSlippage struct matching the real 0x Settler.
    struct AllowedSlippage {
        address payable recipient;
        address buyToken;
        uint256 minAmountOut;
    }

    /// @notice Simulated exchange rate: 1 sellToken = exchangeRate buyToken (in buyToken decimals).
    uint256 public exchangeRate;

    /// @notice Mock buy token to mint/transfer.
    address public mockBuyToken;

    constructor() {
        exchangeRate = 1e18; // 1:1 default
    }

    function setExchangeRate(uint256 rate) external {
        exchangeRate = rate;
    }

    /// @notice Mock execute matching the real Settler signature.
    /// @dev In real Settler, this would execute DEX swaps. Here it mints buyToken to simulate a swap.
    function execute(
        AllowedSlippage calldata slippage,
        bytes[] calldata, /* actions */
        bytes32 /* zid */
    ) external payable returns (bool) {
        // Simulate swap output: mint/transfer buyToken to recipient
        // In real Settler, this handles TRANSFER_FROM, DEX swaps, and slippage check.
        uint256 buyAmount = (msg.value > 0) ? msg.value * exchangeRate / 1e18 : exchangeRate;

        // Simulate buyToken transfer to recipient
        if (slippage.buyToken != address(0) && buyAmount > 0) {
            // Transfer buyToken from this contract to recipient (test must pre-fund settler)
            uint256 balance = IERC20(slippage.buyToken).balanceOf(address(this));
            if (balance >= slippage.minAmountOut) {
                IERC20(slippage.buyToken).transfer(slippage.recipient, slippage.minAmountOut);
            }
        }

        return true;
    }
}
