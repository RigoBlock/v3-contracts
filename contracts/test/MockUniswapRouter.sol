// SPDX-License-Identifier: Apache-2.0-or-later

pragma solidity 0.8.14;

import { WETH9 as WETH9Contract } from "../tokens/WETH9/WETH9.sol";
import "../utils/exchanges/uniswap/ISwapRouter02/ISwapRouter02.sol";
import "./MockUniswapNpm.sol";

contract MockUniswapRouter {
    address public immutable MOCK_UNISWAP_NPM_ADDRESS;

    constructor() {
        MOCK_UNISWAP_NPM_ADDRESS = address(new MockUniswapNpm());
    }

    function positionManager() external view returns (address) {
        return MOCK_UNISWAP_NPM_ADDRESS;
    }

    function sweepToken(
        address token,
        uint256 amountMinimum,
        address recipient
    ) external {}
}