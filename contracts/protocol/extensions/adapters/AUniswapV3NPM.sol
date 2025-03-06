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
import {ApplicationsLib, ApplicationsSlot} from "../../libraries/ApplicationsLib.sol";
import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";
import {StorageLib} from "../../libraries/StorageLib.sol";
import {IWETH9} from "../../interfaces/IWETH9.sol";
import {Applications, TokenIdsSlot} from "../../types/Applications.sol";
import {IAUniswapV3NPM} from "./interfaces/IAUniswapV3NPM.sol";

/// @title AUniswapV3NPM - Allows interactions with the Uniswap NPM contract.
/// @author Gabriele Rigo - <gab@rigoblock.com>
abstract contract AUniswapV3NPM is IAUniswapV3NPM {
    using ApplicationsLib for ApplicationsSlot;
    using SafeTransferLib for address;

    error UniV3PositionsLimitExceeded();
    error PositionOwner();

    enum OperationType {
        Mint,
        Increase,
        Burn
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
        _assertTokenOwnable(params.token0);
        _assertTokenOwnable(params.token1);
        address uniswapNpm = _getUniswapNpm();

        // we set the allowance to the uniswap position manager
        if (params.amount0Desired > 0) params.token0.safeApprove(uniswapNpm, type(uint256).max);
        if (params.amount1Desired > 0) params.token1.safeApprove(uniswapNpm, type(uint256).max);

        // only then do we mint the liquidity token
        (tokenId, liquidity, amount0, amount1) = INonfungiblePositionManager(uniswapNpm).mint(
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
        if (params.amount0Desired > 0) params.token0.safeApprove(uniswapNpm, uint256(1));
        if (params.amount1Desired > 0) params.token1.safeApprove(uniswapNpm, uint256(1));

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
        address uniswapNpm = _getUniswapNpm();
        assert(INonfungiblePositionManager(uniswapNpm).ownerOf(params.tokenId) == address(this));
        (, , address token0, address token1, , , , , , , , ) = INonfungiblePositionManager(uniswapNpm).positions(
            params.tokenId
        );

        // we require both tokens being whitelisted
        _assertTokenOwnable(token0);
        _assertTokenOwnable(token1);

        // we first set the allowance to the uniswap position manager
        if (params.amount0Desired > 0) token0.safeApprove(uniswapNpm, type(uint256).max);
        if (params.amount1Desired > 0) token1.safeApprove(uniswapNpm, type(uint256).max);

        // finally, we add to the liquidity token
        (liquidity, amount0, amount1) = INonfungiblePositionManager(uniswapNpm).increaseLiquidity(
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
        if (params.amount0Desired > 0) token0.safeApprove(uniswapNpm, uint256(1));
        if (params.amount1Desired > 0) token1.safeApprove(uniswapNpm, uint256(1));

        _processTokenId(params.tokenId, OperationType.Increase);
    }

    /// @inheritdoc IAUniswapV3NPM
    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata params)
        external
        override
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = INonfungiblePositionManager(_getUniswapNpm()).decreaseLiquidity(
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
        (amount0, amount1) = INonfungiblePositionManager(_getUniswapNpm()).collect(
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
        INonfungiblePositionManager(_getUniswapNpm()).burn(tokenId);
        _processTokenId(tokenId, OperationType.Burn);
    }

    /// @inheritdoc IAUniswapV3NPM
    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external override returns (address pool) {
        pool = INonfungiblePositionManager(_getUniswapNpm()).createAndInitializePoolIfNecessary(
            token0,
            token1,
            fee,
            sqrtPriceX96
        );
    }

    function _assertTokenOwnable(address token) internal virtual {}

    function _getUniswapNpm() internal view virtual returns (address) {}

    function _processTokenId(uint256 tokenId, OperationType opType) private {
        TokenIdsSlot storage idsSlot = StorageLib.uniV3TokenIdsSlot();

        if (opType == OperationType.Mint) {
            // mint reverts if tokenId exists, so we can be sure it is unique
            uint256 storedLength = idsSlot.tokenIds.length;
            require(storedLength < 256, UniV3PositionsLimitExceeded());

            // sync up to 100 pre-existing positions
            if (storedLength == 0) {
                uint256 numPositions = IERC721(_getUniswapNpm()).balanceOf(address(this));
                numPositions = numPositions < 100 ? numPositions : 100;

                for (uint256 i = 0; i < numPositions; i++) {
                    uint256 existingTokenId = IERC721(_getUniswapNpm()).tokenOfOwnerByIndex(address(this), i);

                    // store positions and exit the loop if we are in sync
                    if (existingTokenId != tokenId) {
                        idsSlot.positions[existingTokenId] = ++storedLength;
                        idsSlot.tokenIds.push(existingTokenId);
                    } else {
                        break;
                    }
                }
            }

            // position 0 is flag for removed
            idsSlot.positions[tokenId] = ++storedLength;
            idsSlot.tokenIds.push(tokenId);
            return;
        } else {
            if (opType == OperationType.Increase) {
                require(idsSlot.positions[tokenId] != 0, PositionOwner());
                return;
            } else if (opType == OperationType.Burn) {
                if (idsSlot.positions[tokenId] != 0) {
                    idsSlot.positions[tokenId] = 0;
                    idsSlot.tokenIds.pop();
                    return;
                }
            }
        }

        // activate/remove application in proxy persistent storage.
        uint256 appsBitmap = StorageLib.activeApplications().packedApplications;
        uint256 appFlag = uint256(Applications.UNIV3_LIQUIDITY);
        bool isActiveApp = ApplicationsLib.isActiveApplication(appsBitmap, appFlag);

        // we update application status after all tokenIds have been processed
        if (StorageLib.uniV3TokenIdsSlot().tokenIds.length > 0) {
            if (!isActiveApp) {
                // activate uniV3 liquidity application
                StorageLib.activeApplications().storeApplication(appFlag);
            }
        } else {
            if (isActiveApp) {
                // remove uniV4 liquidity application
                StorageLib.activeApplications().removeApplication(appFlag);
            }
        }
    }
}
