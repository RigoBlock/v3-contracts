// SPDX-License-Identifier: Apache 2.0

pragma solidity >0.8.0 <0.9.0;

import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {CalldataDecoder} from "@uniswap/v4-periphery/src/libraries/CalldataDecoder.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

/// @dev In uniswap Posm, calls must be calldata encoded to execute. We expose some methods for testing. 
contract MockUniswapPosm {
    using PositionInfoLibrary for PositionInfo;
    using CalldataDecoder for bytes;

    uint256 public nextTokenId = 1;

    mapping(uint256 => address) internal _ownerOf;
    mapping(address => uint256) internal _balanceOf;

    mapping(uint256 tokenId => PositionInfo info) public positionInfo;
    mapping(bytes25 poolId => PoolKey poolKey) public poolKeys;

    /// universal router needs to retrieve ownerOf
    function modifyLiquidities(bytes calldata unlockData, uint256 /*deadline*/) external payable {
        (bytes calldata actions, bytes[] calldata params) = unlockData.decodeActionsRouterParams();
        uint256 numActions = actions.length;
        assert(numActions == params.length);

        for (uint256 actionIndex = 0; actionIndex < numActions; actionIndex++) {
            uint256 action = uint8(actions[actionIndex]);

            if (action == Actions.MINT_POSITION) {
                (
                    PoolKey memory poolKey,
                    int24 tickLower,
                    int24 tickUpper,
                    uint256 liquidity,
                    uint128 amount0Max,
                    uint128 amount1Max,
                    address owner,
                    bytes memory hookData
                ) = params[actionIndex].decodeMintParams();
                mint(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData);
            }
        }
    }

    function getPoolAndPositionInfo(uint256 tokenId) public view returns (PoolKey memory poolKey, PositionInfo info) {
        info = positionInfo[tokenId];
        poolKey = poolKeys[info.poolId()];
    }

    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity) {
        (PoolKey memory poolKey, PositionInfo info) = getPoolAndPositionInfo(tokenId);
        liquidity = _getLiquidity(tokenId, poolKey, info.tickLower(), info.tickUpper());
    }

    function _getLiquidity(uint256 tokenId, PoolKey memory /*poolKey*/, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint128 liquidity)
    {
        bytes32 positionId = Position.calculatePositionKey(address(this), tickLower, tickUpper, bytes32(tokenId));
        // TODO: should return based on positionId
        assert(positionId != keccak256(abi.encode(1)));
        liquidity = 0;
    }

    // TODO: we use memory, but prev. used calldata, check if ok. Alt, we could pass calldata params and decode, use this as internal
    /// @notice A mock method for creating positions for testing nav calculations
    function mint(
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 /*liquidity*/,
        uint128 /*amount0Max*/,
        uint128 /*amount1Max*/,
        address owner,
        bytes memory /*hookData*/
    ) public {
        // mint receipt token
        uint256 tokenId = nextTokenId++;
        _balanceOf[owner]++;
        _ownerOf[tokenId] = owner;

        // Initialize the position info
        PositionInfo info = PositionInfoLibrary.initialize(poolKey, tickLower, tickUpper);
        positionInfo[tokenId] = info;

        // Store the poolKey if it is not already stored.
        // On UniswapV4, the minimum tick spacing is 1, which means that if the tick spacing is 0, the pool key has not been set.
        bytes25 poolId = info.poolId();
        //bytes25 poolId = PositionInfoLibrary.poolId(info);
        if (poolKeys[poolId].tickSpacing == 0) {
            poolKeys[poolId] = poolKey;
        }

        //(BalanceDelta liquidityDelta,) =
        //    _modifyLiquidity(info, poolKey, liquidity.toInt256(), bytes32(tokenId), hookData);
        //liquidityDelta.validateMaxIn(amount0Max, amount1Max);
    }

    function balanceOf(address owner) public view returns (uint256) {
        return _balanceOf[owner];
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        return _ownerOf[tokenId];
    }
}
