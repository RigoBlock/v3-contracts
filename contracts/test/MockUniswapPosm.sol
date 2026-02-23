// SPDX-License-Identifier: Apache 2.0

pragma solidity 0.8.24;

import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {CalldataDecoder} from "@uniswap/v4-periphery/src/libraries/CalldataDecoder.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @dev In uniswap Posm, calls must be calldata encoded to execute. We expose some methods for testing.
contract MockUniswapPosm {
    using PositionInfoLibrary for PositionInfo;
    using CalldataDecoder for bytes;

    IAllowanceTransfer public immutable permit2;

    uint256 public nextTokenId = 1;

    // a mock method to store and retrieve a position's liquidity without having to use PoolManager
    mapping(uint256 tokenId => uint256 liquidity) _liquidities;

    mapping(uint256 => address) internal _ownerOf;
    mapping(address => uint256) internal _balanceOf;

    mapping(uint256 tokenId => PositionInfo info) public positionInfo;
    mapping(bytes25 poolId => PoolKey poolKey) public poolKeys;

    error MockCustomError(string reason);

    // 0 = no revert, 1 = revert with string, 2 = revert with custom error
    uint256 public revertMode;

    constructor(address _permit2) {
        permit2 = IAllowanceTransfer(_permit2);
    }

    function setRevertMode(uint256 mode) external {
        revertMode = mode;
    }

    /// universal router needs to retrieve ownerOf
    function modifyLiquidities(bytes calldata unlockData, uint256 /*deadline*/) external payable {
        if (revertMode == 1) {
            revert("MockPosmStringError");
        } else if (revertMode == 2) {
            revert MockCustomError("MockPosmCustomError");
        }
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
            } else if (action == Actions.INCREASE_LIQUIDITY) {
                (
                    uint256 tokenId,
                    uint256 liquidity,
                    uint128 amount0Max,
                    uint128 amount1Max,
                    bytes calldata hookData
                ) = params[actionIndex].decodeModifyLiquidityParams();
                _increase(tokenId, liquidity, amount0Max, amount1Max, hookData);
            } else if (action == Actions.DECREASE_LIQUIDITY) {
                (
                    uint256 tokenId,
                    uint256 liquidity,
                    uint128 amount0Max,
                    uint128 amount1Max,
                    bytes calldata hookData
                ) = params[actionIndex].decodeModifyLiquidityParams();
                _decrease(tokenId, liquidity, amount0Max, amount1Max, hookData);
            } else if (action == Actions.BURN_POSITION) {
                (uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData) = params[actionIndex]
                    .decodeBurnParams();
                _burn(tokenId, amount0Min, amount1Min, hookData);
            }
        }
    }

    function getPoolAndPositionInfo(uint256 tokenId) public view returns (PoolKey memory poolKey, PositionInfo info) {
        info = positionInfo[tokenId];
        poolKey = poolKeys[info.poolId()];
    }

    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity) {
        //(PoolKey memory poolKey, PositionInfo info) = getPoolAndPositionInfo(tokenId);
        //liquidity = _getLiquidity(tokenId, poolKey, info.tickLower(), info.tickUpper());
        return uint128(_liquidities[tokenId]);
    }

    // TODO: check make this method private and modify some of the remaining tests to use modifyLiquidities
    /// @notice A mock method for creating positions for testing nav calculations
    function mint(
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity,
        uint128 /*amount0Max*/,
        uint128 /*amount1Max*/,
        address owner,
        bytes memory /*hookData*/
    ) public {
        // mint receipt token
        uint256 tokenId = nextTokenId++;
        _balanceOf[owner]++;
        _ownerOf[tokenId] = owner;

        // mock to retrieve liquidity by position
        _liquidities[tokenId] = liquidity;

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

    function _increase(
        uint256 tokenId,
        uint256 liquidity,
        uint128 /*amount0Max*/,
        uint128 /*amount1Max*/,
        bytes calldata /*hookData*/
    ) private {
        _liquidities[tokenId] += liquidity;
    }

    function _decrease(
        uint256 tokenId,
        uint256 liquidity,
        uint128 /*amount0Max*/,
        uint128 /*amount1Max*/,
        bytes calldata /*hookData*/
    ) private {
        _liquidities[tokenId] -= liquidity;
    }

    function _burn(
        uint256 tokenId,
        uint128 /*amount0Min*/,
        uint128 /*amount1Min*/,
        bytes calldata /*hookData*/
    ) private {
        address owner = ownerOf(tokenId);
        _balanceOf[owner]--;
        _ownerOf[tokenId] = address(0);

        // burn will prompt removing liquidity to 0 in Posm
        // https://github.com/Uniswap/v4-periphery/blob/4d85e047e321d0c02134fec9044879c0cd00ea7d/src/PositionManager.sol#L237
        _liquidities[tokenId] = 0;
        positionInfo[tokenId] = PositionInfoLibrary.EMPTY_POSITION_INFO;
    }

    function balanceOf(address owner) public view returns (uint256) {
        return _balanceOf[owner];
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        return _ownerOf[tokenId];
    }
}
