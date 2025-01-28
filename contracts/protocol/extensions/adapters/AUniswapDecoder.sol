// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2024 Rigo Intl.

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

import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {NativeWrapper} from "@uniswap/v4-periphery/src/base/NativeWrapper.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAUniswapRouter} from "./interfaces/IAUniswapRouter.sol";
import {BytesLib} from "./lib/uni-v3/BytesLib.sol";

abstract contract AUniswapDecoder {
    using BytesLib for bytes;
    using TransientStateLibrary for IPoolManager;

    error InvalidCommandType(uint256 commandType);

    /// @dev Only pools that do not have access to liquidity at removal are supported
    error LiquidityMintHookError(address hook);

    address internal constant ZERO_ADDRESS = address(0);

    // TODO: check what the skip flag is used for
    // if seems we should pass it to input state when we do not have to store?
    address internal constant SKIP_FLAG = address(1);

    function positionManager() public view virtual returns (address);

    /// @dev Decodes the input for a command.
    /// @param commandType The command type to decode.
    /// @param inputs The encoded input data.
    /// @return params containing relevant outputs.
    function _decodeInput(
        bytes1 commandType,
        bytes calldata inputs,
        IAUniswapRouter.Parameters memory params
    ) internal returns (IAUniswapRouter.Parameters memory) {
        uint256 command = uint8(commandType & Commands.COMMAND_TYPE_MASK);

        // TODO: uni v4 uses native eth for swaps, whenever the tokenIn is eth, swaps are going to be exactIn,
        // and determined amount is the value that goes into the router. Check how universal router forwards eth.

        // 0x00 <= command < 0x21
        if (command < Commands.EXECUTE_SUB_PLAN) {
            // 0x00 <= command < 0x10
            if (command < Commands.V4_SWAP) {
                // 0x00 <= command < 0x08
                if (command < Commands.V2_SWAP_EXACT_IN) {
                    if (command == Commands.V3_SWAP_EXACT_IN) {
                        (
                            address recipient,
                            ,
                            ,
                            ,
                            /*uint256 amountIn*/ /*uint256 amountOutMin*/ /*bytes memory path*/ bool payerIsUser
                        ) = abi.decode(inputs, (address, uint256, uint256, bytes, bool));
                        assert(payerIsUser);
                        bytes calldata path = inputs.toBytes(3);
                        params.tokensIn = _addUnique(params.tokensIn, path.toAddress());
                        params.tokensOut = _addUnique(params.tokensOut, path.toBytes(path.length - 20).toAddress());
                        params.recipients = _addUnique(params.recipients, recipient);
                    } else if (command == Commands.V3_SWAP_EXACT_OUT) {
                        (
                            address recipient,
                            ,
                            ,
                            ,
                            /*uint256 amountOut*/ /*uint256 amountInMax*/ /*bytes memory path*/ bool payerIsUser
                        ) = abi.decode(inputs, (address, uint256, uint256, bytes, bool));
                        assert(payerIsUser);
                        bytes calldata path = inputs.toBytes(3);
                        params.tokensOut = _addUnique(params.tokensOut, path.toAddress());
                        params.tokensOut = _addUnique(params.tokensIn, path.toBytes(path.length - 20).toAddress());
                        params.recipients = _addUnique(params.recipients, recipient);
                    } else if (command == Commands.PERMIT2_TRANSFER_FROM) {
                        revert InvalidCommandType(command);
                    } else if (command == Commands.PERMIT2_PERMIT_BATCH) {
                        revert InvalidCommandType(command);
                    } else if (command == Commands.SWEEP) {
                        (, /*address token*/ address recipient /*uint160 amountMin*/, ) = abi.decode(
                            inputs,
                            (address, address, uint256)
                        );
                        // sweep is used when the router is used for transfers to clear leftover
                        params.recipients = _addUnique(params.recipients, recipient);
                    } else if (command == Commands.TRANSFER) {
                        // TODO: check should validate token
                        (, /*address token*/ address recipient /*uint256 value*/, ) = abi.decode(
                            inputs,
                            (address, address, uint256)
                        );
                        params.recipients = _addUnique(params.recipients, recipient);
                    } else if (command == Commands.PAY_PORTION) {
                        // TODO: check what this does and if should early return
                        // TODO: check should validate token
                        (, /*address token*/ address recipient /*uint256 bips*/, ) = abi.decode(
                            inputs,
                            (address, address, uint256)
                        );
                        params.recipients = _addUnique(params.recipients, recipient);
                    } else {
                        // placeholder area for command 0x07
                        revert InvalidCommandType(command);
                    }
                } else {
                    // 0x08 <= command < 0x10
                    if (command == Commands.V2_SWAP_EXACT_IN) {
                        (
                            address recipient,
                            uint256 amountIn,
                            ,
                            ,
                            /*uint256 amountOutMin*/ /*bytes memory path*/ bool payerIsUser
                        ) = abi.decode(inputs, (address, uint256, uint256, bytes, bool));
                        // TODO: for native, payer can be router. Probably this check is unnecessary
                        assert(payerIsUser);
                        address[] calldata path = inputs.toAddressArray(3);
                        params.tokensIn = _addUnique(params.tokensIn, path[0]);
                        params.tokensOut = _addUnique(params.tokensOut, path[path.length - 1]);
                        params.recipients = _addUnique(params.recipients, recipient);
                        params.value += path[0] == ZERO_ADDRESS ? amountIn : 0;
                    } else if (command == Commands.V2_SWAP_EXACT_OUT) {
                        (
                            address recipient,
                            ,
                            /*uint256 amountOut*/ uint256 amountInMax,
                            ,
                            /*bytes memory path*/ bool payerIsUser
                        ) = abi.decode(inputs, (address, uint256, uint256, bytes, bool));
                        // TODO: payer could be router for native swaps. This assertion could be unnecessary.
                        assert(payerIsUser);
                        address[] calldata path = inputs.toAddressArray(3);
                        // TODO: check order in/out is correct
                        params.tokensIn = _addUnique(params.tokensIn, path[0]);
                        params.tokensOut = _addUnique(params.tokensOut, path[path.length - 1]);
                        params.recipients = _addUnique(params.recipients, recipient);
                        // TODO: verify that excess native amount is returned after swaps concluded
                        params.value += path[0] == ZERO_ADDRESS ? amountInMax : 0;
                    } else if (command == Commands.PERMIT2_PERMIT) {
                        revert InvalidCommandType(command);
                    } else if (command == Commands.WRAP_ETH) {
                        (address recipient, uint256 amount) = abi.decode(inputs, (address, uint256));
                        params.recipients = _addUnique(params.recipients, recipient);
                        params.tokensOut = _addUnique(
                            params.tokensOut,
                            address(NativeWrapper(payable(positionManager())).WETH9())
                        );
                        params.value += amount;
                    } else if (command == Commands.UNWRAP_WETH) {
                        (address recipient /*uint256 amountMin*/, ) = abi.decode(inputs, (address, uint256));
                        params.tokensOut = _addUnique(params.tokensOut, ZERO_ADDRESS);
                        params.recipients = _addUnique(params.recipients, recipient);
                    } else if (command == Commands.PERMIT2_TRANSFER_FROM_BATCH) {
                        revert InvalidCommandType(command);
                    } else if (command == Commands.BALANCE_CHECK_ERC20) {
                        // TODO: check if we need this one, as it is read only (verify)
                        (address owner, address token /*uint256 minBalance*/, ) = abi.decode(
                            inputs,
                            (address, address, uint256)
                        );
                        // TODO: check if this assertion is needed, as we need to prevent a call to an arbitrary external
                        // contract, which could be a rogue contract
                        params.tokensOut = _addUnique(params.tokensOut, token);
                        params.recipients = _addUnique(params.recipients, owner);
                    } else {
                        // placeholder area for command 0x0f
                        revert InvalidCommandType(command);
                    }
                }
            } else {
                // 0x10 <= command < 0x21
                if (command == Commands.V4_SWAP) {
                    (bytes memory actions, bytes[] memory encodedParams) = abi.decode(inputs, (bytes, bytes[]));

                    uint256 numActions = actions.length;
                    assert(numActions == encodedParams.length);

                    for (uint256 actionIndex = 0; actionIndex < numActions; actionIndex++) {
                        uint256 action = uint8(actions[actionIndex]);
                        bytes memory paramsAtIndex = encodedParams[actionIndex];

                        if (action < Actions.SETTLE) {
                            // TODO: if we only append approvals and requirements in settlement, i.e. payments actions, we can
                            // save gas by avoiding unnecessary approvals and checks. However must make sure recipient is this.
                            if (action == Actions.SWAP_EXACT_IN) {
                                IV4Router.ExactInputParams memory swapParams = abi.decode(
                                    paramsAtIndex,
                                    (IV4Router.ExactInputParams)
                                );
                                uint256 pathLength = swapParams.path.length;
                                params.tokensIn = _addUnique(params.tokensIn, Currency.unwrap(swapParams.currencyIn));
                                params.tokensOut = _addUnique(
                                    params.tokensOut,
                                    Currency.unwrap(swapParams.path[pathLength - 1].intermediateCurrency)
                                );
                            } else if (action == Actions.SWAP_EXACT_IN_SINGLE) {
                                IV4Router.ExactInputSingleParams memory swapParams = abi.decode(
                                    paramsAtIndex,
                                    (IV4Router.ExactInputSingleParams)
                                );
                                params.tokensIn = _addUnique(
                                    params.tokensIn,
                                    Currency.unwrap(swapParams.poolKey.currency0)
                                );
                                params.tokensOut = _addUnique(
                                    params.tokensOut,
                                    Currency.unwrap(swapParams.poolKey.currency1)
                                );
                            } else if (action == Actions.SWAP_EXACT_OUT) {
                                IV4Router.ExactOutputParams memory swapParams = abi.decode(
                                    paramsAtIndex,
                                    (IV4Router.ExactOutputParams)
                                );
                                uint256 pathLength = swapParams.path.length;
                                params.tokensOut = _addUnique(
                                    params.tokensOut,
                                    Currency.unwrap(swapParams.currencyOut)
                                );
                                params.tokensIn = _addUnique(
                                    params.tokensIn,
                                    Currency.unwrap(swapParams.path[pathLength - 1].intermediateCurrency)
                                );
                            } else if (action == Actions.SWAP_EXACT_OUT_SINGLE) {
                                IV4Router.ExactOutputSingleParams memory swapParams = abi.decode(
                                    paramsAtIndex,
                                    (IV4Router.ExactOutputSingleParams)
                                );
                                // TODO: verify ordering on tokens
                                params.tokensOut = _addUnique(
                                    params.tokensOut,
                                    Currency.unwrap(swapParams.poolKey.currency0)
                                );
                                params.tokensIn = _addUnique(
                                    params.tokensIn,
                                    Currency.unwrap(swapParams.poolKey.currency1)
                                );
                            }
                        } else {
                            // TODO: verify we need to append tokensIn, tokensOut here, as already appended in swap actions
                            if (action == Actions.SETTLE_PAIR) {
                                // TODO: verify we cannot decode recipient, i.e. not an input for settle
                                (Currency currency0, Currency currency1) = abi.decode(
                                    paramsAtIndex,
                                    (Currency, Currency)
                                );
                                params.tokensOut = _addUnique(params.tokensIn, Currency.unwrap(currency0));
                                params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(currency1));
                                // TODO: verify initialization as address or instance
                                int256 amount = IPositionManager(positionManager()).poolManager().currencyDelta(
                                    address(this),
                                    currency0
                                );
                                params.value += Currency.unwrap(currency0) == ZERO_ADDRESS && amount < 0
                                    ? uint256(-amount)
                                    : 0;
                            } else if (action == Actions.TAKE_PAIR) {
                                // we still require both tokens to have a price feed, even though we could skip check but for recipient
                                (Currency currency0, Currency currency1, address recipient) = abi.decode(
                                    paramsAtIndex,
                                    (Currency, Currency, address)
                                );
                                params.tokensOut = _addUnique(params.tokensIn, Currency.unwrap(currency0));
                                params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(currency1));
                                params.recipients = _addUnique(params.recipients, recipient);
                            } else if (action == Actions.SETTLE) {
                                (Currency currency, uint256 amount /*bool payerIsUser*/, ) = abi.decode(
                                    paramsAtIndex,
                                    (Currency, uint256, bool)
                                );
                                params.tokensOut = _addUnique(params.tokensIn, Currency.unwrap(currency));
                                params.value += Currency.unwrap(currency) == ZERO_ADDRESS ? amount : 0;
                            } else if (action == Actions.TAKE) {
                                (Currency currency, address recipient /*uint256 amount*/, ) = abi.decode(
                                    paramsAtIndex,
                                    (Currency, address, uint256)
                                );
                                params.tokensOut = _addUnique(params.tokensIn, Currency.unwrap(currency));
                                params.recipients = _addUnique(params.recipients, recipient);
                            } else if (action == Actions.CLOSE_CURRENCY) {
                                // Handles either direction based on final delta
                                // TODO: in these methods, we should check if simply return to skip checks if possible
                                // technically, should append value if neg delta and native, approve if neg delta and not native
                                // should check how often we will use this
                                Currency currency = abi.decode(paramsAtIndex, (Currency));
                                params.tokensOut = _addUnique(params.tokensIn, Currency.unwrap(currency));
                            } else if (action == Actions.CLEAR_OR_TAKE) {
                                (Currency currency /*uint256 amountMax*/, ) = abi.decode(
                                    paramsAtIndex,
                                    (Currency, uint256)
                                );
                                params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(currency));
                            } else if (action == Actions.SWEEP) {
                                (Currency currency, address to) = abi.decode(paramsAtIndex, (Currency, address));
                                params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(currency));
                                params.recipients = _addUnique(params.recipients, to);
                            }
                        }
                    }
                } else if (command == Commands.V3_POSITION_MANAGER_PERMIT) {
                    revert InvalidCommandType(command);
                } else if (command == Commands.V3_POSITION_MANAGER_CALL) {
                    // v3 calls are used to migrate liquidity only, no further actions or assertions are necessary. Migration supported methods are:
                    //  decreaseLiquidity, collect, burn
                    // @notice do not use with an older universal router, as would allow pool to add to non-owned positions
                } else if (command == Commands.V4_POSITION_MANAGER_CALL) {
                    // should only call modifyLiquidities() to mint
                    // do not permit or approve this contract over a v4 position or someone could use this command to decrease, burn, or transfer your position
                    (bytes memory actions, bytes[] memory encodedParams) = abi.decode(inputs, (bytes, bytes[]));

                    uint256 numActions = actions.length;
                    assert(numActions == encodedParams.length);

                    for (uint256 actionIndex = 0; actionIndex < numActions; actionIndex++) {
                        uint256 action = uint8(actions[actionIndex]);
                        bytes memory paramsAtIndex = encodedParams[actionIndex];

                        // TODO: in uni V4, only position owner can modify liquiity, assert
                        // TODO: verify how we extract value if currency is eth
                        if (action == Actions.INCREASE_LIQUIDITY) {
                            (
                                uint256 tokenId /*uint256 liquidity*/,
                                ,
                                uint128 amount0Max /*uint128 amount1Max*/ /*bytes memory hookData*/,
                                ,

                            ) = abi.decode(paramsAtIndex, (uint256, uint256, uint128, uint128, bytes));
                            (PoolKey memory poolKey /*PositionInfo*/, ) = IPositionManager(positionManager())
                                .getPoolAndPositionInfo(tokenId);
                            params.tokensIn = _addUnique(params.tokensIn, Currency.unwrap(poolKey.currency0));
                            params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(poolKey.currency0));
                            params.tokensIn = _addUnique(params.tokensIn, Currency.unwrap(poolKey.currency1));
                            params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(poolKey.currency1));
                            params.value += Currency.unwrap(poolKey.currency0) == ZERO_ADDRESS ? amount0Max : 0;
                            // TODO: this method allows using deltas to swap instead of transferring erc20s. If we support this, we must
                            // also make sure ERC6909 balances are correctly returned by the EApps contract
                            // TODO: the following method is not implemented in the deployed uni package, but it is in uni universal dev
                            //} else if (action == Actions.INCREASE_LIQUIDITY_FROM_DELTAS) {
                            //    (uint256 tokenId, uint128 amount0Max, uint128 amount1Max, bytes calldata hookData) =
                            //    abi.decode(paramsAtIndex, (uint256, uint128, uint128, bytes));
                            //    (PoolKey memory poolKey, /*PositionInfo*/) = IPositionManager(positionManager()).getPoolAndPositionInfo(tokenId);
                            //    // TODO: return owner as recipient if stored in PositionInfo
                            //    params.tokensIn = _addUnique(params.tokensIn, Currency.unwrap(poolKey.currency0));
                            //    params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(poolKey.currency1));
                        } else if (action == Actions.DECREASE_LIQUIDITY) {
                            // skip this command (not yet implemented in uniswap v4)
                        } else if (action == Actions.MINT_POSITION) {
                            // TODO: with mint and increase we might not need to require tokens out whitelisted, but must ensure using a rogue
                            //  token as input does not result in side effects, i.e. reentrancies, attacks, ...
                            (
                                PoolKey memory poolKey /*int24 tickLower*/ /*int24 tickUpper*/ /*uint256 liquidity*/,
                                ,
                                ,
                                ,
                                uint128 amount0Max /*uint128 amount1Max*/,
                                ,
                                address owner /*bytes memory hookData*/,

                            ) = abi.decode(
                                    paramsAtIndex,
                                    (PoolKey, int24, int24, uint256, uint128, uint128, address, bytes)
                                );

                            // TODO: verify why we cannot query afterRemoveLiquidityReturnDelta
                            // we do not allow adding liquidity to pools that have access to liquidity when removing it
                            //require(
                            //    !poolKey.hooks.afterRemoveLiquidityReturnDelta,
                            //    LiquidityMintHookError(address(poolKey.hooks))
                            //);
                            params.tokensIn = _addUnique(params.tokensIn, Currency.unwrap(poolKey.currency0));
                            params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(poolKey.currency0));
                            params.tokensIn = _addUnique(params.tokensIn, Currency.unwrap(poolKey.currency1));
                            params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(poolKey.currency1));
                            params.recipients = _addUnique(params.recipients, owner);
                            params.tokenIds = _addUnique(
                                params.tokenIds,
                                IPositionManager(positionManager()).nextTokenId(),
                                true
                            );
                            params.value += Currency.unwrap(poolKey.currency0) == ZERO_ADDRESS ? amount0Max : 0;
                        } else if (action == Actions.BURN_POSITION) {
                            // TODO: check if has been implemented in universal router
                            // skip this action (not yet implemented in uniswap v4). When burning, remember to remove tokenId from proxy storage
                            //params.tokenIds = _addUnique(params.tokenIds, IPositionManager(positionManager()).nextTokenId(), false);
                        }
                    }
                } else {
                    // placeholder area for commands 0x13-0x20
                    revert InvalidCommandType(command);
                }
            }
        } else {
            // 0x21 <= command
            if (command == Commands.EXECUTE_SUB_PLAN) {
                (bytes memory subCommands, bytes[] memory subInputs) = abi.decode(inputs, (bytes, bytes[]));
                return IAUniswapRouter(address(this)).execute(subCommands, subInputs);
            }
        }
        return params;
    }

    function _addUnique(address[] memory array, address target) private pure returns (address[] memory) {
        for (uint256 i = 0; i < array.length; i++) {
            if (array[i] == target) {
                return array; // Already exists, return unchanged array
            }
        }
        address[] memory newArray = new address[](array.length + 1);
        for (uint256 i = 0; i < array.length; i++) {
            newArray[i] = array[i];
        }
        newArray[array.length] = target;
        return newArray;
    }

    function _addUnique(int256[] memory array, uint256 id, bool isMint) private pure returns (int256[] memory) {
        for (uint256 i = 0; i < array.length; i++) {
            if (array[i] == int256(id)) {
                return array; // Already exists, return unchanged array
            }
        }
        int256[] memory newArray = new int256[](array.length + 1);
        for (uint256 i = 0; i < array.length; i++) {
            newArray[i] = array[i];
        }

        // negative value is sentinel for closed position
        newArray[array.length] = isMint ? int256(id) : -int256(id);
        return newArray;
    }
}
