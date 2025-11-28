// SPDX-License-Identifier: Apache 2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

/// @title Rigoblock V3 Pool Actions Interface - Allows interaction with the pool contract.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
interface ISmartPoolActions {
    /// @notice Allows a user to mint pool tokens on behalf of an address.
    /// @param recipient Address receiving the tokens.
    /// @param amountIn Amount of base tokens.
    /// @param amountOutMin Minimum amount to be received, prevents pool operator frontrunning.
    /// @return recipientAmount Number of tokens minted to recipient.
    function mint(
        address recipient,
        uint256 amountIn,
        uint256 amountOutMin
    ) external payable returns (uint256 recipientAmount);

    /// @notice Allows a user to mint pool tokens on behalf of an address using a desired token.
    /// @dev The token must be vault-owned, i.e. in the active token list, after operator action.
    /// @param recipient Address receiving the tokens.
    /// @param amountIn Amount of base tokens.
    /// @param amountOutMin Minimum amount to be received, prevents pool operator frontrunning.
    /// @return recipientAmount Number of tokens minted to recipient.
    function mintWithToken(
        address recipient,
        uint256 amountIn,
        uint256 amountOutMin,
        address tokenIn
    ) external payable returns (uint256 recipientAmount);

    /// @notice Allows a pool holder to burn pool tokens.
    /// @param amountIn Number of tokens to burn.
    /// @param amountOutMin Minimum amount to be received, prevents pool operator frontrunning.
    /// @return netRevenue Net amount of burnt pool tokens.
    function burn(uint256 amountIn, uint256 amountOutMin) external returns (uint256 netRevenue);

    /// @notice Allows a pool holder to burn pool tokens and receive a token other than base token.
    /// @dev The method is a fallback for when the vault does not hold enough base token, reverts otherwise.
    /// @param amountIn Number of tokens to burn.
    /// @param amountOutMin Minimum amount to be received, prevents pool operator frontrunning.
    /// @param tokenOut The token to be received in exchange for pool tokens.
    /// @return netRevenue Net amount of burnt pool tokens.
    function burnForToken(
        uint256 amountIn,
        uint256 amountOutMin,
        address tokenOut
    ) external returns (uint256 netRevenue);

    /// @notice Allows anyone to store an up-to-date pool price.
    function updateUnitaryValue() external;

    /// @notice Sets or removes an operator for the caller.
    /// @param operator The address of the operator.
    /// @param approved The approval status.
    /// @return bool True, always.
    function setOperator(address operator, bool approved) external returns (bool);
}
