// SPDX-License-Identifier: Apache-2.0-or-later
/*

 Copyright 2025 Rigo Intl.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.

*/

pragma solidity 0.8.28;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin-legacy/contracts/utils/math/SafeCast.sol";
import {IDeflation} from "../interfaces/IDeflation.sol";

interface IEOracle {
    function convertTokenAmount(
        address token,
        int256 amount,
        address targetToken
    ) external view returns (int256 convertedAmount);
}

/// @title Deflation
contract Deflation is IDeflation {
    using SafeERC20 for IERC20;
    using SafeCast for int256;

    error InvalidConvertedAmount();
    error GrgAmountIsNull();

    IERC20 public immutable GRG;
    IEOracle public oracle;

    uint256 public constant MAX_DISCOUNT = 8000; // 80% in basis points
    uint256 public constant AUCTION_DURATION = 2 weeks;
    uint256 public constant BASIS_POINTS = 10000;

    // Mapping from token address to last purchase timestamp
    mapping(address => uint256) public lastPurchaseTime;

    event TokenPurchased(
        address indexed buyer,
        address indexed token,
        uint256 tokenAmount,
        uint256 grgPaid,
        uint256 discount
    );
    event OracleUpdated(address indexed newOracle);

    constructor(address _grg, address _oracle) {
        require(_grg != address(0), "Invalid GRG address");
        require(_oracle != address(0), "Invalid oracle address");
        GRG = IERC20(_grg);
        oracle = IEOracle(_oracle);
    }

    /// @notice Receive ETH from vaults
    receive() external payable {}

    /// @inheritdoc IDeflation
    function buyToken(address tokenOut, uint256 amountOut) external returns (uint256 amountIn) {
        require(amountOut > 0, "Amount must be greater than 0");
        require(tokenOut != address(0), "Invalid token address");

        uint256 discount = getCurrentDiscount(tokenOut);
        int256 grgAmount = oracle.convertTokenAmount(tokenOut, int256(amountOut), address(GRG));

        require(grgAmount > 0, InvalidConvertedAmount());

        amountIn = grgAmount.toUint256();

        // apply discount
        amountIn = (amountIn * (BASIS_POINTS - discount)) / BASIS_POINTS;

        require(amountIn > 0, GrgAmountIsNull());

        // Update last purchase time
        lastPurchaseTime[tokenOut] = block.timestamp;

        // Transfer tokens to buyer
        if (tokenOut == address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)) {
            // Handle ETH transfer
            (bool success, ) = msg.sender.call{value: amountOut}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        }

        emit TokenPurchased(msg.sender, tokenOut, amountOut, amountIn, discount);
    }

    function getCurrentDiscount(address token) public view returns (uint256) {
        uint256 timeSinceLastPurchase = block.timestamp - lastPurchaseTime[token];

        if (timeSinceLastPurchase >= AUCTION_DURATION) {
            return MAX_DISCOUNT;
        }

        // Linear increase from 0 to MAX_DISCOUNT over AUCTION_DURATION
        uint256 discount = (timeSinceLastPurchase * MAX_DISCOUNT) / AUCTION_DURATION;
        
        // Ensure discount never exceeds BASIS_POINTS
        return discount > BASIS_POINTS ? BASIS_POINTS : discount;
    }
}