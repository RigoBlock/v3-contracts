// SPDX-License-Identifier: Apache 2.0

pragma solidity >=0.8.0 <0.9.0;

import "../../../../utils/exchanges/uniswap/ISwapRouter02/ISwapRouter02.sol";

interface IAUniswap {
    function UNISWAP_SWAP_ROUTER_2_ADDRESS() external view returns (address);

    function UNISWAP_V3_NPM_ADDRESS() external view returns (address);

    function WETH_ADDRESS() external view returns (address);

    /*
     * UNISWAP V2 METHODS
     */
    /// @notice Swaps `amountIn` of one token for as much as possible of another token.
    /// @dev Setting `amountIn` to 0 will cause the contract to look up its own balance,
    /// and swap the entire amount, enabling contracts to send tokens before calling this function.
    /// @param amountIn The amount of token to swap.
    /// @param amountOutMin The minimum amount of output that must be received.
    /// @param path The ordered list of tokens to swap through.
    /// @param to The recipient address.
    /// @return amountOut The amount of the received token.
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to
    ) external returns (uint256 amountOut);

    /// @notice Swaps as little as possible of one token for an exact amount of another token.
    /// @param amountOut The amount of token to swap for.
    /// @param amountInMax The maximum amount of input that the caller will pay.
    /// @param path The ordered list of tokens to swap through.
    /// @param to The recipient address.
    /// @return amountIn The amount of token to pay.
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to
    ) external returns (uint256 amountIn);

    /*
     * UNISWAP V3 SWAP METHODS
     */
    /// @notice Swaps `amountIn` of one token for as much as possible of another token.
    /// @param params The parameters necessary for the swap, encoded as `ExactInputSingleParams` in memory.
    /// @return amountOut The amount of the received token.
    function exactInputSingle(ISwapRouter02.ExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut);

    /// @notice Swaps `amountIn` of one token for as much as possible of another along the specified path.
    /// @param params The parameters necessary for the multi-hop swap, encoded as `ExactInputParams` in memory.
    /// @return amountOut The amount of the received token.
    function exactInput(ISwapRouter02.ExactInputParams calldata params) external returns (uint256 amountOut);

    /// @notice Swaps as little as possible of one token for `amountOut` of another token.
    /// @param params The parameters necessary for the swap, encoded as `ExactOutputSingleParams` in memory.
    /// @return amountIn The amount of the input token.
    function exactOutputSingle(ISwapRouter02.ExactOutputSingleParams calldata params)
        external
        returns (uint256 amountIn);

    /// @notice Swaps as little as possible of one token for `amountOut` of another along the specified path (reversed).
    /// @param params The parameters necessary for the multi-hop swap, encoded as `ExactOutputParams` in memory.
    /// @return amountIn The amount of the input token.
    function exactOutput(ISwapRouter02.ExactOutputParams calldata params) external returns (uint256 amountIn);

    /*
     * UNISWAP V3 PAYMENT METHODS
     */
    /// @notice Transfers the full amount of a token held by this contract to recipient.
    /// @dev The amountMinimum parameter prevents malicious contracts from stealing the token from users.
    /// @param token The contract address of the token which will be transferred to `recipient`.
    /// @param amountMinimum The minimum amount of token required for a transfer.
    function sweepToken(address token, uint256 amountMinimum) external;

    /// @notice Transfers the full amount of a token held by this contract to recipient.
    /// @dev The amountMinimum parameter prevents malicious contracts from stealing the token from users.
    /// @param token The contract address of the token which will be transferred to `recipient`.
    /// @param amountMinimum The minimum amount of token required for a transfer.
    /// @param recipient The destination address of the token.
    function sweepToken(
        address token,
        uint256 amountMinimum,
        address recipient
    ) external;

    /// @notice Transfers the full amount of a token held by this contract to recipient, with a percentage between
    /// 0 (exclusive) and 1 (inclusive) going to feeRecipient.
    /// @dev The amountMinimum parameter prevents malicious contracts from stealing the token from users.
    function sweepTokenWithFee(
        address token,
        uint256 amountMinimum,
        uint256 feeBips,
        address feeRecipient
    ) external;

    function sweepTokenWithFee(
        address token,
        uint256 amountMinimum,
        address recipient,
        uint256 feeBips,
        address feeRecipient
    ) external;

    /// @notice Unwraps the contract's WETH9 balance and sends it to recipient as ETH.
    /// @dev The amountMinimum parameter prevents malicious contracts from stealing WETH9 from users.
    /// @param amountMinimum The minimum amount of WETH9 to unwrap.
    function unwrapWETH9(uint256 amountMinimum) external;

    /// @notice Unwraps ETH from WETH9.
    /// @param amountMinimum The minimum amount of WETH9 to unwrap.
    /// @param recipient The address to keep same uniswap npm selector.
    function unwrapWETH9(uint256 amountMinimum, address recipient) external;

    /// @notice Unwraps the contract's WETH9 balance and sends it to recipient as ETH, with a percentage between
    /// 0 (exclusive), and 1 (inclusive) going to feeRecipient.
    /// @dev The amountMinimum parameter prevents malicious contracts from stealing WETH9 from users.
    function unwrapWETH9WithFee(
        uint256 amountMinimum,
        uint256 feeBips,
        address feeRecipient
    ) external;

    /// @notice Unwraps the contract's WETH9 balance and sends it to recipient as ETH, with a percentage between
    /// 0 (exclusive), and 1 (inclusive) going to feeRecipient.
    /// @dev The amountMinimum parameter prevents malicious contracts from stealing WETH9 from users.
    function unwrapWETH9WithFee(
        uint256 amountMinimum,
        address recipient,
        uint256 feeBips,
        address feeRecipient
    ) external;

    /// @dev Wraps ETH.
    /// @notice Client must wrap if input is native currency.
    /// @param value The ETH amount to be wrapped.
    function wrapETH(uint256 value) external;

    /// @notice Allows sending pool transactions exactly as Uniswap original transactions.
    /// @dev Declared virtual as we never send ETH to Uniswap router contract.
    function refundETH() external;
}
