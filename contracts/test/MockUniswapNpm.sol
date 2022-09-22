// SPDX-License-Identifier: Apache-2.0-or-later

pragma solidity 0.8.17;

import {WETH9 as WETH9Contract} from "../tokens/WETH9/WETH9.sol";
import "../utils/exchanges/uniswap/INonfungiblePositionManager/INonfungiblePositionManager.sol";

contract MockUniswapNpm {
    address public immutable WETH9;

    constructor() {
        WETH9 = address(new WETH9Contract());
    }

    function mint(INonfungiblePositionManager.MintParams memory params)
        external
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {}

    function increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams memory params)
        external
        returns (
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {}

    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {}

    function collect(INonfungiblePositionManager.CollectParams memory params)
        external
        returns (uint256 amount0, uint256 amount1)
    {}

    function burn(uint256 tokenId) external {}

    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external returns (address pool) {}

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {}
}
