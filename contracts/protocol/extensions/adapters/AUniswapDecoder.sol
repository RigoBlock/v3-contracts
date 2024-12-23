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

import {TransientSlot} from "@openzeppelin/contracts/contracts/utils/TransientSlot.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PathKey} from "@uniswap/v4-periphery/src/libraries/PathKey.sol";
import {IAUniswapRouter} from "./interfaces/IAUniswapRouter.sol";
import {BytesLib} from './lib/uni-v3/BytesLib.sol';

abstract contract AUniswapDecoder {
    using BytesLib for bytes;
    
    error InvalidCommandType(uint256 commandType);

    /// @dev Only pools that do not have access to liquidity at removal are supported
    error LiquidityMintHookError(address hook);

    address internal constant ZERO_ADDRESS = address(0);

    // TODO: check what the skip flag is used for
    // if seems we should pass it to input state when we do not have to store?
    address internal constant SKIP_FLAG = address(1);

    // TODO: check if should merge Parameters in this struct
    struct InputState {
        uint256 value;
        uint256 command;
        bytes filteredInput;
    }

    struct Parameters {
        int256 memory tokenId;
        address memory recipient;
        address[] memory tokensIn;
        address[] memory tokensOut;
    }

    function positionManager() public view virtual returns (address);

    /// @dev Decodes the input for a command.
    /// @param commandType The command type to decode.
    /// @param inputs The encoded input data.
    /// @return inputState containing filtered information.
    function _decodeInput(bytes1 commandType, bytes calldata inputs)
        internal
        returns (InputState memory inputState, Parameters memory params)
    {
        uint256 command = uint8(commandType & Commands.COMMAND_TYPE_MASK);
        inputState.command = command;

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
                        params.tokensIn = _addUnique(tokensIn, path.toAddress());
                        params.tokensOut = _addUnique(tokensOut, path.toBytes(path.length - 20).toAddress());
                        params.recipient = _addUnique(recipient, recipient);
                        inputState.filteredInput = inputs;
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
                        params.tokensOut = _addUnique(tokensOut, path.toAddress());
                        params.tokensOut = _addUnique(tokensIn, path.toBytes(path.length - 20).toAddress());
                        params.recipient = _addUnique(recipient, recipient);
                        inputState.filteredInput = inputs;
                    } else if (command == Commands.PERMIT2_TRANSFER_FROM) {
                        // skip this command
                    } else if (command == Commands.PERMIT2_PERMIT_BATCH) {
                        // skip this command
                    } else if (command == Commands.SWEEP) {
                        (/*address token*/, address recipient, /*uint160 amountMin*/) = abi.decode(inputs, (address, address, uint256));
                        // sweep is used when the router is used for transfers to clear leftover
                        params.recipient = _addUnique(recipient, recipient);
                        inputState.filteredInput = inputs;
                    } else if (command == Commands.TRANSFER) {
                        // TODO: check should validate token
                        (/*address token*/, address recipient, /*uint256 value*/) = abi.decode(inputs, (address, address, uint256));
                        params.recipient = _addUnique(recipient, recipient);
                        inputState.filteredInput = inputs;
                    } else if (command == Commands.PAY_PORTION) {
                        // TODO: check what this does and if should early return
                        // TODO: check should validate token
                        (/*address token*/, address recipient, /*uint256 bips*/) = abi.decode(inputs, (address, address, uint256));
                        params.recipient = _addUnique(recipient, recipient);
                        inputState.filteredInput = inputs;
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
                        params.tokensOut = _addUnique(tokensIn, path[0]);
                        params.tokensOut = _addUnique(tokensOut, path[path.length - 1]);
                        params.recipient = _addUnique(recipient, recipient);
                        inputState.filteredInput = inputs;
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
                        params.tokensOut = _addUnique(tokensIn, path[0]);
                        params.tokensOut = _addUnique(tokensOut, path[path.length - 1]);
                        params.recipient = _addUnique(recipient, recipient);
                        inputState.filteredInput = inputs;
                    } else if (command == Commands.PERMIT2_PERMIT) {
                        // skip this command
                    } else if (command == Commands.WRAP_ETH) {
                        (address recipient, uint256 amount) = abi.decode(inputs, (address, uint256));
                        // TODO: we might want to _mapRecipient(recipient), but we do not accept calls from
                        // wallet other than user (like a trusted forwarder)
                        params.recipient = _addUnique(recipient, recipient);
                        inputState.value = amount;
                        inputState.filteredInput = inputs;
                        // TODO: must also add WETH to tracked assets, prob best in router adapter for all tokensOut
                        // TODO: also add to apps, as oracle may not exist, we may want to return base balances back when oracle
                        // does not exist
                    } else if (command == Commands.UNWRAP_WETH) {
                        (address recipient, /*uint256 amountMin*/) = abi.decode(inputs, (address, uint256));
                        params.recipient = _addUnique(recipient, recipient);
                        inputState.filteredInput = inputs;
                        // TODO: must also remove WETH from tracked assets, but we are not passing the correct flag to router adapter
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
                        params.tokensOut = _addUnique(tokensOut, token);
                        params.recipient = _addUnique(recipient, owner);
                        inputState.filteredInput = inputs;
                    } else {
                        // placeholder area for command 0x0f
                        revert InvalidCommandType(command);
                    }
                }
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
                                params.tokensOut = _addUnique(tokensIn, Currency.unwrap(swapParams.currencyIn));
                                params.tokensOut = _addUnique(tokensOut, Currency.unwrap(swapParams.path[pathLength - 1].intermediateCurrency));
                            } else if (action == Actions.SWAP_EXACT_IN_SINGLE) {
                                IV4Router.ExactInputSingleParams memory swapParams = abi.decode(paramsAtIndex, (IV4Router.ExactInputSingleParams));
                                params.tokensOut = _addUnique(tokensIn, Currency.unwrap(swapParams.poolKey.currency0));
                                params.tokensOut = _addUnique(tokensOut, Currency.unwrap(swapParams.poolKey.currency1));
                            } else if (action == Actions.SWAP_EXACT_OUT) {
                                IV4Router.ExactOutputParams memory swapParams = abi.decode(paramsAtIndex, (IV4Router.ExactOutputParams));
                                uint256 pathLength = swapParams.path.length;
                                params.tokensOut = _addUnique(tokensOut, Currency.unwrap(swapParams.currencyOut));
                                params.tokensOut = _addUnique(tokensIn, Currency.unwrap(swapParams.path[pathLength - 1].intermediateCurrency));
                            } else if (action == Actions.SWAP_EXACT_OUT_SINGLE) {
                                IV4Router.ExactOutputSingleParams memory swapParams = abi.decode(paramsAtIndex, (IV4Router.ExactOutputSingleParams));
                                // TODO: verify ordering on tokens
                                params.tokensOut = _addUnique(tokensIn, Currency.unwrap(swapParams.poolKey.currency1));
                                params.tokensOut = _addUnique(tokensOut, Currency.unwrap(swapParams.poolKey.currency0));
                            }
                        } else {
                            if (action == Actions.SETTLE_PAIR) {
                                // TODO: verify we cannot decode recipient, i.e. not an input for settle
                                (Currency currency0, Currency currency1) = abi.decode(paramsAtIndex, (Currency, Currency));
                                params.tokensOut = _addUnique(tokensIn, Currency.unwrap(currency0));
                                params.tokensOut = _addUnique(tokensOut, Currency.unwrap(currency1));
                            } else if (action == Actions.TAKE_PAIR) {
                                // TODO: verify if currency is eth we must forward currency.value?
                                (Currency currency0, Currency currency1, address recipient) = abi.decode(paramsAtIndex, (Currency, Currency, address));
                                params.tokensOut = _addUnique(tokensIn, Currency.unwrap(currency0));
                                params.tokensOut = _addUnique(tokensOut, Currency.unwrap(currency1));
                                params.recipient = _addUnique(recipient, recipient);
                            } else if (action == Actions.SETTLE) {
                                (Currency currency, /*uint256 amount*/, /*bool payerIsUser*/) = abi.decode(paramsAtIndex, (Currency, uint256, bool));
                                params.tokensOut = _addUnique(tokensIn, Currency.unwrap(currency));
                            } else if (action == Actions.TAKE) {
                                (Currency currency, address recipient, /*uint256 amount*/) = abi.decode(paramsAtIndex, (Currency, address, uint256));
                                params.tokensOut = _addUnique(tokensIn, Currency.unwrap(currency));
                                params.recipient = _addUnique(recipient, recipient);
                            } else if (action == Actions.CLOSE_CURRENCY) {
                                // TODO: in these methods, we should check if simply return to skip checks if possible
                                Currency currency = abi.decode(paramsAtIndex, (Currency));
                                params.tokensOut = _addUnique(tokensIn, Currency.unwrap(currency));
                            } else if (action == Actions.CLEAR_OR_TAKE) {
                                (Currency currency, /*uint256 amountMax*/) = abi.decode(paramsAtIndex, (Currency, uint256));
                                params.tokensOut = _addUnique(tokensOut, Currency.unwrap(currency));
                            } else if (action == Actions.SWEEP) {
                                (Currency currency, address to) = abi.decode(paramsAtIndex, (Currency, address));
                                params.tokensOut = _addUnique(tokensOut, Currency.unwrap(currency));
                                params.recipient = _addUnique(recipient, to);
                            }
                        }
                    }

                    // all v4 swap actions are forwarded
                    inputState.filteredInput = inputs;
                } else if (command == Commands.V3_POSITION_MANAGER_PERMIT) {
                    // skip this command
                } else if (command == Commands.V3_POSITION_MANAGER_CALL) {
                    // v3 calls are used to migrate liquidity only, no further actions or assertions are necessary. Migration supported methods are:
                    //  decreaseLiquidity, collect, burn
                    // @notice do not use with an older universal router, as would allow pool to add to non-owned positions
                    inputState.filteredInput = inputs;
                } else if (command == Commands.V4_POSITION_MANAGER_CALL) {
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

                        // TODO: in uni V4, only position owner can modify liquiity, assert
                        // TODO: verify how we extract value if currency is eth
                        if (action == Actions.INCREASE_LIQUIDITY) {
                            (uint256 tokenId, /*uint256 liquidity*/, /*uint128 amount0Max*/, /*uint128 amount1Max*/, /*bytes memory hookData*/) =
                                abi.decode(paramsAtIndex, (uint256, uint256, uint128, uint128, bytes));
                            (PoolKey memory poolKey, /*PositionInfo*/) = IPositionManager(positionManager()).getPoolAndPositionInfo(tokenId);
                            params.tokensOut = _addUnique(tokensIn, Currency.unwrap(poolKey.currency0));
                            params.tokensOut = _addUnique(tokensOut, Currency.unwrap(poolKey.currency0));
                            params.tokensOut = _addUnique(tokensIn, Currency.unwrap(poolKey.currency1));
                            params.tokensOut = _addUnique(tokensOut, Currency.unwrap(poolKey.currency1));
                            filteredActions[filteredActionIndex] = bytes1(uint8(action));
                            filteredParams[filteredActionIndex] = paramsAtIndex;
                            filteredActionIndex++;
                        // TODO: this method allows using deltas to swap instead of transferring erc20s. If we support this, we must
                        // also make sure ERC6909 balances are correctly returned by the EApps contract
                        // TODO: the following method is not implemented in the deployed uni package, but it is in uni universal dev
                        //} else if (action == Actions.INCREASE_LIQUIDITY_FROM_DELTAS) {
                        //    (uint256 tokenId, uint128 amount0Max, uint128 amount1Max, bytes calldata hookData) =
                        //    abi.decode(paramsAtIndex, (uint256, uint128, uint128, bytes));
                        //    (PoolKey memory poolKey, /*PositionInfo*/) = IPositionManager(positionManager()).getPoolAndPositionInfo(tokenId);
                        //    // TODO: return owner as recipient if stored in PositionInfo
                        //    params.tokensOut = _addUnique(tokensIn, Currency.unwrap(poolKey.currency0));
                        //    params.tokensOut = _addUnique(tokensIn, Currency.unwrap(poolKey.currency1));
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

                            // we do not allow adding liquidity to pools that have access to liquidity when removing it
                            require(
                                !poolKey.hooks.afterRemoveLiquidityReturnDelta,
                                LiquidityMintHookError(address(poolKey.hooks))
                            );
                            params.tokensOut = _addUnique(tokensIn, Currency.unwrap(poolKey.currency0));
                            params.tokensOut = _addUnique(tokensOut, Currency.unwrap(poolKey.currency0));
                            params.tokensOut = _addUnique(tokensIn, Currency.unwrap(poolKey.currency1));
                            params.tokensOut = _addUnique(tokensOut, Currency.unwrap(poolKey.currency1));
                            params.recipient = _addUnique(recipient, owner);
                            filteredActions[filteredActionIndex] = bytes1(uint8(action));
                            filteredParams[filteredActionIndex] = paramsAtIndex;
                            filteredActionIndex++;
                            params.tokenId = _addUniqueTokenId(params.tokenId, int256(IPositionManager(positionManager()).nextTokenId()));
                        } else if (action == Actions.BURN_POSITION) {
                            // TODO: check if has been implemented in universal router
                            // skip this action (not yet implemented in uniswap v4). When burning, remember to remove tokenId from proxy storage
                            //params.tokenId = _addUniqueTokenId(params.tokenId, -int256(IPositionManager(positionManager()).nextTokenId()));
                        }
                    }

                    // Truncate filteredParams
                    bytes[] memory actualFilteredParams = new bytes[](filteredActionIndex);
                    for (uint256 i = 0; i < filteredActionIndex; i++) {
                        actualFilteredParams[i] = filteredParams[i];
                    }

                    inputState.filteredInput = abi.encodePacked(abi.encodePacked(filteredActions), abi.encode(filteredParams));
                } else {
                    // placeholder area for commands 0x13-0x20
                    revert InvalidCommandType(command);
                }
            }
        } else {
            // 0x21 <= command
            if (command == Commands.EXECUTE_SUB_PLAN) {
                (bytes memory subCommands, bytes[] memory subInputs) = abi.decode(inputs, (bytes, bytes[]));
                execute(subCommands, subInputs) returns (bytes memory);
            }
        }
        return (inputState, addresses);
    }

    function execute(bytes calldata commands, bytes[] calldata inputs)
        public
        payable
        virtual
        returns (bytes memory returnData);

    function _addUnique(address[] memory array, address target) private pure returns (address[] memory) {
        for (uint i = 0; i < array.length; i++) {
            if (array[i] == target) {
                return array; // Already exists, return unchanged array
            }
        }
        address[] memory newArray = new address[](array.length + 1);
        for (uint i = 0; i < array.length; i++) {
            newArray[i] = array[i];
        }
        newArray[array.length] = target;
        return newArray;
    }

    function _addUniqueTokenId(uint256[] memory array, uint256 id, bool isMint) private pure returns (int256[] memory) {
        for (uint i = 0; i < array.length; i++) {
            if (array[i] == id) {
                return array; // Already exists, return unchanged array
            }
        }
        address[] memory newArray = new address[](array.length + 1);
        for (uint i = 0; i < array.length; i++) {
            newArray[i] = array[i];
        }

        // negative value is sentinel for closed position
        newArray[array.length] = isMint ? int256(target) : -int256(target);
        return newArray;
    }
}