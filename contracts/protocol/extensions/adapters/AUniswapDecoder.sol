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

// TODO: check if can add remapping an declare as @uniswap/universal-router without messing with uniswap v3 imports
//import "@uniswap/universal-router/contracts/UniversalRouter.sol";
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
    uint256 internal constant NIL_VALUE = 0;

    struct RelevantInputs {
        address token0;
        address token1 ;
        address tokenOut;
        address recipient;
        uint256 value;
    }

    function positionManager() public view virtual returns (address);

    /// @dev Decodes the input for a command.
    /// @param commandType The command type to decode.
    /// @param inputs The encoded input data.
    /// @return relevantInputs containing decoded information.
    function _decodeInput(bytes1 commandType, bytes calldata inputs)
        internal
        view
        returns (RelevantInputs memory relevantInputs)
    {
        uint256 command = uint8(commandType & Commands.COMMAND_TYPE_MASK);

        // initialize struct with nil values
        relevantInputs = RelevantInputs({
            token0: ZERO_ADDRESS,
            token1: ZERO_ADDRESS,
            tokenOut: ZERO_ADDRESS,
            recipient: ZERO_ADDRESS,
            value: NIL_VALUE
        });

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
                        relevantInputs.token0 = path.toAddress();
                        relevantInputs.tokenOut = path.toBytes(path.length - 20).toAddress();
                        relevantInputs.recipient = recipient;
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
                        relevantInputs.tokenOut = path.toAddress();
                        relevantInputs.token0 = path.toBytes(path.length - 20).toAddress();
                        relevantInputs.recipient = recipient;
                    } else if (command == Commands.PERMIT2_TRANSFER_FROM) {
                        relevantInputs.recipient = SKIP_FLAG;
                    } else if (command == Commands.PERMIT2_PERMIT_BATCH) {
                        relevantInputs.recipient = SKIP_FLAG;
                    } else if (command == Commands.SWEEP) {
                        (/*address token*/, address recipient, /*uint160 amountMin*/) = abi.decode(inputs, (address, address, uint256));
                        // sweep is used when the router is used for transfers
                        relevantInputs.recipient = recipient;
                    } else if (command == Commands.TRANSFER) {
                        // TODO: check should validate token
                        (/*address token*/, address recipient, /*uint256 value*/) = abi.decode(inputs, (address, address, uint256));
                        relevantInputs.recipient = recipient;
                    } else if (command == Commands.PAY_PORTION) {
                        // TODO: check what this does and if should early return
                        // TODO: check should validate token
                        (/*address token*/, address recipient, /*uint256 bips*/) = abi.decode(inputs, (address, address, uint256));
                        relevantInputs.recipient = recipient;
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
                        relevantInputs.token0 = path[0];
                        relevantInputs.tokenOut = path[path.length - 1];
                        relevantInputs.recipient = recipient;
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
                        relevantInputs.token0 = path[0];
                        relevantInputs.tokenOut = path[path.length - 1];
                        relevantInputs.recipient = recipient;
                    } else if (command == Commands.PERMIT2_PERMIT) {
                        relevantInputs.recipient = SKIP_FLAG;
                    } else if (command == Commands.WRAP_ETH) {
                        (address recipient, uint256 amount) = abi.decode(inputs, (address, uint256));
                        // TODO: we might want to _mapRecipient(recipient), but we do not accept calls from
                        // wallet other than user (like a trusted forwarder)
                        relevantInputs.recipient = recipient;
                        relevantInputs.value = amount;
                    } else if (command == Commands.UNWRAP_WETH) {
                        (address recipient, /*uint256 amountMin*/) = abi.decode(inputs, (address, uint256));
                        relevantInputs.recipient = recipient;
                    } else if (command == Commands.PERMIT2_TRANSFER_FROM_BATCH) {
                        relevantInputs.recipient = SKIP_FLAG;
                    } else if (command == Commands.BALANCE_CHECK_ERC20) {
                        (
                            address owner,
                            address token,
                            /*uint256 minBalance*/
                        ) = abi.decode(inputs, (address, address, uint256));
                        // TODO: check if this assertion is needed, as we need to prevent a call to an arbitrary external
                        // contract, which could be a rogue contract
                        relevantInputs.tokenOut = token;
                        relevantInputs.recipient = owner;
                    } else {
                        // placeholder area for command 0x0f
                        revert InvalidCommandType(command);
                    }
                }
            } else {
                // 0x10 <= command < 0x21
                // TODO: restrict conditions on NO_OP hook flag
                // TODO: we can allow any hook, as frontrunning is always possible, but should retrieve recipient
                //  and tokens
                // should loop through actions as in https://github.com/Uniswap/v4-periphery/blob/d767807d357b18bb8d35876b52c0556f1c2b302f/src/base/BaseActionsRouter.sol#L38
                if (command == Commands.V4_SWAP) {
                    (bytes memory actions, bytes[] memory params) = abi.decode(inputs, (bytes, bytes[]));

                    uint256 numActions = actions.length;
                    assert(numActions == params.length);

                    // TODO: we need to store tokens and recipient in memory, and can override as 1 swap is intended,
                    // i.e. if multiple swaps are sent most will fail, as multiple swaps should be sent as an array
                    // of v4 swaps

                    for (uint256 actionIndex = 0; actionIndex < numActions; actionIndex++) {
                        uint256 action = uint8(actions[actionIndex]);
                        bytes memory paramsAtIndex = params[actionIndex];

                        if (action < Actions.SETTLE) {
                            if (action == Actions.SWAP_EXACT_IN) {
                                IV4Router.ExactInputParams memory swapParams = abi.decode(paramsAtIndex, (IV4Router.ExactInputParams));
                                uint256 pathLength = swapParams.path.length;
                                relevantInputs.token0 = Currency.unwrap(swapParams.currencyIn);
                                relevantInputs.tokenOut = Currency.unwrap(swapParams.path[pathLength - 1].intermediateCurrency);
                            } else if (action == Actions.SWAP_EXACT_IN_SINGLE) {
                                IV4Router.ExactInputSingleParams memory swapParams = abi.decode(paramsAtIndex, (IV4Router.ExactInputSingleParams));
                                relevantInputs.token0 = Currency.unwrap(swapParams.poolKey.currency0);
                                relevantInputs.tokenOut = Currency.unwrap(swapParams.poolKey.currency1);
                            } else if (action == Actions.SWAP_EXACT_OUT) {
                                IV4Router.ExactOutputParams memory swapParams = abi.decode(paramsAtIndex, (IV4Router.ExactOutputParams));
                                uint256 pathLength = swapParams.path.length;
                                relevantInputs.tokenOut = Currency.unwrap(swapParams.currencyOut);
                                relevantInputs.token0 = Currency.unwrap(swapParams.path[pathLength - 1].intermediateCurrency);
                            } else if (action == Actions.SWAP_EXACT_OUT_SINGLE) {
                                IV4Router.ExactOutputSingleParams memory swapParams = abi.decode(paramsAtIndex, (IV4Router.ExactOutputSingleParams));
                                relevantInputs.token0 = Currency.unwrap(swapParams.poolKey.currency1);
                                relevantInputs.tokenOut = Currency.unwrap(swapParams.poolKey.currency0);
                            }
                        } else {
                            // TODO: check payment methods and that we are correctly returning token0 or token1 or tokenOut
                            if (action == Actions.SETTLE_PAIR) {
                                // TODO: verify we cannot decode recipient, i.e. not an input for settle
                                (Currency currency0, Currency currency1) = abi.decode(paramsAtIndex, (Currency, Currency));
                                relevantInputs.token0 = Currency.unwrap(currency0);
                                relevantInputs.tokenOut = Currency.unwrap(currency1);
                            } else if (action == Actions.TAKE_PAIR) {
                                (Currency currency0, Currency currency1, address recipient) = abi.decode(paramsAtIndex, (Currency, Currency, address));
                                relevantInputs.token0 = Currency.unwrap(currency0);
                                relevantInputs.tokenOut = Currency.unwrap(currency1);
                                relevantInputs.recipient = recipient;
                            } else if (action == Actions.SETTLE) {
                                (Currency currency, /*uint256 amount*/, /*bool payerIsUser*/) = abi.decode(paramsAtIndex, (Currency, uint256, bool));
                                //_settle(currency, _mapPayer(payerIsUser), _mapSettleAmount(amount, currency));
                                relevantInputs.token0 = Currency.unwrap(currency);
                            } else if (action == Actions.TAKE) {
                                (Currency currency, address recipient, /*uint256 amount*/) = abi.decode(paramsAtIndex, (Currency, address, uint256));
                                //_take(currency, _mapRecipient(recipient), _mapTakeAmount(amount, currency));
                                relevantInputs.token0 = Currency.unwrap(currency);
                                relevantInputs.recipient = recipient;
                            } else if (action == Actions.CLOSE_CURRENCY) {
                                // TODO: in these methods, we should check if simply return to skip checks if possible
                                Currency currency = abi.decode(paramsAtIndex, (Currency));
                                //_close(currency);
                                relevantInputs.token0 = Currency.unwrap(currency);
                                //return relevantInputs;
                            } else if (action == Actions.CLEAR_OR_TAKE) {
                                (Currency currency, /*uint256 amountMax*/) = abi.decode(paramsAtIndex, (Currency, uint256));
                                relevantInputs.tokenOut = Currency.unwrap(currency);
                                //_clearOrTake(currency, amountMax);
                                //return relevantInputs;
                            } else if (action == Actions.SWEEP) {
                                (Currency currency, address to) = abi.decode(paramsAtIndex, (Currency, address));
                                //_sweep(currency, _mapRecipient(to));
                                relevantInputs.tokenOut = Currency.unwrap(currency);
                                relevantInputs.recipient = to;
                            }
                        }
                    }
                } else if (command == Commands.V3_POSITION_MANAGER_PERMIT) {
                    relevantInputs.recipient = SKIP_FLAG;
                } else if (command == Commands.V3_POSITION_MANAGER_CALL) {
                    // v3 calls are used to migrate liquidity only, no further actions or assertions are necessary. Migration supported methods are:
                    //  decreaseLiquidity, collect, burn
                } else if (command == Commands.V4_POSITION_CALL) {
                    // should only call modifyLiquidities() to mint
                    // do not permit or approve this contract over a v4 position or someone could use this command to decrease, burn, or transfer your position
                    (bytes memory actions, bytes[] memory params) = abi.decode(inputs, (bytes, bytes[]));

                    uint256 numActions = actions.length;
                    assert(numActions == params.length);

                    for (uint256 actionIndex = 0; actionIndex < numActions; actionIndex++) {
                        uint256 action = uint8(actions[actionIndex]);
                        bytes memory paramsAtIndex = params[actionIndex];

                        // TODO: verify liquidity position owner is always sender in v4
                        if (action == Actions.INCREASE_LIQUIDITY) {
                            (uint256 tokenId, /*uint256 liquidity*/, /*uint128 amount0Max*/, /*uint128 amount1Max*/, /*bytes memory hookData*/) =
                                abi.decode(paramsAtIndex, (uint256, uint256, uint128, uint128, bytes));
                            (PoolKey memory poolKey, /*PositionInfo*/) = IPositionManager(positionManager()).getPoolAndPositionInfo(tokenId);
                            // TODO: return owner as recipient if stored in PositionInfo
                            // TODO: we should verify that tokens are whitelisted as well
                            relevantInputs.token0 = Currency.unwrap(poolKey.currency0);
                            relevantInputs.token1 = Currency.unwrap(poolKey.currency1);
                        // TODO: the following method is not implemented in the deployed uni package, but it is in uni universal dev
                        //} else if (action == Actions.INCREASE_LIQUIDITY_FROM_DELTAS) {
                        //    (uint256 tokenId, uint128 amount0Max, uint128 amount1Max, bytes calldata hookData) =
                        //        abi.decode(paramsAtIndex, (uint256, uint128, uint128, bytes));
                        //    (PoolKey memory poolKey, /*PositionInfo*/) = IPositionManager(positionManager()).getPoolAndPositionInfo(tokenId);
                        //    // TODO: return owner as recipient if stored in PositionInfo
                        //    relevantInputs.token0 = Currency.unwrap(poolKey.currency0);
                        //    relevantInputs.token1 = Currency.unwrap(poolKey.currency1);
                        } else if (action == Actions.DECREASE_LIQUIDITY) {
                            relevantInputs.recipient = SKIP_FLAG;
                        } else if (action == Actions.MINT_POSITION) {
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
                            relevantInputs.token0 = Currency.unwrap(poolKey.currency0);
                            relevantInputs.token1 = Currency.unwrap(poolKey.currency1);
                            relevantInputs.recipient = owner;
                        } else if (action == Actions.BURN_POSITION) {
                            return relevantInputs;
                        }
                    }
                } else {
                    // placeholder area for commands 0x13-0x20
                    revert InvalidCommandType(command);
                }
            }
        } else {
            // 0x21 <= command
            // we skip Commands.EXECUTE_SUB_PLAN here, as it is already handled in AUniswapDecoder
        }
    }
}