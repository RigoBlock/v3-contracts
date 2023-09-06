// SPDX-License-Identifier: Apache-2.0-or-later
/*

 Copyright 2021-2022 Rigo Intl.

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
import "./interfaces/IEWhitelist.sol";
import "../../interfaces/IWETH9.sol";
import "../../IRigoblockV3Pool.sol";
import "../../../utils/exchanges/uniswap/v3-periphery/contracts/libraries/Path.sol";
import "../../../utils/exchanges/uniswap/ISwapRouter02/ISwapRouter02.sol";

/// @title AUniswap - Allows interactions with the Uniswap contracts.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// @notice We implement sweep token methods routed to uniswap router even though could be defined as virtual and not implemented,
//  because we always wrap/unwrap ETH within the pool and never accidentally send tokens to uniswap router or npm contracts.
//  This allows to avoid clasing signatures and correctly reach target address for payment methods.
contract AUniswap is IAUniswap, AUniswapV3NPM {
    using Path for bytes;

    // storage must be immutable as needs to be rutime consistent
    // 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45 on public networks
    /// @inheritdoc IAUniswap
    address public immutable override uniswapRouter02;

    // 0xC36442b4a4522E871399CD717aBDD847Ab11FE88 on public networks
    /// @inheritdoc IAUniswap
    address public immutable override uniswapv3Npm;

    /// @inheritdoc IAUniswap
    address public immutable override weth;

    constructor(address newUniswapRouter02) {
        uniswapRouter02 = newUniswapRouter02;
        uniswapv3Npm = payable(ISwapRouter02(uniswapRouter02).positionManager());
        weth = payable(INonfungiblePositionManager(uniswapv3Npm).WETH9());
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

        // we require target to being contract to prevent call being executed to EOA
        require(_isContract(path[0]), "AUNISWAP_APPROVE_TARGET_NOT_CONTRACT_ERROR");
        address uniswapRouter = _getUniswapRouter2();

        // we set the allowance to the uniswap router
        _safeApprove(path[0], uniswapRouter, type(uint256).max);

        amountOut = ISwapRouter02(uniswapRouter).swapExactTokensForTokens(
            amountIn,
            amountOutMin,
            path,
            to != address(this) ? address(this) : to
        );

        // we make sure we do not clear storage
        _safeApprove(path[0], uniswapRouter, uint256(1));
    }

    /// @inheritdoc IAUniswap
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to
    ) external override returns (uint256 amountIn) {
        _assertTokenWhitelisted(path[1]);

        // we require target to being contract to prevent call being executed to EOA
        require(_isContract(path[0]), "AUNISWAP_APPROVE_TARGET_NOT_CONTRACT_ERROR");
        address uniswapRouter = _getUniswapRouter2();

        // we set the allowance to the uniswap router
        _safeApprove(path[0], uniswapRouter, type(uint256).max);

        amountIn = ISwapRouter02(uniswapRouter).swapTokensForExactTokens(
            amountOut,
            amountInMax,
            path,
            to != address(this) ? address(this) : to
        );

        // we make sure we do not clear storage
        _safeApprove(path[0], uniswapRouter, uint256(1));
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

        // we require target to being contract to prevent call being executed to EOA
        require(_isContract(params.tokenIn), "AUNISWAP_APPROVE_TARGET_NOT_CONTRACT_ERROR");
        address uniswapRouter = _getUniswapRouter2();

        // we set the allowance to the uniswap router
        _safeApprove(params.tokenIn, uniswapRouter, type(uint256).max);

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
        _safeApprove(params.tokenIn, uniswapRouter, uint256(1));
    }

    /// @inheritdoc IAUniswap
    function exactInput(ISwapRouter02.ExactInputParams calldata params) external override returns (uint256 amountOut) {
        (address tokenIn, address tokenOut) = _decodePathTokens(params.path);

        _assertTokenWhitelisted(tokenOut);

        // we require target to being contract to prevent call being executed to EOA
        require(_isContract(tokenIn), "AUNISWAP_APPROVE_TARGET_NOT_CONTRACT_ERROR");
        address uniswapRouter = _getUniswapRouter2();

        // we set the allowance to the uniswap router
        _safeApprove(tokenIn, uniswapRouter, type(uint256).max);

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
        _safeApprove(tokenIn, uniswapRouter, uint256(1));
    }

    /// @inheritdoc IAUniswap
    function exactOutputSingle(ISwapRouter02.ExactOutputSingleParams calldata params)
        external
        override
        returns (uint256 amountIn)
    {
        _assertTokenWhitelisted(params.tokenOut);

        // we require target to being contract to prevent call being executed to EOA
        require(_isContract(params.tokenIn), "AUNISWAP_APPROVE_TARGET_NOT_CONTRACT_ERROR");
        address uniswapRouter = _getUniswapRouter2();

        // we set the allowance to the uniswap router
        _safeApprove(params.tokenIn, uniswapRouter, type(uint256).max);

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
        _safeApprove(params.tokenIn, uniswapRouter, uint256(1));
    }

    /// @inheritdoc IAUniswap
    function exactOutput(ISwapRouter02.ExactOutputParams calldata params) external override returns (uint256 amountIn) {
        (address tokenIn, address tokenOut) = _decodePathTokens(params.path);
        _assertTokenWhitelisted(tokenOut);

        // we require target to being contract to prevent call being executed to EOA
        require(_isContract(tokenIn), "AUNISWAP_APPROVE_TARGET_NOT_CONTRACT_ERROR");
        address uniswapRouter = _getUniswapRouter2();

        // we set the allowance to the uniswap router
        _safeApprove(tokenIn, uniswapRouter, type(uint256).max);

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
        _safeApprove(tokenIn, uniswapRouter, uint256(1));
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
        IWETH9(_getWeth()).withdraw(amountMinimum);
    }

    /// @inheritdoc IAUniswap
    function unwrapWETH9(uint256 amountMinimum, address recipient) external override {
        if (recipient != address(this)) {
            recipient = address(this);
        }
        IWETH9(_getWeth()).withdraw(amountMinimum);
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
            IWETH9(_getWeth()).deposit{value: value}();
        }
    }

    /// @inheritdoc IAUniswap
    function refundETH() external virtual override {}

    function _safeApprove(
        address token,
        address spender,
        uint256 value
    ) internal override {
        // 0x095ea7b3 = bytes4(keccak256(bytes("approve(address,uint256)")))
        // solhint-disable-next-line avoid-low-level-calls
        (, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, spender, value));
        // approval never fails unless rogue token
        assert(data.length == 0 || abi.decode(data, (bool)));
    }

    function _assertTokenWhitelisted(address token) internal view override {
        // we allow swapping to base token even if not whitelisted token
        if (token != IRigoblockV3Pool(payable(address(this))).getPool().baseToken) {
            require(IEWhitelist(address(this)).isWhitelistedToken(token), "AUNISWAP_TOKEN_NOT_WHITELISTED_ERROR");
        }
    }

    function _getUniswapNpm() internal view override returns (address) {
        return uniswapv3Npm;
    }

    // TODO: check if should visibility private
    function _isContract(address target) internal view returns (bool) {
        return target.code.length > 0;
    }

    function _decodePathTokens(bytes memory path) private pure returns (address tokenIn, address tokenOut) {
        (tokenIn, , ) = path.decodeFirstPool();

        if (path.hasMultiplePools()) {
            // we skip all routes but last POP_OFFSET
            for (uint256 i = 0; i < path.numPools() - 1; i++) {
                path = path.skipToken();
            }
        }

        (, tokenOut, ) = path.decodeFirstPool();
    }

    function _getUniswapRouter2() private view returns (address) {
        return uniswapRouter02;
    }

    function _getWeth() private view returns (address) {
        return weth;
    }
}
