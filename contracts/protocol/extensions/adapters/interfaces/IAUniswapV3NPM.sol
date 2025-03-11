// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2022 Rigo Intl.

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

pragma solidity >=0.8.0 <0.9.0;

import "../../../../utils/exchanges/uniswap/INonfungiblePositionManager/INonfungiblePositionManager.sol";

interface IAUniswapV3NPM {
    /// @notice Returns the address of the Uniswap NPM contract.
    /// @return Address of the Uniswap NPM contract.
    function uniswapv3Npm() external view returns (address);

    /// @notice Returns the address of the Weth contract.
    /// @return Address of the Weth contract.
    function weth() external view returns (address);

    /*
     * UNISWAP V3 LIQUIDITY METHODS
     */
    /// @notice Creates a new position wrapped in a NFT.
    /// @dev Call this when the pool does exist and is initialized. Note that if the pool is created but not initialized
    /// a method does not exist, i.e. the pool is assumed to be initialized.
    /// @param params The params necessary to mint a position, encoded as `MintParams` in calldata.
    /// @return tokenId The ID of the token that represents the minted position.
    /// @return liquidity The amount of liquidity for this position.
    /// @return amount0 The amount of token0.
    /// @return amount1 The amount of token1.
    function mint(INonfungiblePositionManager.MintParams calldata params)
        external
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        );

    /// @notice Increases the amount of liquidity in a position, with tokens paid by the `msg.sender`.
    /// @param params tokenId The ID of the token for which liquidity is being increased,
    /// amount0Desired The desired amount of token0 to be spent,
    /// amount1Desired The desired amount of token1 to be spent,
    /// amount0Min The minimum amount of token0 to spend, which serves as a slippage check,
    /// amount1Min The minimum amount of token1 to spend, which serves as a slippage check,
    /// deadline The time by which the transaction must be included to effect the change.
    /// @return liquidity The new liquidity amount as a result of the increase.
    /// @return amount0 The amount of token0 to acheive resulting liquidity.
    /// @return amount1 The amount of token1 to acheive resulting liquidity.
    function increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams calldata params)
        external
        returns (
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        );

    /// @notice Decreases the amount of liquidity in a position and accounts it to the position.
    /// @param params tokenId The ID of the token for which liquidity is being decreased,
    /// amount The amount by which liquidity will be decreased,
    /// amount0Min The minimum amount of token0 that should be accounted for the burned liquidity,
    /// amount1Min The minimum amount of token1 that should be accounted for the burned liquidity,
    /// deadline The time by which the transaction must be included to effect the change.
    /// @return amount0 The amount of token0 accounted to the position's tokens owed.
    /// @return amount1 The amount of token1 accounted to the position's tokens owed.
    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1);

    /// @notice Collects up to a maximum amount of fees owed to a specific position to the recipient.
    /// @param params tokenId The ID of the NFT for which tokens are being collected,
    /// recipient The account that should receive the tokens,
    /// amount0Max The maximum amount of token0 to collect,
    /// amount1Max The maximum amount of token1 to collect.
    /// @return amount0 The amount of fees collected in token0.
    /// @return amount1 The amount of fees collected in token1.
    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1);

    /// @notice Burns a token ID, which deletes it from the NFT contract. The token must have 0 liquidity and all tokens.
    /// must be collected first.
    /// @param tokenId The ID of the token that is being burned.
    function burn(uint256 tokenId) external;

    /// @notice Creates a new pool if it does not exist, then initializes if not initialized
    /// @dev This method can be bundled with others via IMulticall for the first action (e.g. mint) performed against a pool.
    /// @param token0 The contract address of token0 of the pool.
    /// @param token1 The contract address of token1 of the pool.
    /// @param fee The fee amount of the v3 pool for the specified token pair.
    /// @param sqrtPriceX96 The initial square root price of the pool as a Q64.96 value.
    /// @return pool Returns the pool address based on the pair of tokens and fee, will return the newly created pool address if necessary.
    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external returns (address pool);
}
