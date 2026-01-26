// SPDX-License-Identifier: Apache-2.0-or-later

pragma solidity 0.8.17;

import {PoolAddress} from "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";
import {INonfungiblePositionManager} from "../utils/exchanges/uniswap/INonfungiblePositionManager/INonfungiblePositionManager.sol";

struct Position {
    uint96 nonce;
    address operator;
    uint80 poolId;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint256 feeGrowthInside0LastX128;
    uint256 feeGrowthInside1LastX128;
    uint128 tokensOwed0;
    uint128 tokensOwed1;
}

contract MockUniswapNpm {
    address public immutable WETH9;

    mapping(uint256 => address) private _ownerOf;
    mapping(address /*owner*/ => mapping(uint256 /*index*/ => uint256)) private _ownedTokens;
    mapping(address => uint256) private _balances;

    mapping(address => uint80) private _poolIds;
    mapping(uint80 => PoolAddress.PoolKey) private _poolIdToPoolKey;
    mapping(uint256 => Position) private _positions;

    uint176 private _nextId = 1;
    uint80 private _nextPoolId = 1;

    // default position in state. We can modify return params by override returned params
    Position public defaultPosition =
        Position({
            nonce: 0,
            operator: address(0),
            poolId: 0,
            tickLower: -2000,
            tickUpper: 3000,
            liquidity: 9369142662522830710261,
            feeGrowthInside0LastX128: 2 * 1e16,
            feeGrowthInside1LastX128: 3 * 1e16,
            tokensOwed0: 16 * 1e16,
            tokensOwed1: 15 * 1e16
        });

    constructor(address weth) {
        WETH9 = weth;
    }

    function mint(
        INonfungiblePositionManager.MintParams memory params
    ) external returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        tokenId = _nextId++;
        uint256 index = _balances[params.recipient]++;
        _ownerOf[tokenId] = params.recipient;
        _ownedTokens[params.recipient][index] = tokenId;

        PoolAddress.PoolKey memory poolKey = PoolAddress.getPoolKey(params.token0, params.token1, params.fee);
        address pool = address(uint160(uint256(keccak256(abi.encode(poolKey)))));
        uint80 poolId = _poolIds[pool];
        if (poolId == 0) {
            _poolIds[pool] = (poolId = _nextPoolId++);
            _poolIdToPoolKey[poolId] = poolKey;
        }

        // we can override position params here to return different tokens or balances later
        Position memory position = defaultPosition;
        position.poolId = poolId;
        _positions[tokenId] = position;

        return (tokenId, position.liquidity, 0, 0);
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

    function burn(uint256 tokenId) external {
        delete _positions[tokenId];
        address owner = _ownerOf[tokenId];
        // technically could be an approve address, but in rigoblock we only allow transactions to be proxied by the pool
        require(owner == msg.sender, "Not approved");
        _balances[owner]--;
        delete _ownerOf[tokenId];
    }

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
        uint256 tokenId
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
        Position memory position = _positions[tokenId];
        PoolAddress.PoolKey memory poolKey = _poolIdToPoolKey[position.poolId];
        return (
            position.nonce,
            position.operator,
            poolKey.token0,
            poolKey.token1,
            poolKey.fee,
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            position.feeGrowthInside0LastX128,
            position.feeGrowthInside1LastX128,
            position.tokensOwed0,
            position.tokensOwed1
        );
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return _ownerOf[tokenId];
    }

    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256 tokenId) {
        tokenId = _ownedTokens[owner][index];
    }
}
