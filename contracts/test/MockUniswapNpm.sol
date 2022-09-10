// SPDX-License-Identifier: Apache-2.0-or-later

pragma solidity 0.8.14;

import "../utils/exchanges/uniswap/INonfungiblePositionManager/INonfungiblePositionManager.sol";

contract MockUniswapNpm {
    address public immutable WETH9;

    constructor(address _wethAddress) {
        WETH9 = _wethAddress;
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

    function sweepToken(
        address token,
        uint256 amountMinimum,
        address recipient
    ) external {}

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
