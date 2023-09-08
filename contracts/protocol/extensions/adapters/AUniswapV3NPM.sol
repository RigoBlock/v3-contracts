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
pragma solidity 0.8.17;

import "./interfaces/IAUniswapV3NPM.sol";
import "../../interfaces/IWETH9.sol";
import "../../../utils/exchanges/uniswap/INonfungiblePositionManager/INonfungiblePositionManager.sol";

/// @title AUniswapV3NPM - Allows interactions with the Uniswap NPM contract.
/// @author Gabriele Rigo - <gab@rigoblock.com>
abstract contract AUniswapV3NPM is IAUniswapV3NPM {
    /// @inheritdoc IAUniswapV3NPM
    function mint(INonfungiblePositionManager.MintParams memory params)
        external
        override
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        // we require both token being whitelisted
        _assertTokenWhitelisted(params.token0);
        _assertTokenWhitelisted(params.token1);
        address uniswapNpm = _getUniswapNpm();

        // we set the allowance to the uniswap position manager
        if (params.amount0Desired > 0) _safeApprove(params.token0, uniswapNpm, type(uint256).max);
        if (params.amount1Desired > 0) _safeApprove(params.token1, uniswapNpm, type(uint256).max);

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
        if (params.amount0Desired > 0) _safeApprove(params.token0, uniswapNpm, uint256(1));
        if (params.amount1Desired > 0) _safeApprove(params.token1, uniswapNpm, uint256(1));
    }

    /// @inheritdoc IAUniswapV3NPM
    function increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams memory params)
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
        _assertTokenWhitelisted(token0);
        _assertTokenWhitelisted(token1);

        // we first set the allowance to the uniswap position manager
        if (params.amount0Desired > 0) _safeApprove(token0, uniswapNpm, type(uint256).max);
        if (params.amount1Desired > 0) _safeApprove(token1, uniswapNpm, type(uint256).max);

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
        if (params.amount0Desired > 0) _safeApprove(token0, uniswapNpm, uint256(1));
        if (params.amount1Desired > 0) _safeApprove(token1, uniswapNpm, uint256(1));
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
    function collect(INonfungiblePositionManager.CollectParams memory params)
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

    function _assertTokenWhitelisted(address token) internal view virtual {}

    function _safeApprove(
        address token,
        address spender,
        uint256 value
    ) internal virtual {}

    function _getUniswapNpm() internal view virtual returns (address) {}
}
