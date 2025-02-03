// SPDX-License-Identifier: Apache-2.0-or-later

pragma solidity 0.8.17;

import {WETH9 as WETH9Contract} from "../tokens/WETH9/WETH9.sol";
import "../utils/exchanges/uniswap/INonfungiblePositionManager/INonfungiblePositionManager.sol";

contract MockUniswapNpm {
    address public immutable WETH9;

    uint256 private numPools;

    mapping(uint256 => address) private _ownerOf;
    // TODO: verify correctly stored, and check upgrade solc
    mapping(address /*owner*/ => mapping(uint256 /*index*/ => uint256)) private _ownedTokens;
    mapping(address => uint256) private _balances;

    constructor() {
        WETH9 = address(new WETH9Contract());
    }

    function mint(
        INonfungiblePositionManager.MintParams memory params
    ) external returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        tokenId = ++numPools;
        uint256 index = _balances[params.recipient]++;
        _ownerOf[tokenId] = params.recipient;
        _ownedTokens[params.recipient][index];
        liquidity = 1;
        amount0 = 2;
        amount1 = 3;
    }

    function increaseLiquidity(
        INonfungiblePositionManager.IncreaseLiquidityParams memory params
    ) external returns (uint128 liquidity, uint256 amount0, uint256 amount1) {}

    function decreaseLiquidity(
        INonfungiblePositionManager.DecreaseLiquidityParams calldata params
    ) external returns (uint256 amount0, uint256 amount1) {}

    function collect(
        INonfungiblePositionManager.CollectParams memory params
    ) external returns (uint256 amount0, uint256 amount1) {}

    function burn(uint256 tokenId) external {}

    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external returns (address pool) {}

    function balanceOf(address owner) external view returns (uint256) {
        return _balances[owner];
    }

    function positions(
        uint256
    )
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
    {
        nonce = 1;
        operator = address(1);
        token0 = WETH9;
        token1 = WETH9;
        fee = 500;
        tickLower = 100;
        tickUpper = 1000;
        liquidity = 400;
        feeGrowthInside0LastX128 = 2;
        feeGrowthInside1LastX128 = 3;
        tokensOwed0 = 16;
        tokensOwed1 = 15;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return _ownerOf[tokenId];
    }

    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256 tokenId) {
        tokenId = _ownedTokens[owner][index];
    }
}
