// SPDX-License-Identifier: Apache-2.0-or-later
/*

 Copyright 2021 Rigo Intl.

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
pragma solidity 0.8.17;

import "./AUniswapV3NPM.sol";
import "./interfaces/IAUniswap.sol";
// TODO: import extension interface
//import "./interfaces/IEWhitelist.sol";
import "../EWhitelist.sol";
import "../../../utils/exchanges/uniswap/v3-periphery/contracts/libraries/Path.sol";
import "../../interfaces/IWETH9.sol";
import "../../../utils/exchanges/uniswap/ISwapRouter02/ISwapRouter02.sol";

// @notice We implement sweep token methods routed to uniswap router even though could be defined as virtual and not implemented,
//  because we always wrap/unwrap ETH within the pool and never accidentally send tokens to uniswap router or npm contracts.
//  This allows to avoid clasing signatures and correctly reach target address for payment methods.
contract AUniswap is IAUniswap, AUniswapV3NPM {
    using Path for bytes;

    // storage must be immutable as needs to be rutime consistent
    // 0xE592427A0AEce92De3Edee1F18E0157C05861564 on public networks
    address public immutable override UNISWAP_SWAP_ROUTER_2_ADDRESS;

    // 0xC36442b4a4522E871399CD717aBDD847Ab11FE88 on public networks
    address public immutable override UNISWAP_V3_NPM_ADDRESS;

    address public immutable override WETH_ADDRESS;

    constructor(address _uniswapRouter02) {
        UNISWAP_SWAP_ROUTER_2_ADDRESS = _uniswapRouter02;
        UNISWAP_V3_NPM_ADDRESS = payable(ISwapRouter02(UNISWAP_SWAP_ROUTER_2_ADDRESS).positionManager());
        WETH_ADDRESS = payable(INonfungiblePositionManager(UNISWAP_V3_NPM_ADDRESS).WETH9());
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
        _assertTokenWhitelisted(path[1]);

        amountOut = ISwapRouter02(_getUniswapRouter2()).swapExactTokensForTokens(
            amountIn,
            amountOutMin,
            path,
            to != address(this) ? address(this) : to
        );
    }

    /// @inheritdoc IAUniswap
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to
    ) external override returns (uint256 amountIn) {
        _assertTokenWhitelisted(path[1]);

        amountIn = ISwapRouter02(_getUniswapRouter2()).swapTokensForExactTokens(
            amountOut,
            amountInMax,
            path,
            to != address(this) ? address(this) : to
        );
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
        _assertTokenWhitelisted(params.tokenOut);

        // we first set the allowance to the uniswap router
        _safeApprove(params.tokenIn, _getUniswapRouter2(), type(uint256).max);

        // finally, we swap the tokens
        amountOut = ISwapRouter02(_getUniswapRouter2()).exactInputSingle(
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
        _safeApprove(params.tokenIn, _getUniswapRouter2(), uint256(1));
    }

    /// @inheritdoc IAUniswap
    function exactInput(ISwapRouter02.ExactInputParams calldata params) external override returns (uint256 amountOut) {
        (address tokenIn, address tokenOut, ) = params.path.decodeFirstPool();
        _assertTokenWhitelisted(tokenOut);

        // we first set the allowance to the uniswap router
        _safeApprove(tokenIn, _getUniswapRouter2(), type(uint256).max);

        // finally, we swap the tokens
        amountOut = ISwapRouter02(_getUniswapRouter2()).exactInput(
            IV3SwapRouter.ExactInputParams({
                path: params.path,
                recipient: address(this), // this pool is always the recipient
                amountIn: params.amountIn,
                amountOutMinimum: params.amountOutMinimum
            })
        );

        // we make sure we do not clear storage
        _safeApprove(tokenIn, _getUniswapRouter2(), uint256(1));
    }

    /// @inheritdoc IAUniswap
    function exactOutputSingle(ISwapRouter02.ExactOutputSingleParams calldata params)
        external
        override
        returns (uint256 amountIn)
    {
        _assertTokenWhitelisted(params.tokenOut);

        // we first set the allowance to the uniswap router
        _safeApprove(params.tokenIn, _getUniswapRouter2(), type(uint256).max);

        // finally, we swap the tokens
        amountIn = ISwapRouter02(_getUniswapRouter2()).exactOutputSingle(
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
        _safeApprove(params.tokenIn, _getUniswapRouter2(), uint256(1));
    }

    /// @inheritdoc IAUniswap
    function exactOutput(ISwapRouter02.ExactOutputParams calldata params) external override returns (uint256 amountIn) {
        (address tokenIn, address tokenOut, ) = params.path.decodeFirstPool();
        _assertTokenWhitelisted(tokenOut);

        // we first set the allowance to the uniswap router
        _safeApprove(tokenIn, _getUniswapRouter2(), type(uint256).max);

        // finally, we swap the tokens
        amountIn = ISwapRouter02(_getUniswapRouter2()).exactOutput(
            IV3SwapRouter.ExactOutputParams({
                path: params.path,
                recipient: address(this), // this pool is always the recipient
                amountOut: params.amountOut,
                amountInMaximum: params.amountInMaximum
            })
        );

        // we make sure we do not clear storage
        _safeApprove(tokenIn, _getUniswapRouter2(), uint256(1));
    }

    /*
     * UNISWAP V3 PAYMENT METHODS
     */
    /// @inheritdoc IAUniswap
    function sweepToken(address token, uint256 amountMinimum) external override {
        ISwapRouter02(_getUniswapRouter2()).sweepToken(token, amountMinimum);
    }

    /// @inheritdoc IAUniswap
    function sweepToken(
        address token,
        uint256 amountMinimum,
        address recipient
    ) external override {
        ISwapRouter02(_getUniswapRouter2()).sweepToken(
            token,
            amountMinimum,
            recipient != address(this) ? address(this) : address(this) // this pool is always the recipient
        );
    }

    /// @inheritdoc IAUniswap
    function sweepTokenWithFee(
        address token,
        uint256 amountMinimum,
        uint256 feeBips,
        address feeRecipient
    ) external override {
        ISwapRouter02(_getUniswapRouter2()).sweepTokenWithFee(token, amountMinimum, feeBips, feeRecipient);
    }

    /// @inheritdoc IAUniswap
    function sweepTokenWithFee(
        address token,
        uint256 amountMinimum,
        address recipient,
        uint256 feeBips,
        address feeRecipient
    ) external override {
        ISwapRouter02(_getUniswapRouter2()).sweepTokenWithFee(
            token,
            amountMinimum,
            recipient != address(this) ? address(this) : address(this), // this pool is always the recipient
            feeBips,
            feeRecipient
        );
    }

    /// @inheritdoc IAUniswap
    function unwrapWETH9(uint256 amountMinimum) external override {
        IWETH9(_getWethAddress()).withdraw(amountMinimum);
    }

    /// @inheritdoc IAUniswap
    function unwrapWETH9(uint256 amountMinimum, address recipient) external override {
        if (recipient != address(this)) {
            recipient = address(this);
        }
        IWETH9(_getWethAddress()).withdraw(amountMinimum);
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
    function wrapETH(uint256 value) external {
        if (value > uint256(0)) {
            IWETH9(_getWethAddress()).deposit{value: value}();
        }
    }

    /// @inheritdoc IAUniswap
    function refundETH() external virtual override {}

    function _safeApprove(
        address token,
        address spender,
        uint256 value
    ) internal override {
        // requiring target to being contract can be levied when token whitelist implemented
        require(isContract(token), "AUNISWAP_APPROVE_TARGET_NOT_CONTRACT_ERROR");
        // 0x095ea7b3 = bytes4(keccak256(bytes("approve(address,uint256)")))
        // solhint-disable-next-line avoid-low-level-calls
        (, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, spender, value));
        // approval never fails unless rogue token
        assert(data.length == 0 || abi.decode(data, (bool)));
    }

    function _getUniswapNpmAddress() internal view override returns (address) {
        return UNISWAP_V3_NPM_ADDRESS;
    }

    function isContract(address target) internal view returns (bool) {
        return target.code.length > 0;
    }

    function _assertTokenWhitelisted(address _token) private view {
        require(
            EWhitelist(address(this)).isWhitelisted(_token),
            "AUNISWAP_TOKEN_NOT_WHITELISTED_ERROR"
        );
    }

    function _getUniswapRouter2() private view returns (address) {
        return UNISWAP_SWAP_ROUTER_2_ADDRESS;
    }

    function _getWethAddress() private view returns (address) {
        return WETH_ADDRESS;
    }
}
