// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2025 Rigo Intl.

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
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {CalldataDecoder} from "@uniswap/v4-periphery/src/libraries/CalldataDecoder.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {BytesLib} from '@uniswap/universal-router/contracts/modules/uniswap/v3/BytesLib.sol';

abstract contract AUniswapDecoder {
    using BytesLib for bytes;
    using TransientStateLibrary for IPoolManager;
    using CalldataDecoder for bytes;

    error InvalidCommandType(uint256 commandType);
    error UnsupportedAction(uint256 action);

    address internal constant ZERO_ADDRESS = address(0);
    address internal constant NON_EXISTENT_POSITION_FLAG = address(1);
    address private immutable _wrappedNative;

    IPositionManager internal immutable _uniV4Posm;

    constructor(address wrappedNative, address v4Posm) {
        _wrappedNative = wrappedNative;
        _uniV4Posm = IPositionManager(v4Posm);
    }

    struct Parameters {
        uint256 value;
        address[] recipients;
        address[] tokensIn;
        address[] tokensOut;
    }

    /// @dev Decodes the input for a command.
    /// @param commandType The command type to decode.
    /// @param inputs The encoded input data.
    /// @return params containing relevant outputs.
    function _decodeInput(
        bytes1 commandType,
        bytes calldata inputs,
        Parameters memory params
    ) internal returns (Parameters memory) {
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
                        // slice last 20 bytes from path to find tokenIn address
                        bytes calldata lastTokenBytes;
                        assembly ("memory-safe") {
                            let lastTokenOffset := sub(add(path.offset, path.length), 20)
                            lastTokenBytes.length := 20
                            lastTokenBytes.offset := lastTokenOffset
                        }
                        params.tokensOut = _addUnique(params.tokensOut, lastTokenBytes.toAddress());
                        params.recipients = _addUnique(params.recipients, recipient);
                        return params;
                    } else if (command == Commands.V3_SWAP_EXACT_OUT) {
                        // address recipient, uint256 amountOut, uint256 amountInMax, bytes memory path, bool payerIsUser
                        (address recipient,,,,) = abi.decode(inputs, (address, uint256, uint256, bytes, bool));
                        bytes calldata path = inputs.toBytes(3);
                        params.recipients = _addUnique(params.recipients, recipient);
                        params.tokensOut = _addUnique(params.tokensOut, path.toAddress());
                        // slice last 20 bytes from path to find tokenIn address
                        bytes calldata lastTokenBytes;
                        assembly ("memory-safe") {
                            let lastTokenOffset := sub(add(path.offset, path.length), 20)
                            lastTokenBytes.length := 20
                            lastTokenBytes.offset := lastTokenOffset
                        }
                        params.tokensIn = _addUnique(params.tokensIn, lastTokenBytes.toAddress());
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
                        (address recipient,,,,) =
                            abi.decode(inputs, (address, uint256, uint256, bytes, bool));
                        params.recipients = _addUnique(params.recipients, recipient);
                        address[] calldata path = inputs.toAddressArray(3);
                        params.tokensOut = _addUnique(params.tokensOut, path[0]);
                        params.tokensIn = _addUnique(params.tokensIn, path[path.length - 1]);
                        params.recipients = _addUnique(params.recipients, recipient);
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
                        return params;
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
                            // we must retrieve native value here, as SETTLE may use flag amounts
                            if (action == Actions.SWAP_EXACT_IN) {
                                IV4Router.ExactInputParams calldata swapParams = paramsAtIndex.decodeSwapExactInParams();
                                params.value += Currency.unwrap(swapParams.currencyIn) == ZERO_ADDRESS ? swapParams.amountIn : 0;
                                continue;
                            } else if (action == Actions.SWAP_EXACT_IN_SINGLE) {
                                IV4Router.ExactInputSingleParams calldata swapParams = paramsAtIndex.decodeSwapExactInSingleParams();
                                params.value += swapParams.zeroForOne && Currency.unwrap(swapParams.poolKey.currency0) == ZERO_ADDRESS
                                    ? swapParams.amountIn
                                    : 0;
                                continue;
                            } else if (action == Actions.SWAP_EXACT_OUT) {
                                continue;
                            } else if (action == Actions.SWAP_EXACT_OUT_SINGLE) {
                                continue;
                            }
                        } else {
                            if (action == Actions.SETTLE_ALL) {
                                (Currency currency, /*uint256 maxAmount*/) = paramsAtIndex.decodeCurrencyAndUint256();
                                params.tokensIn = _addUnique(params.tokensIn, Currency.unwrap(currency));
                                continue;
                            } else if (action == Actions.TAKE_ALL) {
                                (Currency currency,) = paramsAtIndex.decodeCurrencyAndUint256();
                                params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(currency));
                                continue;
                            } else if (action == Actions.SETTLE) {
                                // Currency currency, uint256 amount, bool payerIsUser
                                (Currency currency,,) = paramsAtIndex.decodeCurrencyUint256AndBool();
                                params.tokensIn = _addUnique(params.tokensIn, Currency.unwrap(currency));
                                continue;
                            } else if (action == Actions.TAKE) {
                                (Currency currency, address recipient,) = paramsAtIndex.decodeCurrencyAddressAndUint256();
                                params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(currency));
                                params.recipients = _addUnique(params.recipients, recipient);
                                continue;
                            } else if (action == Actions.TAKE_PORTION) {
                                (Currency currency, address recipient,) = paramsAtIndex.decodeCurrencyAddressAndUint256();
                                params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(currency));
                                params.recipients = _addUnique(params.recipients, recipient);
                                continue;
                            } else {
                                revert UnsupportedAction(action);
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
                (bytes calldata _commands, bytes[] calldata _inputs) = inputs.decodeCommandsAndInputs();

                for (uint256 j = 0; j < _commands.length; j++) {
                    params = _decodeInput(_commands[j], _inputs[j], params);
                }
            } else {
                // placeholder area for commands 0x22-0x3f
                revert InvalidCommandType(command);
            }
        }
        return params;
    }

    /// @notice Each liquidity position has its associated hook address, which can be null if no hook is used.
    struct Position {
        address hook;
        uint256 tokenId;
        uint256 action;
    }

    /// @dev It cannot handle minting and increasing liquidity in the same call, as we run decoding before forwarding the call, hence the position is not
    /// stored, and cannot return pool and position info, which are necessary to append value
    function _decodePosmAction(
        uint256 action,
        bytes calldata actionParams,
        Parameters memory params,
        Position[] memory positions
    ) internal view returns (Parameters memory, Position[] memory) {
        if (action < Actions.SETTLE) {
            if (action == Actions.INCREASE_LIQUIDITY) {
                // uint256 tokenId, uint256 liquidity, uint128 amount0Max, uint128 amount1Max, bytes calldata hookData
                (uint256 tokenId,, uint128 amount0Max,,) = actionParams.decodeModifyLiquidityParams();
                (PoolKey memory poolKey,) = _uniV4Posm.getPoolAndPositionInfo(tokenId);
                address hook = address(poolKey.hooks);

                if (Currency.unwrap(poolKey.currency1) == ZERO_ADDRESS) {
                    hook = NON_EXISTENT_POSITION_FLAG;
                } else {
                    if (Currency.unwrap(poolKey.currency0) == ZERO_ADDRESS) {
                        params.value += amount0Max;
                    }
                }

                positions = _addUniquePosition(positions, Position(hook, tokenId, Actions.INCREASE_LIQUIDITY));
                return (params, positions);
            } else if (action == Actions.INCREASE_LIQUIDITY_FROM_DELTAS) {
                revert UnsupportedAction(action);
            } else if (action == Actions.DECREASE_LIQUIDITY) {
                // uint256 tokenId, uint256 liquidity, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData
                (uint256 tokenId,,,,) = actionParams.decodeModifyLiquidityParams();
                // hook address is not relevant for decrease, use ZERO_ADDRESS instead to save gas
                positions = _addUniquePosition(positions, Position(ZERO_ADDRESS, tokenId, Actions.DECREASE_LIQUIDITY));
                return (params, positions);
            } else if (action == Actions.MINT_POSITION) {
                // PoolKey calldata poolKey, int24 tickLower, int24 tickUpper, uint256 liquidity, uint128 amount0Max, uint128 amount1Max, address owner, bytes calldata hookData
                (PoolKey calldata poolKey,,,, uint128 amount0Max,, address owner,) = actionParams.decodeMintParams();

                // as an amount could be null, we want to assert here that both tokens have a price feed
                params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(poolKey.currency0));
                params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(poolKey.currency1));
                params.recipients = _addUnique(params.recipients, owner);
                params.value += Currency.unwrap(poolKey.currency0) == ZERO_ADDRESS ? amount0Max : 0;
                positions = _addUniquePosition(positions, Position(address(poolKey.hooks), 0, Actions.MINT_POSITION));
                return (params, positions);
            } else if (action == Actions.MINT_POSITION_FROM_DELTAS) {
                revert UnsupportedAction(action);
            } else if (action == Actions.BURN_POSITION) {
                // uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData
                (uint256 tokenId,,,) = actionParams.decodeBurnParams();
                // hook address is not relevant for burn, use ZERO_ADDRESS instead to save gas
                positions = _addUniquePosition(positions, Position(ZERO_ADDRESS, tokenId, Actions.BURN_POSITION));
                return (params, positions);
            } else {
                revert UnsupportedAction(action);
            }
        } else {
            if (action == Actions.SETTLE_PAIR) {
                (Currency currency0, Currency currency1) = actionParams.decodeCurrencyPair();
                params.tokensIn = _addUnique(params.tokensIn, Currency.unwrap(currency0));
                params.tokensIn = _addUnique(params.tokensIn, Currency.unwrap(currency1));
                return (params, positions);
            } else if (action == Actions.TAKE_PAIR) {
                (Currency currency0, Currency currency1, address recipient) = actionParams.decodeCurrencyPairAndAddress();
                params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(currency0));
                params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(currency1));
                params.recipients = _addUnique(params.recipients, recipient);
                return (params, positions);
            } else if (action == Actions.SETTLE) {
                // in posm, SETTLE is usually used with ActionConstants.OPEN_DELTA (i.e. 0)
                // (Currency currency, uint256 amount, bool payerIsUser)
                (Currency currency, uint256 amount,) = actionParams.decodeCurrencyUint256AndBool();
                params.tokensIn = _addUnique(params.tokensIn, Currency.unwrap(currency));
                params.value += Currency.unwrap(currency) == ZERO_ADDRESS ? amount : 0;
                return (params, positions);
            } else if (action == Actions.TAKE) {
                (Currency currency, address recipient,) = actionParams.decodeCurrencyAddressAndUint256();
                params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(currency));
                params.recipients = _addUnique(params.recipients, recipient);
                return (params, positions);
            } else if (action == Actions.CLOSE_CURRENCY) {
                Currency currency = actionParams.decodeCurrency();
                params.tokensIn = _addUnique(params.tokensIn, Currency.unwrap(currency));  
                params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(currency));
            } else if (action == Actions.CLEAR_OR_TAKE) {
                (Currency currency,) = actionParams.decodeCurrencyAndUint256();
                params.tokensIn = _addUnique(params.tokensIn, Currency.unwrap(currency));  
                params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(currency));
                return (params, positions);
            } else if (action == Actions.SWEEP) {
                (Currency currency, address to) = actionParams.decodeCurrencyAndAddress();
                params.tokensOut = _addUnique(params.tokensOut, Currency.unwrap(currency));
                params.recipients = _addUnique(params.recipients, to);
                return (params, positions);
            } else if (action == Actions.WRAP) {
                // TODO: verify if wrap uses amount flag, and if we have already appended value in liquidity action (should not append value here then)
                uint256 amount = actionParams.decodeUint256();
                params.tokensOut = _addUnique(params.tokensOut, _wrappedNative);
                params.value += amount;
                return (params, positions);
            } else if (action == Actions.UNWRAP) {
                params.tokensOut = _addUnique(params.tokensOut, ZERO_ADDRESS);
                return (params, positions);
            } else {
                revert UnsupportedAction(action);
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

    /// @dev Multiple actions can be executed on the same tokenId, so we add a new position if same tokenId but different action
    function _addUniquePosition(Position[] memory array, Position memory pos) private pure returns (Position[] memory) {
        for (uint256 i = 0; i < array.length; i++) {
            if (array[i].hook == pos.hook && array[i].tokenId == pos.tokenId && array[i].action == pos.action) {
                return array;
            }
        }
        Position[] memory newArray = new Position[](array.length + 1);
        for (uint256 i = 0; i < array.length; i++) {
            newArray[i] = array[i];
        }

        newArray[array.length] = pos;
        return newArray;
    }
}
