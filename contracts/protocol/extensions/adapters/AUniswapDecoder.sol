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

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
// TODO: verify git submodule updated, as Actions library has changed
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {CalldataDecoder} from "@uniswap/v4-periphery/src/libraries/CalldataDecoder.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {BytesLib} from '@uniswap/universal-router/contracts/modules/uniswap/v3/BytesLib.sol';
import {IAUniswapRouter} from "./interfaces/IAUniswapRouter.sol";

interface IHook {
    function getHookPermissions() external pure returns (Hooks.Permissions memory);
}

abstract contract AUniswapDecoder {
    using BytesLib for bytes;
    using TransientStateLibrary for IPoolManager;
    using CalldataDecoder for bytes;

    error InvalidCommandType(uint256 commandType);
    error UnsupportedAction(uint256 action);

    /// @dev Only pools that do not have access to liquidity at removal are supported
    error LiquidityMintHookError(address hook);

    address internal constant ZERO_ADDRESS = address(0);
    address private immutable _wrappedNative;

    constructor(address wrappedNative) {
        _wrappedNative = wrappedNative;
    }

    function uniV4Posm() public view virtual returns (IPositionManager);

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

        // 0x00 <= command < 0x21
        if (command < Commands.EXECUTE_SUB_PLAN) {
            // 0x00 <= command < 0x10
            if (command < Commands.V4_SWAP) {
                // 0x00 <= command < 0x08
                if (command < Commands.V2_SWAP_EXACT_IN) {
                    if (command == Commands.V3_SWAP_EXACT_IN) {
                        // address recipient, uint256 amountIn, uint256 amountOutMin, bytes memory path, bool payerIsUser
                        (address recipient,,,,) = abi.decode(inputs, (address, uint256, uint256, bytes, bool));
                        bytes calldata path = inputs.toBytes(3);
                        params.recipients = _addUnique(params.recipients, recipient);
                        params.tokensIn = _addUnique(params.tokensIn, path.toAddress());
                        params.tokensOut = _addUnique(params.tokensOut, path.toBytes(path.length - 20).toAddress());
                        params.recipients = _addUnique(params.recipients, recipient);
                        return params;
                    } else if (command == Commands.V3_SWAP_EXACT_OUT) {
                        // address recipient, uint256 amountOut, uint256 amountInMax, bytes memory path, bool payerIsUser
                        (address recipient,,,,) = abi.decode(inputs, (address, uint256, uint256, bytes, bool));
                        bytes calldata path = inputs.toBytes(3);
                        params.recipients = _addUnique(params.recipients, recipient);
                        params.tokensOut = _addUnique(params.tokensOut, path.toAddress());
                        params.tokensIn = _addUnique(params.tokensIn, path.toBytes(path.length - 20).toAddress());
                        params.recipients = _addUnique(params.recipients, recipient);
                        return params;
                    } else if (command == Commands.PERMIT2_TRANSFER_FROM) {
                        revert InvalidCommandType(command);
                    } else if (command == Commands.PERMIT2_PERMIT_BATCH) {
                        revert InvalidCommandType(command);
                    } else if (command == Commands.SWEEP) {
                        // sweep is used when the router is used for transfers to clear leftover
                        // address token, address recipient, uint160 amountMin
                        (address token, address recipient, ) = abi.decode(inputs, (address, address, uint256));
                        params.tokensOut = _addUnique(params.tokensOut, token);
                        params.recipients = _addUnique(params.recipients, recipient);
                        return params;
                    } else if (command == Commands.TRANSFER) {
                        // address token, address recipient, uint256 value
                        (address token, address recipient,) = abi.decode(inputs, (address, address, uint256));
                        params.tokensOut = _addUnique(params.tokensOut, token);
                        params.recipients = _addUnique(params.recipients, recipient);
                        return params;
                    } else if (command == Commands.PAY_PORTION) {
                        // address token, address recipient, uint256 bips
                        (address token, address recipient, ) = abi.decode(inputs, (address, address, uint256));
                        params.tokensOut = _addUnique(params.tokensOut, token);
                        params.recipients = _addUnique(params.recipients, recipient);
                        return params;
                    } else {
                        // placeholder area for command 0x07
                        revert InvalidCommandType(command);
                    }
                } else {
                    // 0x08 <= command < 0x10
                    if (command == Commands.V2_SWAP_EXACT_IN) {
                        // address recipient, uint256 amountIn, uint256 amountOutMin, bytes memory path, bool payerIsUser
                        (address recipient, uint256 amountIn,,,) =
                            abi.decode(inputs, (address, uint256, uint256, bytes, bool));
                        params.recipients = _addUnique(params.recipients, recipient);
                        address[] calldata path = inputs.toAddressArray(3);
                        params.tokensIn = _addUnique(params.tokensIn, path[0]);
                        params.tokensOut = _addUnique(params.tokensOut, path[path.length - 1]);
                        params.recipients = _addUnique(params.recipients, recipient);
                        params.value += path[0] == ZERO_ADDRESS ? amountIn : 0;
                        return params;
                    } else if (command == Commands.V2_SWAP_EXACT_OUT) {
                        // address recipient, uint256 amountOut, uint256 amountInMax, bytes memory path, bool payerIsUser
                        (address recipient,, uint256 amountInMax,,) =
                            abi.decode(inputs, (address, uint256, uint256, bytes, bool));
                        params.recipients = _addUnique(params.recipients, recipient);
                        address[] calldata path = inputs.toAddressArray(3);
                        params.tokensOut = _addUnique(params.tokensOut, path[0]);
                        params.tokensIn = _addUnique(params.tokensIn, path[path.length - 1]);
                        params.recipients = _addUnique(params.recipients, recipient);
                        params.value += path[0] == ZERO_ADDRESS ? amountInMax : 0;
                        return params;
                    } else if (command == Commands.PERMIT2_PERMIT) {
                        revert InvalidCommandType(command);
                    } else if (command == Commands.WRAP_ETH) {
                        (address recipient, uint256 amount) = abi.decode(inputs, (address, uint256));
                        params.recipients = _addUnique(params.recipients, recipient);
                        params.tokensOut = _addUnique(params.tokensOut, _wrappedNative);
                        params.value += amount;
                        return params;
                    } else if (command == Commands.UNWRAP_WETH) {
                        // address recipient, uint256 amountMin
                        (address recipient, ) = abi.decode(inputs, (address, uint256));
                        params.tokensOut = _addUnique(params.tokensOut, ZERO_ADDRESS);
                        params.recipients = _addUnique(params.recipients, recipient);
                        return params;
                    } else if (command == Commands.PERMIT2_TRANSFER_FROM_BATCH) {
                        revert InvalidCommandType(command);
                    } else if (command == Commands.BALANCE_CHECK_ERC20) {
                        // no further assertion needed as uni router uses staticcall
                    } else {
                        // placeholder area for command 0x0f
                        revert InvalidCommandType(command);
                    }
                }
            } else {
                // 0x10 <= command < 0x21
                if (command == Commands.V4_SWAP) {
                    //(bytes memory actions, bytes[] memory encodedParams) = abi.decode(inputs, (bytes, bytes[]));
                    // we decode manually to be able to override params?
                    (bytes calldata actions, bytes[] calldata encodedParams) = inputs.decodeActionsRouterParams();
                    assert(actions.length == encodedParams.length);

                    for (uint256 actionIndex = 0; actionIndex < actions.length; actionIndex++) {
                        uint256 action = uint8(actions[actionIndex]);
                        bytes calldata paramsAtIndex = encodedParams[actionIndex];

                        if (action < Actions.SETTLE) {
                            // no further assertion needed
                            //if (action == Actions.SWAP_EXACT_IN) {
                            //} else if (action == Actions.SWAP_EXACT_IN_SINGLE) {
                            //} else if (action == Actions.SWAP_EXACT_OUT) {
                            //} else if (action == Actions.SWAP_EXACT_OUT_SINGLE) {
                            //}
                        } else {
                            if (action == Actions.SETTLE_PAIR) {
                                revert UnsupportedAction(action);
                            } else if (action == Actions.TAKE_PAIR) {
                                revert UnsupportedAction(action);
                            } else if (action == Actions.SETTLE) {
                                // Currency currency, uint256 amount, bool payerIsUser
                                (Currency currency, uint256 amount,) =
                                    abi.decode(paramsAtIndex, (Currency, uint256, bool));
                                params.tokensIn = _addUnique(params.tokensIn, Currency.unwrap(currency));
                                params.value += Currency.unwrap(currency) == ZERO_ADDRESS ? amount : 0;
                                return params;
                            } else if (action == Actions.TAKE) {
                                // Currency currency, address recipient, uint256 amount
                                (Currency currency, address recipient,) =
                                    abi.decode(paramsAtIndex, (Currency, address, uint256));
                                params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(currency));
                                params.recipients = _addUnique(params.recipients, recipient);
                                return params;
                            } else if (action == Actions.CLOSE_CURRENCY) {
                                // this will either settle or take, so we need to make sure the token is tracked
                                (Currency currency) = paramsAtIndex.decodeCurrency();
                                params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(currency));
                                return params;
                            } else if (action == Actions.CLEAR_OR_TAKE) {
                                // Currency currency, uint256 amountMax
                                (Currency currency,) = paramsAtIndex.decodeCurrencyAndUint256();
                                params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(currency));
                                return params;
                            } else if (action == Actions.SWEEP) {
                                (Currency currency, address to) = paramsAtIndex.decodeCurrencyAndAddress();
                                params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(currency));
                                params.recipients = _addUnique(params.recipients, to);
                                return params;
                            }
                        }
                    }
                } else if (command == Commands.V3_POSITION_MANAGER_PERMIT) {
                    revert InvalidCommandType(command);
                } else if (command == Commands.V3_POSITION_MANAGER_CALL) {
                    revert InvalidCommandType(command);
                } else if (command == Commands.V4_POSITION_MANAGER_CALL) {
                    // v4 liquidity actions must be routed via modifyLiquidities endpoint
                    revert InvalidCommandType(command);
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

    function _decodePosmAction(
        uint256 action,
        bytes calldata actionParams,
        IAUniswapRouter.Parameters memory params
    ) internal view returns (IAUniswapRouter.Parameters memory) {
        if (action < Actions.SETTLE) {
            if (action == Actions.INCREASE_LIQUIDITY) {
                // uint256 tokenId, uint256 liquidity, uint128 amount0Max, uint128 amount1Max, bytes calldata hookData
                (uint256 tokenId,,,,) = actionParams.decodeModifyLiquidityParams();
                params.tokenIds = _addUniqueTokenId(params.tokenIds, -int256(tokenId));
                return params;
            } else if (action == Actions.INCREASE_LIQUIDITY_FROM_DELTAS) {
                revert UnsupportedAction(action);
            } else if (action == Actions.DECREASE_LIQUIDITY) {
                // no further assertion needed when removing liquidity
                return params;
            } else if (action == Actions.MINT_POSITION) {
                // PoolKey calldata poolKey, int24 tickLower, int24 tickUpper, uint256 liquidity, uint128 amount0Max, uint128 amount1Max, address owner, bytes calldata hookData
                (PoolKey calldata poolKey,,,,,, address owner,) = actionParams.decodeMintParams();

                // Assert hook does not have access to deltas
                if (address(poolKey.hooks) != ZERO_ADDRESS) {
                    require(
                        !IHook(address(poolKey.hooks)).getHookPermissions().afterRemoveLiquidityReturnDelta,
                        LiquidityMintHookError(address(poolKey.hooks))
                    );
                }

                // as an amount could be null, we want to assert here that both tokens have a price feed
                params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(poolKey.currency0));
                params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(poolKey.currency1));
                params.recipients = _addUnique(params.recipients, owner);
                params.tokenIds = _addUniqueTokenId(params.tokenIds, int256(uniV4Posm().nextTokenId()));
                return params;
            } else if (action == Actions.MINT_POSITION_FROM_DELTAS) {
                revert UnsupportedAction(action);
            } else if (action == Actions.BURN_POSITION) {
                // uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData
                (uint256 tokenId,,,) = actionParams.decodeBurnParams();
                params.tokenIds = _addUniqueTokenId(params.tokenIds, -int256(tokenId));
                return params;
            }
        } else {
            if (action == Actions.SETTLE_PAIR) {
                // settlement eth value must be retrieved in previous actions
                (Currency currency0, Currency currency1) = actionParams.decodeCurrencyPair();
                params.tokensIn = _addUnique(params.tokensIn, Currency.unwrap(currency0));
                params.tokensIn = _addUnique(params.tokensIn, Currency.unwrap(currency1));
                // TODO: how do we get value for pair here?
                //params.value += Currency.unwrap(currency0) == ZERO_ADDRESS ? amount : 0;
                return params;
            } else if (action == Actions.TAKE_PAIR) {
                (Currency currency0, Currency currency1, address recipient) = actionParams.decodeCurrencyPairAndAddress();
                params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(currency0));
                params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(currency1));
                params.recipients = _addUnique(params.recipients, recipient);
                return params;
            } else if (action == Actions.SETTLE) {
                (Currency currency, uint256 amount,) = actionParams.decodeCurrencyUint256AndBool();
                params.tokensIn = _addUnique(params.tokensIn, Currency.unwrap(currency));
                params.value += Currency.unwrap(currency) == ZERO_ADDRESS ? amount : 0;
                return params;
            } else if (action == Actions.TAKE) {
                (Currency currency, address recipient, /*uint256 amount*/) = actionParams.decodeCurrencyAddressAndUint256();
                params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(currency));
                params.recipients = _addUnique(params.recipients, recipient);
                return params;
            } else if (action == Actions.CLOSE_CURRENCY) {
                // TODO: verify
                revert UnsupportedAction(action);
            } else if (action == Actions.CLEAR_OR_TAKE) {
                // no further assertion needed
                (Currency currency,) = actionParams.decodeCurrencyAndUint256();
                params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(currency));
                return params;
            } else if (action == Actions.SWEEP) {
                (Currency currency, address to) = actionParams.decodeCurrencyAndAddress();
                params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(currency));
                params.recipients = _addUnique(params.recipients, to);
                return params;
            } else if (action == Actions.WRAP) {
                uint256 amount = actionParams.decodeUint256();
                params.tokensOut = _addUnique(params.tokensOut, _wrappedNative);
                params.value += amount;
                return params;
            } else if (action == Actions.UNWRAP) {
                params.tokensOut = _addUnique(params.tokensOut, ZERO_ADDRESS);
                return params;
            }
        }
        revert UnsupportedAction(action);
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

    // TODO: verify we are appending correctly, as we could be appending MINT + INCREASE, meaning same id would be stored twice, but with opposite sign
    function _addUniqueTokenId(int256[] memory array, int256 id) private pure returns (int256[] memory) {
        for (uint256 i = 0; i < array.length; i++) {
            if (array[i] == id) {
                return array; // Already exists, return unchanged array
            }
        }
        int256[] memory newArray = new int256[](array.length + 1);
        for (uint256 i = 0; i < array.length; i++) {
            newArray[i] = array[i];
        }

        newArray[array.length] = id;
        return newArray;
    }
}
