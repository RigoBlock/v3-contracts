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
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PathKey} from "@uniswap/v4-periphery/src/libraries/PathKey.sol";
import "./interfaces/IEWhitelist.sol";
import {IAUniswapRouter} from "./interfaces/IAUniswapRouter.sol";
import {BytesLib} from './lib/uni-v3/BytesLib.sol';
import "../../IRigoblockV3Pool.sol";

// TODO: check if should implement as a library instead
abstract contract AUniswapDecoder {
    using BytesLib for bytes;
    
    error InvalidCommandType(uint256 commandType);

    address internal constant ZERO_ADDRESS = address(0);
    address internal constant SKIP_FLAG = address(1);

    // Initialize counters for transient storage, so we can forward sub plan to self
    uint256 internal transient _tokensInCount;
    uint256 internal transient _tokensOutCount;
    uint256 internal transient _recipientsCount;

    // arrays length is not updated on purpose, use the transient counters instead
    // TODO: however, verify that a reentrant call correctly indexes tokens
    struct RelevantInputs {
        address[] tokensIn;
        address[] tokensOut;
        address[] recipients;
        uint256 value;
        uint256 command;
        bytes filteredInput;
    }

    function positionManager() public view virtual returns (address);

    /// @dev Decodes the input for a command.
    /// @param commandType The command type to decode.
    /// @param inputs The encoded input data.
    /// @return relevantInputs containing decoded information.
    function _decodeInput(bytes1 commandType, bytes calldata inputs)
        internal
        returns (RelevantInputs memory relevantInputs)
    {
        uint256 command = uint8(commandType & Commands.COMMAND_TYPE_MASK);
        relevantInputs.command = command;

        // TODO: verify a subplan does not overwrite to relevantInpus, but uses a separate one, so we do not need to use _tokensInCount, ... as index for position storing
        // 0x00 <= command < 0x21
        if (command < Commands.EXECUTE_SUB_PLAN) {
            // 0x00 <= command < 0x10
            if (command < Commands.V4_SWAP) {
                // 0x00 <= command < 0x08
                if (command < Commands.V2_SWAP_EXACT_IN) {
                    if (command == Commands.V3_SWAP_EXACT_IN) {
                        (
                            address recipient,
                            /*uint256 amountIn*/,
                            /*uint256 amountOutMin*/,
                            /*bytes memory path*/,
                            bool payerIsUser
                        ) = abi.decode(inputs, (address, uint256, uint256, bytes, bool));
                        assert(payerIsUser);
                        bytes calldata path = inputs.toBytes(3);
                        relevantInputs.tokensIn[0] = path.toAddress();
                        relevantInputs.tokensOut[0] = path.toBytes(path.length - 20).toAddress();
                        relevantInputs.recipients[0] = recipient;
                        relevantInputs.filteredInput = inputs;
                    } else if (command == Commands.V3_SWAP_EXACT_OUT) {
                        (
                            address recipient,
                            /*uint256 amountOut*/,
                            /*uint256 amountInMax*/,
                            /*bytes memory path*/,
                            bool payerIsUser
                        ) = abi.decode(inputs, (address, uint256, uint256, bytes, bool));
                        assert(payerIsUser);
                        bytes calldata path = inputs.toBytes(3);
                        relevantInputs.tokensOut[0] = path.toAddress();
                        relevantInputs.tokensIn[0] = path.toBytes(path.length - 20).toAddress();
                        relevantInputs.recipients[0] = recipient;
                        relevantInputs.filteredInput = inputs;
                    } else if (command == Commands.PERMIT2_TRANSFER_FROM) {
                        // skip this command
                    } else if (command == Commands.PERMIT2_PERMIT_BATCH) {
                        // skip this command
                    } else if (command == Commands.SWEEP) {
                        (/*address token*/, address recipient, /*uint160 amountMin*/) = abi.decode(inputs, (address, address, uint256));
                        // sweep is used when the router is used for transfers to clear leftover
                        relevantInputs.recipients[0] = recipient;
                        relevantInputs.filteredInput = inputs;
                    } else if (command == Commands.TRANSFER) {
                        // TODO: check should validate token
                        (/*address token*/, address recipient, /*uint256 value*/) = abi.decode(inputs, (address, address, uint256));
                        relevantInputs.recipients[0] = recipient;
                        relevantInputs.filteredInput = inputs;
                    } else if (command == Commands.PAY_PORTION) {
                        // TODO: check what this does and if should early return
                        // TODO: check should validate token
                        (/*address token*/, address recipient, /*uint256 bips*/) = abi.decode(inputs, (address, address, uint256));
                        relevantInputs.recipients[0] = recipient;
                        relevantInputs.filteredInput = inputs;
                    } else {
                        // placeholder area for command 0x07
                        revert InvalidCommandType(command);
                    }
                } else {
                    // 0x08 <= command < 0x10
                    if (command == Commands.V2_SWAP_EXACT_IN) {
                        (
                            address recipient,
                            /*uint256 amountIn*/,
                            /*uint256 amountOutMin*/,
                            /*bytes memory path*/,
                            bool payerIsUser
                        ) = abi.decode(inputs, (address, uint256, uint256, bytes, bool));
                        assert(payerIsUser);
                        address[] calldata path = inputs.toAddressArray(3);
                        relevantInputs.tokensIn[0] = path[0];
                        relevantInputs.tokensOut[0] = path[path.length - 1];
                        relevantInputs.recipients[0] = recipient;
                        relevantInputs.filteredInput;
                    } else if (command == Commands.V2_SWAP_EXACT_OUT) {
                        (
                            address recipient,
                            /*uint256 amountOut*/,
                            /*uint256 amountInMax*/,
                            /*bytes memory path*/,
                            bool payerIsUser
                        ) = abi.decode(inputs, (address, uint256, uint256, bytes, bool));
                        assert(payerIsUser);
                        address[] calldata path = inputs.toAddressArray(3);
                        // TODO: check order in/out is correct
                        relevantInputs.tokensIn[0] = path[0];
                        relevantInputs.tokensOut[0] = path[path.length - 1];
                        relevantInputs.recipients[0] = recipient;
                        relevantInputs.filteredInput = inputs;
                    } else if (command == Commands.PERMIT2_PERMIT) {
                        // skip this command
                    } else if (command == Commands.WRAP_ETH) {
                        (address recipient, uint256 amount) = abi.decode(inputs, (address, uint256));
                        // TODO: we might want to _mapRecipient(recipient), but we do not accept calls from
                        // wallet other than user (like a trusted forwarder)
                        relevantInputs.recipients[0] = recipient;
                        relevantInputs.value = amount;
                        relevantInputs.filteredInput = inputs;
                    } else if (command == Commands.UNWRAP_WETH) {
                        (address recipient, /*uint256 amountMin*/) = abi.decode(inputs, (address, uint256));
                        relevantInputs.recipients[0] = recipient;
                        relevantInputs.filteredInput = inputs;
                    } else if (command == Commands.PERMIT2_TRANSFER_FROM_BATCH) {
                        // skip this command
                    } else if (command == Commands.BALANCE_CHECK_ERC20) {
                        // TODO: check if we need this one, we could simply not pass it
                        (
                            address owner,
                            address token,
                            /*uint256 minBalance*/
                        ) = abi.decode(inputs, (address, address, uint256));
                        // TODO: check if this assertion is needed, as we need to prevent a call to an arbitrary external
                        // contract, which could be a rogue contract
                        relevantInputs.tokensOut[0] = token;
                        relevantInputs.recipients[0] = owner;
                        relevantInputs.filteredInput = inputs;
                    } else {
                        // placeholder area for command 0x0f
                        revert InvalidCommandType(command);
                    }
                }

                // TODO: we should adjust the arrays' length for completeness
                // Adjust array lengths
                //    assembly {
                //        mstore(relevantInputs.tokensIn, tokensInCount)
                //        mstore(relevantInputs.tokensOut, tokensOutCount)
                //        mstore(relevantInputs.recipients, recipientsCount)
                //    }
            } else {
                // 0x10 <= command < 0x21
                if (command == Commands.V4_SWAP) {
                    (bytes memory actions, bytes[] memory params) = abi.decode(inputs, (bytes, bytes[]));

                    uint256 numActions = actions.length;
                    assert(numActions == params.length);

                    for (uint256 actionIndex = 0; actionIndex < numActions; actionIndex++) {
                        uint256 action = uint8(actions[actionIndex]);
                        bytes memory paramsAtIndex = params[actionIndex];

                        if (action < Actions.SETTLE) {
                            if (action == Actions.SWAP_EXACT_IN) {
                                IV4Router.ExactInputParams memory swapParams = abi.decode(paramsAtIndex, (IV4Router.ExactInputParams));
                                uint256 pathLength = swapParams.path.length;
                                relevantInputs.tokensIn[_tokensInCount++] = Currency.unwrap(swapParams.currencyIn);
                                relevantInputs.tokensOut[_tokensOutCount++] = Currency.unwrap(swapParams.path[pathLength - 1].intermediateCurrency);
                            } else if (action == Actions.SWAP_EXACT_IN_SINGLE) {
                                IV4Router.ExactInputSingleParams memory swapParams = abi.decode(paramsAtIndex, (IV4Router.ExactInputSingleParams));
                                relevantInputs.tokensIn[_tokensInCount++] = Currency.unwrap(swapParams.poolKey.currency0);
                                relevantInputs.tokensOut[_tokensOutCount++] = Currency.unwrap(swapParams.poolKey.currency1);
                            } else if (action == Actions.SWAP_EXACT_OUT) {
                                IV4Router.ExactOutputParams memory swapParams = abi.decode(paramsAtIndex, (IV4Router.ExactOutputParams));
                                uint256 pathLength = swapParams.path.length;
                                relevantInputs.tokensOut[_tokensOutCount++] = Currency.unwrap(swapParams.currencyOut);
                                relevantInputs.tokensIn[_tokensInCount++] = Currency.unwrap(swapParams.path[pathLength - 1].intermediateCurrency);
                            } else if (action == Actions.SWAP_EXACT_OUT_SINGLE) {
                                IV4Router.ExactOutputSingleParams memory swapParams = abi.decode(paramsAtIndex, (IV4Router.ExactOutputSingleParams));
                                relevantInputs.tokensIn[_tokensInCount++] = Currency.unwrap(swapParams.poolKey.currency1);
                                relevantInputs.tokensOut[_tokensOutCount++] = Currency.unwrap(swapParams.poolKey.currency0);
                            }
                        } else {
                            if (action == Actions.SETTLE_PAIR) {
                                // TODO: verify we cannot decode recipient, i.e. not an input for settle
                                (Currency currency0, Currency currency1) = abi.decode(paramsAtIndex, (Currency, Currency));
                                relevantInputs.tokensIn[_tokensInCount++] = Currency.unwrap(currency0);
                                relevantInputs.tokensOut[_tokensOutCount++] = Currency.unwrap(currency1);
                            } else if (action == Actions.TAKE_PAIR) {
                                (Currency currency0, Currency currency1, address recipient) = abi.decode(paramsAtIndex, (Currency, Currency, address));
                                relevantInputs.tokensIn[_tokensInCount++] = Currency.unwrap(currency0);
                                relevantInputs.tokensOut[_tokensOutCount++] = Currency.unwrap(currency1);
                                relevantInputs.recipients[_recipientsCount++] = recipient;
                            } else if (action == Actions.SETTLE) {
                                (Currency currency, /*uint256 amount*/, /*bool payerIsUser*/) = abi.decode(paramsAtIndex, (Currency, uint256, bool));
                                relevantInputs.tokensIn[_tokensInCount++] = Currency.unwrap(currency);
                            } else if (action == Actions.TAKE) {
                                (Currency currency, address recipient, /*uint256 amount*/) = abi.decode(paramsAtIndex, (Currency, address, uint256));
                                relevantInputs.tokensIn[_tokensInCount++] = Currency.unwrap(currency);
                                relevantInputs.recipients[_recipientsCount++] = recipient;
                            } else if (action == Actions.CLOSE_CURRENCY) {
                                // TODO: in these methods, we should check if simply return to skip checks if possible
                                Currency currency = abi.decode(paramsAtIndex, (Currency));
                                relevantInputs.tokensIn[_tokensInCount++] = Currency.unwrap(currency);
                            } else if (action == Actions.CLEAR_OR_TAKE) {
                                (Currency currency, /*uint256 amountMax*/) = abi.decode(paramsAtIndex, (Currency, uint256));
                                relevantInputs.tokensOut[_tokensOutCount++] = Currency.unwrap(currency);
                            } else if (action == Actions.SWEEP) {
                                (Currency currency, address to) = abi.decode(paramsAtIndex, (Currency, address));
                                relevantInputs.tokensOut[_tokensOutCount++] = Currency.unwrap(currency);
                                relevantInputs.recipients[_recipientsCount++] = to;
                            }
                        }
                    }

                    // all v4 swap actions are forwarded
                    relevantInputs.filteredInput = inputs;
                } else if (command == Commands.V3_POSITION_MANAGER_PERMIT) {
                    // skip this command
                } else if (command == Commands.V3_POSITION_MANAGER_CALL) {
                    // v3 calls are used to migrate liquidity only, no further actions or assertions are necessary. Migration supported methods are:
                    //  decreaseLiquidity, collect, burn
                    relevantInputs.filteredInput = inputs;
                } else if (command == Commands.V4_POSITION_MANAGER_CALL) {
                    // TODO: we should store filteredActions in memory, re-encode the good ones and return them for execution
                    // should only call modifyLiquidities() to mint
                    // do not permit or approve this contract over a v4 position or someone could use this command to decrease, burn, or transfer your position
                    (bytes memory actions, bytes[] memory params) = abi.decode(inputs, (bytes, bytes[]));

                    uint256 numActions = actions.length;
                    assert(numActions == params.length);

                    bytes1[] memory filteredActions = new bytes1[](numActions);
                    bytes[] memory filteredParams = new bytes[](numActions);
                    uint256 filteredActionIndex = 0;

                    for (uint256 actionIndex = 0; actionIndex < numActions; actionIndex++) {
                        uint256 action = uint8(actions[actionIndex]);
                        bytes memory paramsAtIndex = params[actionIndex];

                        // TODO: must assert liquidity position owner is always sender in v4
                        if (action == Actions.INCREASE_LIQUIDITY) {
                            (uint256 tokenId, /*uint256 liquidity*/, /*uint128 amount0Max*/, /*uint128 amount1Max*/, /*bytes memory hookData*/) =
                                abi.decode(paramsAtIndex, (uint256, uint256, uint128, uint128, bytes));
                            (PoolKey memory poolKey, /*PositionInfo*/) = IPositionManager(positionManager()).getPoolAndPositionInfo(tokenId);
                            // TODO: return owner as recipient if stored in PositionInfo
                            relevantInputs.tokensIn[_tokensInCount++] = Currency.unwrap(poolKey.currency0);
                            relevantInputs.tokensOut[_tokensOutCount++] = Currency.unwrap(poolKey.currency0);
                            relevantInputs.tokensIn[_tokensInCount++] = Currency.unwrap(poolKey.currency1);
                            relevantInputs.tokensOut[_tokensOutCount++] = Currency.unwrap(poolKey.currency1);
                            filteredActions[filteredActionIndex] = bytes1(uint8(action));
                            filteredParams[filteredActionIndex] = paramsAtIndex;
                            filteredActionIndex++;
                        // TODO: the following method is not implemented in the deployed uni package, but it is in uni universal dev
                        //} else if (action == Actions.INCREASE_LIQUIDITY_FROM_DELTAS) {
                        //    (uint256 tokenId, uint128 amount0Max, uint128 amount1Max, bytes calldata hookData) =
                        //    abi.decode(paramsAtIndex, (uint256, uint128, uint128, bytes));
                        //    (PoolKey memory poolKey, /*PositionInfo*/) = IPositionManager(positionManager()).getPoolAndPositionInfo(tokenId);
                        //    // TODO: return owner as recipient if stored in PositionInfo
                        //    relevantInputs.token0 = Currency.unwrap(poolKey.currency0);
                        //    relevantInputs.token1 = Currency.unwrap(poolKey.currency1);
                        //    filteredActions[filteredActionIndex] = bytes1(uint8(action));
                        //    filteredParams[filteredActionIndex] = paramsAtIndex;
                        //    filteredActionIndex++;
                        } else if (action == Actions.DECREASE_LIQUIDITY) {
                            // skip this command (not yet implemented in uniswap v4)
                        } else if (action == Actions.MINT_POSITION) {
                            // TODO: with mint and increase we might not need to require tokens out whitelisted, but must ensure using a rogue
                            //  token as input does not result in side effects, i.e. reentrancies, attacks, ...
                            (
                                PoolKey memory poolKey,
                                /*int24 tickLower*/,
                                /*int24 tickUpper*/,
                                /*uint256 liquidity*/,
                                /*uint128 amount0Max*/,
                                /*uint128 amount1Max*/,
                                address owner,
                                /*bytes memory hookData*/
                            ) = abi.decode(paramsAtIndex, (PoolKey, int24, int24, uint256, uint128, uint128, address, bytes));
                            relevantInputs.tokensIn[_tokensInCount++] = Currency.unwrap(poolKey.currency0);
                            relevantInputs.tokensOut[_tokensOutCount++] = Currency.unwrap(poolKey.currency0);
                            relevantInputs.tokensIn[_tokensInCount++] = Currency.unwrap(poolKey.currency1);
                            relevantInputs.tokensOut[_tokensOutCount++] = Currency.unwrap(poolKey.currency1);
                            relevantInputs.recipients[_recipientsCount++] = owner;
                            filteredActions[filteredActionIndex] = bytes1(uint8(action));
                            filteredParams[filteredActionIndex] = paramsAtIndex;
                            filteredActionIndex++;
                        } else if (action == Actions.BURN_POSITION) {
                            // skip this action (not yet implemented in uniswap v4)
                        }
                    }

                    // TODO: we should adjust arrays' length for completeness
                    // Adjust array lengths
                    //assembly {
                    //    mstore(relevantInputs.tokensIn, tokensInCount)
                    //    mstore(relevantInputs.tokensOut, tokensOutCount)
                    //    mstore(relevantInputs.recipients, recipientsCount)
                    //    mstore(filteredActions, filteredActionIndex)
                    //}

                    // Truncate filteredParams
                    bytes[] memory actualFilteredParams = new bytes[](filteredActionIndex);
                    for (uint256 i = 0; i < filteredActionIndex; i++) {
                        actualFilteredParams[i] = filteredParams[i];
                    }

                    relevantInputs.filteredInput = abi.encodePacked(abi.encodePacked(filteredActions), abi.encode(filteredParams));
                } else {
                    // placeholder area for commands 0x13-0x20
                    revert InvalidCommandType(command);
                }
            }
        } else {
            // 0x21 <= command
            if (command == Commands.EXECUTE_SUB_PLAN) {
                (bytes memory subCommands, bytes[] memory subInputs) = abi.decode(inputs, (bytes, bytes[]));

                try IAUniswapRouter(address(this)).execute(subCommands, subInputs) returns (bytes memory) {
                    // we do not return input, as they will be handled by the reentrant call
                } catch Error(string memory reason) {
                    revert(reason);
                }
            }
        }
    }
}