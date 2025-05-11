// SPDX-License-Identifier: Apache-2.0-or-later

pragma solidity 0.8.17;

import {WETH9 as WETH9Contract} from "../tokens/WETH9/WETH9.sol";
import {ISwapRouter02} from "../utils/exchanges/uniswap/ISwapRouter02/ISwapRouter02.sol";
import {MockUniswapNpm} from "./MockUniswapNpm.sol";

contract MockUniswapRouter {
    string public constant requiredVersion = "4.0.0";
    address public immutable MOCK_UNISWAP_NPM_ADDRESS;

    constructor(address weth) {
        MOCK_UNISWAP_NPM_ADDRESS = address(new MockUniswapNpm(weth));
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to
    ) external returns (uint256 amountOut) {}

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to
    ) external returns (uint256 amountIn) {}

    function exactInputSingle(
        ISwapRouter02.ExactInputSingleParams calldata params
    ) external returns (uint256 amountOut) {}

    function exactInput(ISwapRouter02.ExactInputParams calldata params) external returns (uint256 amountOut) {}

    function exactOutputSingle(
        ISwapRouter02.ExactOutputSingleParams calldata params
    ) external returns (uint256 amountIn) {}

    function exactOutput(ISwapRouter02.ExactOutputParams calldata params) external returns (uint256 amountIn) {}

    function sweepToken(address token, uint256 amountMinimum) external {}

    function sweepToken(address token, uint256 amountMinimum, address recipient) external {}

    function sweepTokenWithFee(address token, uint256 amountMinimum, uint256 feeBips, address feeRecipient) external {}

    function sweepTokenWithFee(
        address token,
        uint256 amountMinimum,
        address recipient,
        uint256 feeBips,
        address feeRecipient
    ) external {}

    function positionManager() external view returns (address) {
        return MOCK_UNISWAP_NPM_ADDRESS;
    }
}
