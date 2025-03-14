// SPDX-License-Identifier: Apache-2.0-or-later
/*

 Copyright 2021-2023 Rigo Intl.

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
pragma solidity 0.8.28;

import {IERC721Enumerable as IERC721} from "forge-std/interfaces/IERC721.sol";
import {INonfungiblePositionManager} from "../../../utils/exchanges/uniswap/INonfungiblePositionManager/INonfungiblePositionManager.sol";
import {ISwapRouter02} from "../../../utils/exchanges/uniswap/ISwapRouter02/ISwapRouter02.sol";
import {ApplicationsLib, ApplicationsSlot} from "../../libraries/ApplicationsLib.sol";
import {EnumerableSet, AddressSet} from "../../libraries/EnumerableSet.sol";
import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";
import {StorageLib} from "../../libraries/StorageLib.sol";
import {IWETH9} from "../../interfaces/IWETH9.sol";
import {Applications, TokenIdsSlot} from "../../types/Applications.sol";
import {IAUniswapV3NPM} from "./interfaces/IAUniswapV3NPM.sol";
import {IEOracle} from "./interfaces/IEOracle.sol";

/// @title AUniswapV3NPM - Allows interactions with the Uniswap NPM contract.
/// @author Gabriele Rigo - <gab@rigoblock.com>
abstract contract AUniswapV3NPM is IAUniswapV3NPM {
    using ApplicationsLib for ApplicationsSlot;
    using EnumerableSet for AddressSet;
    using SafeTransferLib for address;

    error UniV3PositionsLimitExceeded();
    error PositionOwner();

    IWETH9 internal immutable _weth;

    // 0xC36442b4a4522E871399CD717aBDD847Ab11FE88 on public networks
    INonfungiblePositionManager private immutable _uniV3Npm;

    enum OperationType {
        Mint,
        Increase,
        Burn
    }

    constructor(address uniswapRouter02) {
        _uniV3Npm = INonfungiblePositionManager(payable(ISwapRouter02(uniswapRouter02).positionManager()));
        _weth = IWETH9(payable(_uniV3Npm.WETH9()));
    }

    /// @inheritdoc IAUniswapV3NPM
    function mint(INonfungiblePositionManager.MintParams calldata params)
        external
        override
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        // we require both token being ownable
        _activateToken(params.token0);
        _activateToken(params.token1);

        // we set the allowance to the uniswap position manager
        if (params.amount0Desired > 0) params.token0.safeApprove(address(_uniV3Npm), type(uint256).max);
        if (params.amount1Desired > 0) params.token1.safeApprove(address(_uniV3Npm), type(uint256).max);

        // only then do we mint the liquidity token
        (tokenId, liquidity, amount0, amount1) = _uniV3Npm.mint(
            INonfungiblePositionManager.MintParams({
                token0: params.token0,
                token1: params.token1,
                fee: params.fee,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                amount0Desired: params.amount0Desired,
                amount1Desired: params.amount1Desired,
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min,
                recipient: address(this), // this pool is always the recipient
                deadline: params.deadline
            })
        );

        // we make sure we do not clear storage
        if (params.amount0Desired > 0) params.token0.safeApprove(address(_uniV3Npm), uint256(1));
        if (params.amount1Desired > 0) params.token1.safeApprove(address(_uniV3Npm), uint256(1));

        _processTokenId(tokenId, OperationType.Mint);
    }

    /// @inheritdoc IAUniswapV3NPM
    function increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams calldata params)
        external
        override
        returns (
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        assert(_uniV3Npm.ownerOf(params.tokenId) == address(this));
        (, , address token0, address token1, , , , , , , , ) = _uniV3Npm.positions(
            params.tokenId
        );

        // we require both tokens being whitelisted
        _activateToken(token0);
        _activateToken(token1);

        // we first set the allowance to the uniswap position manager
        if (params.amount0Desired > 0) token0.safeApprove(address(_uniV3Npm), type(uint256).max);
        if (params.amount1Desired > 0) token1.safeApprove(address(_uniV3Npm), type(uint256).max);

        // finally, we add to the liquidity token
        (liquidity, amount0, amount1) = _uniV3Npm.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: params.tokenId,
                amount0Desired: params.amount0Desired,
                amount1Desired: params.amount1Desired,
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min,
                deadline: params.deadline
            })
        );

        // we make sure we do not clear storage
        if (params.amount0Desired > 0) token0.safeApprove(address(_uniV3Npm), uint256(1));
        if (params.amount1Desired > 0) token1.safeApprove(address(_uniV3Npm), uint256(1));

        _processTokenId(params.tokenId, OperationType.Increase);
    }

    /// @inheritdoc IAUniswapV3NPM
    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata params)
        external
        override
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = _uniV3Npm.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: params.tokenId,
                liquidity: params.liquidity,
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min,
                deadline: params.deadline
            })
        );
    }

    /// @inheritdoc IAUniswapV3NPM
    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        override
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = _uniV3Npm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: params.tokenId,
                recipient: address(this), // this pool is always the recipient
                amount0Max: params.amount0Max,
                amount1Max: params.amount1Max
            })
        );
    }

    /// @inheritdoc IAUniswapV3NPM
    function burn(uint256 tokenId) external override {
        _uniV3Npm.burn(tokenId);
        _processTokenId(tokenId, OperationType.Burn);
    }

    /// @inheritdoc IAUniswapV3NPM
    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external override returns (address pool) {
        pool = _uniV3Npm.createAndInitializePoolIfNecessary(
            token0,
            token1,
            fee,
            sqrtPriceX96
        );
    }

    function _activateToken(address token) internal {
        AddressSet storage values = StorageLib.activeTokensSet();

        // update storage with new token
        values.addUnique(IEOracle(address(this)), token, StorageLib.pool().baseToken);
    }

    function _processTokenId(uint256 tokenId, OperationType opType) private {
        TokenIdsSlot storage idsSlot = StorageLib.uniV3TokenIdsSlot();

        if (opType == OperationType.Mint) {
            // mint reverts if tokenId exists, so we can be sure it is unique
            uint256 storedLength = idsSlot.tokenIds.length;
            require(storedLength < 256, UniV3PositionsLimitExceeded());

            // if position is minted and burnt in the same call, storage is updated on both operations
            // sync up to 32 pre-existing positions
            if (storedLength == 0) {
                // activate uniV3 liquidity application
                StorageLib.activeApplications().storeApplication(uint256(Applications.UNIV3_LIQUIDITY));

                uint256 numPositions = IERC721(address(_uniV3Npm)).balanceOf(address(this));
                numPositions = numPositions < 32 ? numPositions : 32;

                for (uint256 i = 0; i < numPositions; i++) {
                    uint256 existingTokenId = IERC721(address(_uniV3Npm)).tokenOfOwnerByIndex(address(this), i);

                    // store positions and exit the loop if we are in sync
                    if (existingTokenId != tokenId) {
                        // increase counter. Position 0 is reserved flag for removed position
                        idsSlot.positions[existingTokenId] = ++storedLength;
                        idsSlot.tokenIds.push(existingTokenId);
                    } else {
                        break;
                    }
                }
            }

            // increase counter
            idsSlot.positions[tokenId] = ++storedLength;
            idsSlot.tokenIds.push(tokenId);
        } else {
            if (opType == OperationType.Increase) {
                require(idsSlot.positions[tokenId] != 0, PositionOwner());
                return;
            } else if (opType == OperationType.Burn) {
                uint256 position = idsSlot.positions[tokenId];

                if (position != 0) {
                    uint256 idIndex = position - 1;
                    uint256 lastIndex = idsSlot.tokenIds.length - 1;

                    if (idIndex != lastIndex) {
                        idsSlot.tokenIds[idIndex] = lastIndex;
                        idsSlot.positions[lastIndex] = position;
                    }

                    idsSlot.positions[tokenId] = 0;
                    idsSlot.tokenIds.pop();

                    // remove application in proxy persistent storage. Application must be active after first position mint.
                    if (lastIndex == 0) {
                        // remove uniV3 liquidity application
                        StorageLib.activeApplications().removeApplication(uint256(Applications.UNIV3_LIQUIDITY));
                    }
                }
            }
        }
    }
}
