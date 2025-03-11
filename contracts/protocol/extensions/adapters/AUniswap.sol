// SPDX-License-Identifier: Apache-2.0-or-later
/*

 Copyright 2021-2023 Rigo Intl.

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

// solhint-disable-next-line
pragma solidity 0.8.28;

import {INonfungiblePositionManager} from "../../../utils/exchanges/uniswap/INonfungiblePositionManager/INonfungiblePositionManager.sol";
import {BytesLib} from "../../../utils/exchanges/uniswap/v3-periphery/contracts/libraries/BytesLib.sol";
import {ISwapRouter02, IV3SwapRouter} from "../../../utils/exchanges/uniswap/ISwapRouter02/ISwapRouter02.sol";
import {IWETH9} from "../../interfaces/IWETH9.sol";
import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";
import {StorageLib} from "../../libraries/StorageLib.sol";
import {IAUniswap} from "./interfaces/IAUniswap.sol";
import {IMinimumVersion} from "./interfaces/IMinimumVersion.sol";
import {AUniswapV3NPM} from "./AUniswapV3NPM.sol";

/// @title AUniswap - Allows interactions with the Uniswap contracts.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// @notice We implement sweep token methods routed to uniswap router even though could be defined as virtual and not implemented,
//  because we always wrap/unwrap ETH within the pool and never accidentally send tokens to uniswap router or npm contracts.
//  This allows to avoid clasing signatures and correctly reach target address for payment methods.
contract AUniswap is IAUniswap, IMinimumVersion, AUniswapV3NPM {
    using BytesLib for bytes;
    using SafeTransferLib for address;

    string private constant _REQUIRED_VERSION = "4.0.0";

    // storage must be immutable as needs to be rutime consistent
    // 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45 on public networks
    /// @inheritdoc IAUniswap
    address public immutable override uniswapRouter02;

    address private constant ADDRESS_ZERO = address(0);

    constructor(address newUniswapRouter02) AUniswapV3NPM(newUniswapRouter02) {
        uniswapRouter02 = newUniswapRouter02;
    }

    /// @inheritdoc IMinimumVersion
    function requiredVersion() external pure override returns (string memory) {
        return _REQUIRED_VERSION;
    }

    /*
     * UNISWAP V2 METHODS
     */
    /// @inheritdoc IAUniswap
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to
    ) external override returns (uint256 amountOut) {
        address uniswapRouter = _preSwap(path[0], path[path.length - 1]);

        amountOut = ISwapRouter02(uniswapRouter).swapExactTokensForTokens(
            amountIn,
            amountOutMin,
            path,
            to != address(this) ? address(this) : to
        );

        // we make sure we do not clear storage
        path[0].safeApprove(uniswapRouter, uint256(1));
    }

    /// @inheritdoc IAUniswap
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to
    ) external override returns (uint256 amountIn) {
        address uniswapRouter = _preSwap(path[0], path[path.length - 1]);

        amountIn = ISwapRouter02(uniswapRouter).swapTokensForExactTokens(
            amountOut,
            amountInMax,
            path,
            to != address(this) ? address(this) : to
        );

        // we make sure we do not clear storage
        path[0].safeApprove(uniswapRouter, uint256(1));
    }

    /*
     * UNISWAP V3 SWAP METHODS
     */
    /// @inheritdoc IAUniswap
    function exactInputSingle(ISwapRouter02.ExactInputSingleParams calldata params)
        external
        override
        returns (uint256 amountOut)
    {
        address uniswapRouter = _preSwap(params.tokenIn, params.tokenOut);

        // we swap the tokens
        amountOut = ISwapRouter02(uniswapRouter).exactInputSingle(
            IV3SwapRouter.ExactInputSingleParams({
                tokenIn: params.tokenIn,
                tokenOut: params.tokenOut,
                fee: params.fee,
                recipient: address(this), // this pool is always the recipient
                amountIn: params.amountIn,
                amountOutMinimum: params.amountOutMinimum,
                sqrtPriceLimitX96: params.sqrtPriceLimitX96
            })
        );

        // we make sure we do not clear storage
        params.tokenIn.safeApprove(uniswapRouter, uint256(1));
    }

    /// @inheritdoc IAUniswap
    function exactInput(ISwapRouter02.ExactInputParams calldata params) external override returns (uint256 amountOut) {
        // tokenIn is the first address in the path, tokenOut the last
        address tokenIn = params.path.toAddress(0);
        address tokenOut = params.path.toAddress(params.path.length - 20);
        address uniswapRouter = _preSwap(tokenIn, tokenOut);

        // we swap the tokens
        amountOut = ISwapRouter02(uniswapRouter).exactInput(
            IV3SwapRouter.ExactInputParams({
                path: params.path,
                recipient: address(this), // this pool is always the recipient
                amountIn: params.amountIn,
                amountOutMinimum: params.amountOutMinimum
            })
        );

        // we make sure we do not clear storage
        tokenIn.safeApprove(uniswapRouter, uint256(1));
    }

    /// @inheritdoc IAUniswap
    function exactOutputSingle(ISwapRouter02.ExactOutputSingleParams calldata params)
        external
        override
        returns (uint256 amountIn)
    {
        address uniswapRouter = _preSwap(params.tokenIn, params.tokenOut);

        // we swap the tokens
        amountIn = ISwapRouter02(uniswapRouter).exactOutputSingle(
            IV3SwapRouter.ExactOutputSingleParams({
                tokenIn: params.tokenIn,
                tokenOut: params.tokenOut,
                fee: params.fee,
                recipient: address(this), // this pool is always the recipient
                amountOut: params.amountOut,
                amountInMaximum: params.amountInMaximum,
                sqrtPriceLimitX96: params.sqrtPriceLimitX96
            })
        );

        // we make sure we do not clear storage
        params.tokenIn.safeApprove(uniswapRouter, uint256(1));
    }

    /// @inheritdoc IAUniswap
    function exactOutput(ISwapRouter02.ExactOutputParams calldata params) external override returns (uint256 amountIn) {
        // tokenIn is the last address in the path, tokenOut the first
        address tokenOut = params.path.toAddress(0);
        address tokenIn = params.path.toAddress(params.path.length - 20);
        address uniswapRouter = _preSwap(tokenIn, tokenOut);

        // we swap the tokens
        amountIn = ISwapRouter02(uniswapRouter).exactOutput(
            IV3SwapRouter.ExactOutputParams({
                path: params.path,
                recipient: address(this), // this pool is always the recipient
                amountOut: params.amountOut,
                amountInMaximum: params.amountInMaximum
            })
        );

        // we make sure we do not clear storage
        tokenIn.safeApprove(uniswapRouter, uint256(1));
    }

    /*
     * UNISWAP V3 PAYMENT METHODS
     */
    /// @inheritdoc IAUniswap
    function sweepToken(address token, uint256 amountMinimum) external virtual override {}

    /// @inheritdoc IAUniswap
    function sweepToken(
        address token,
        uint256 amountMinimum,
        address recipient
    ) external virtual override {}

    /// @inheritdoc IAUniswap
    function sweepTokenWithFee(
        address token,
        uint256 amountMinimum,
        uint256 feeBips,
        address feeRecipient
    ) external virtual override {}

    /// @inheritdoc IAUniswap
    function sweepTokenWithFee(
        address token,
        uint256 amountMinimum,
        address recipient,
        uint256 feeBips,
        address feeRecipient
    ) external virtual override {}

    /// @inheritdoc IAUniswap
    function unwrapWETH9(uint256 amountMinimum) external override {
        _activateToken(ADDRESS_ZERO);
        IWETH9(weth).withdraw(amountMinimum);
    }

    /// @inheritdoc IAUniswap
    function unwrapWETH9(uint256 amountMinimum, address /*recipient*/) external override {
        _activateToken(ADDRESS_ZERO);
        IWETH9(weth).withdraw(amountMinimum);
    }

    /// @inheritdoc IAUniswap
    function unwrapWETH9WithFee(
        uint256 amountMinimum,
        uint256 feeBips,
        address feeRecipient
    ) external virtual override {}

    /// @inheritdoc IAUniswap
    function unwrapWETH9WithFee(
        uint256 amountMinimum,
        address recipient,
        uint256 feeBips,
        address feeRecipient
    ) external virtual override {}

    /// @inheritdoc IAUniswap
    function wrapETH(uint256 value) external override {
        if (value > uint256(0)) {
            _activateToken(weth);
            IWETH9(weth).deposit{value: value}();
        }
    }

    /// @inheritdoc IAUniswap
    function refundETH() external virtual override {}

    function _preSwap(address tokenIn, address tokenOut) private returns (address uniswapRouter) {
        _activateToken(tokenOut);
        uniswapRouter = uniswapRouter02;

        // we set the allowance to the uniswap router
        tokenIn.safeApprove(uniswapRouter, type(uint256).max);
    }
}
