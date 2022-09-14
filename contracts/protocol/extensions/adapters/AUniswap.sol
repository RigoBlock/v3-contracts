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
pragma solidity 0.8.14;

import "../../../utils/exchanges/uniswap/v3-periphery/contracts/libraries/Path.sol";
import "../../interfaces/IWETH9.sol";
import "../../../utils/exchanges/uniswap/ISwapRouter02/ISwapRouter02.sol";
import "./AUniswapV3NPM.sol";

// @notice We implement sweep token methods routed to uniswap router even though could be defined as virtual and not implemented,
//  because we always wrap/unwrap ETH within the pool and never accidentally send tokens to uniswap router or npm contracts.
//  This allows to avoid clasing signatures and correctly reach target address for payment methods.
contract AUniswap is AUniswapV3NPM {
    using Path for bytes;

    // storage must be immutable as needs to be rutime consistent
    bytes4 private constant APPROVE_SELECTOR = bytes4(keccak256(bytes("approve(address,uint256)")));

    // 0xE592427A0AEce92De3Edee1F18E0157C05861564 on public networks
    address public immutable UNISWAP_SWAP_ROUTER_2_ADDRESS;

    // 0xC36442b4a4522E871399CD717aBDD847Ab11FE88 on public networks
    address public immutable UNISWAP_V3_NPM_ADDRESS;

    address payable public immutable WETH_ADDRESS;

    constructor(address _uniswapRouter02) {
        UNISWAP_SWAP_ROUTER_2_ADDRESS = _uniswapRouter02;
        UNISWAP_V3_NPM_ADDRESS = payable(ISwapRouter02(UNISWAP_SWAP_ROUTER_2_ADDRESS).positionManager());
        WETH_ADDRESS = payable(INonfungiblePositionManager(UNISWAP_V3_NPM_ADDRESS).WETH9());
    }

    /*
     * UNISWAP V2 METHODS
    */
    /// @notice Swaps `amountIn` of one token for as much as possible of another token
    /// @dev Setting `amountIn` to 0 will cause the contract to look up its own balance,
    /// and swap the entire amount, enabling contracts to send tokens before calling this function.
    /// @param amountIn The amount of token to swap
    /// @param amountOutMin The minimum amount of output that must be received
    /// @param path The ordered list of tokens to swap through
    /// @param to The recipient address
    /// @return amountOut The amount of the received token
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to
    ) external returns (uint256 amountOut) {
        amountOut = ISwapRouter02(getUniswapRouter2()).swapExactTokensForTokens(amountIn, amountOutMin, path, to);
    }

    /// @notice Swaps as little as possible of one token for an exact amount of another token
    /// @param amountOut The amount of token to swap for
    /// @param amountInMax The maximum amount of input that the caller will pay
    /// @param path The ordered list of tokens to swap through
    /// @param to The recipient address
    /// @return amountIn The amount of token to pay
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to
    ) external returns (uint256 amountIn) {
        amountIn = ISwapRouter02(getUniswapRouter2()).swapTokensForExactTokens(amountOut, amountInMax, path, to);
    }

    /*
     * UNISWAP V3 SWAP METHODS
    */
    /// @notice Swaps `amountIn` of one token for as much as possible of another token
    /// @param params The parameters necessary for the swap, encoded as `ExactInputSingleParams` in memory
    /// @return amountOut The amount of the received token
    function exactInputSingle(ISwapRouter02.ExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut)
    {
        // we first set the allowance to the uniswap router
        _safeApprove(params.tokenIn, getUniswapRouter2(), type(uint256).max);

        // finally, we swap the tokens
        amountOut = ISwapRouter02(getUniswapRouter2()).exactInputSingle(
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
        _safeApprove(params.tokenIn, getUniswapRouter2(), uint256(1));
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another along the specified path
    /// @param params The parameters necessary for the multi-hop swap, encoded as `ExactInputParams` in memory
    /// @return amountOut The amount of the received token
    function exactInput(ISwapRouter02.ExactInputParams calldata params) external returns (uint256 amountOut) {
        (address tokenIn, , ) = params.path.decodeFirstPool();

        // we first set the allowance to the uniswap router
        _safeApprove(tokenIn, getUniswapRouter2(), type(uint256).max);

        // finally, we swap the tokens
        amountOut = ISwapRouter02(getUniswapRouter2()).exactInput(
            IV3SwapRouter.ExactInputParams({
                path: params.path,
                recipient: address(this), // this pool is always the recipient
                amountIn: params.amountIn,
                amountOutMinimum: params.amountOutMinimum
            })
        );

        // we make sure we do not clear storage
        _safeApprove(tokenIn, getUniswapRouter2(), uint256(1));
    }

    /// @notice Swaps as little as possible of one token for `amountOut` of another token
    /// @param params The parameters necessary for the swap, encoded as `ExactOutputSingleParams` in memory
    /// @return amountIn The amount of the input token
    function exactOutputSingle(ISwapRouter02.ExactOutputSingleParams calldata params)
        external
        returns (uint256 amountIn)
    {
        // we first set the allowance to the uniswap router
        _safeApprove(params.tokenIn, getUniswapRouter2(), type(uint256).max);

        // finally, we swap the tokens
        amountIn = ISwapRouter02(getUniswapRouter2()).exactOutputSingle(
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
        _safeApprove(params.tokenIn, getUniswapRouter2(), uint256(1));
    }

    /// @notice Swaps as little as possible of one token for `amountOut` of another along the specified path (reversed)
    /// @param params The parameters necessary for the multi-hop swap, encoded as `ExactOutputParams` in memory
    /// @return amountIn The amount of the input token
    function exactOutput(ISwapRouter02.ExactOutputParams calldata params) external returns (uint256 amountIn) {
        (address tokenIn, , ) = params.path.decodeFirstPool();

        // we first set the allowance to the uniswap router
        _safeApprove(tokenIn, getUniswapRouter2(), type(uint256).max);

        // finally, we swap the tokens
        amountIn = ISwapRouter02(getUniswapRouter2()).exactOutput(
            IV3SwapRouter.ExactOutputParams({
                path: params.path,
                recipient: address(this), // this pool is always the recipient
                amountOut: params.amountOut,
                amountInMaximum: params.amountInMaximum
            })
        );

        // we make sure we do not clear storage
        _safeApprove(tokenIn, getUniswapRouter2(), uint256(1));
    }

    /*
     * UNISWAP V3 PAYMENT METHODS
    */
    /// @notice Transfers the full amount of a token held by this contract to recipient.
    /// @dev The amountMinimum parameter prevents malicious contracts from stealing the token from users.
    /// @param token The contract address of the token which will be transferred to `recipient`.
    /// @param amountMinimum The minimum amount of token required for a transfer.
    function sweepToken(
        address token,
        uint256 amountMinimum
    ) external {
        ISwapRouter02(getUniswapRouter2()).sweepToken(
            token,
            amountMinimum
        );
    }

    /// @notice Transfers the full amount of a token held by this contract to recipient
    /// @dev The amountMinimum parameter prevents malicious contracts from stealing the token from users
    /// @param token The contract address of the token which will be transferred to `recipient`
    /// @param amountMinimum The minimum amount of token required for a transfer
    /// @param recipient The destination address of the token
    function sweepToken(
        address token,
        uint256 amountMinimum,
        address recipient
    ) external {
        ISwapRouter02(getUniswapRouter2()).sweepToken(
            token,
            amountMinimum,
            recipient != address(this) ? address(this) : address(this) // this pool is always the recipient
        );
    }

    /// @notice Transfers the full amount of a token held by this contract to recipient, with a percentage between
    /// 0 (exclusive) and 1 (inclusive) going to feeRecipient
    /// @dev The amountMinimum parameter prevents malicious contracts from stealing the token from users
    function sweepTokenWithFee(
        address token,
        uint256 amountMinimum,
        uint256 feeBips,
        address feeRecipient
    ) external {
        ISwapRouter02(getUniswapRouter2()).sweepTokenWithFee(
            token,
            amountMinimum,
            feeBips,
            feeRecipient
        );
    }

    /// @notice Unwraps the contract's WETH9 balance and sends it to recipient as ETH.
    /// @dev The amountMinimum parameter prevents malicious contracts from stealing WETH9 from users.
    /// @param amountMinimum The minimum amount of WETH9 to unwrap.
    function unwrapWETH9(uint256 amountMinimum) external {
        IWETH9(_getWethAddress()).withdraw(amountMinimum);
    }

    /// @notice Unwraps ETH from WETH9.
    /// @param amountMinimum The minimum amount of WETH9 to unwrap.
    /// @param recipient The address to keep same uniswap npm selector.
    function unwrapWETH9(uint256 amountMinimum, address recipient) external {
        if (recipient != address(this)) { recipient = address(this); }
        IWETH9(_getWethAddress()).withdraw(amountMinimum);
    }

    /// @notice Unwraps the contract's WETH9 balance and sends it to recipient as ETH, with a percentage between
    /// 0 (exclusive), and 1 (inclusive) going to feeRecipient
    /// @dev The amountMinimum parameter prevents malicious contracts from stealing WETH9 from users.
    function unwrapWETH9WithFee(
        uint256 amountMinimum,
        uint256 feeBips,
        address feeRecipient
    ) external virtual {}

    /// @notice Unwraps the contract's WETH9 balance and sends it to recipient as ETH, with a percentage between
    /// 0 (exclusive), and 1 (inclusive) going to feeRecipient
    /// @dev The amountMinimum parameter prevents malicious contracts from stealing WETH9 from users.
    function unwrapWETH9WithFee(
        uint256 amountMinimum,
        address recipient,
        uint256 feeBips,
        address feeRecipient
    ) external virtual{}

    /// @dev Wraps ETH.
    /// @notice Client must wrap if input is native currency.
    /// @param value The ETH amount to be wrapped.
    function wrapETH(uint256 value) external {
        if (value > uint256(0)) {
            IWETH9(_getWethAddress()).deposit{value: value}();
        }
    }

    /// @notice Allows sending pool transactions exactly as Uniswap original transactions.
    /// @dev Declared virtual as we never send ETH to Uniswap router contract.
    function refundETH() external virtual {}

    function _safeApprove(
        address token,
        address spender,
        uint256 value
    ) internal override {
        // solhint-disable-next-line avoid-low-level-calls
        // TODO: we may want to use assembly here
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(_getApproveSelector(), spender, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "AUNISWAPV3_TOKEN_APPROVE_FAILED_ERROR");
    }

    function _getApproveSelector() private pure returns (bytes4) {
        return APPROVE_SELECTOR;
    }

    function _getUniswapNpmAddress() internal view override returns (address) {
        return UNISWAP_V3_NPM_ADDRESS;
    }

    function getUniswapRouter2() internal view returns (address) {
        return UNISWAP_SWAP_ROUTER_2_ADDRESS;
    }

    function _getWethAddress() private view returns (address) {
        return WETH_ADDRESS;
    }
}
