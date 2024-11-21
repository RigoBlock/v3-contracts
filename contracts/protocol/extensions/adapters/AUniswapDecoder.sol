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

import "@uniswap/universal-router/contracts/UniversalRouter.sol";
import "./interfaces/IEWhitelist.sol";
import {Actions} from "./lib/uni-v4/Actions.sol";
import {Commands} from './lib/uni-v4/Commands.sol';
import "../../IRigoblockV3Pool.sol";
import "../../../utils/exchanges/uniswap/v3-periphery/contracts/libraries/BytesLib.sol";

// TODO: check if should implement as a library instead
abstract contract AUniswapDecoder {
    using BytesLib for bytes;
    using CalldataDecoder for bytes;
    
    error InvalidCommandType(uint256 commandType);

    struct Output {
        address token0;
        address token1 ;
        address tokenOut;
    }

    Output private _output = Output({
        token0: address(0),
        token1: address(0),
        tokenOut: address(0)
    });

    function _decodeInput(bytes1 commandType, bytes calldata inputs)
        private
        returns (address token0, address token1, address tokenOut, address recipient)
    {
        uint256 command = uint8(commandType & Commands.COMMAND_TYPE_MASK);

        // 0x00 <= command < 0x21
        if (command < Commands.EXECUTE_SUB_PLAN) {
            // 0x00 <= command < 0x10
            if (command < Commands.V4_SWAP) {
                // 0x00 <= command < 0x08
                if (command < Commands.V2_SWAP_EXACT_IN) {
                    if (command == Commands.V3_SWAP_EXACT_IN) {
                        // equivalent: abi.decode(inputs, (address, uint256, uint256, bytes, bool))
                        address recipient;
                        //uint256 amountIn;
                        //uint256 amountOutMin;
                        bool payerIsUser;
                        assembly {
                            recipient := calldataload(inputs.offset)
                            //amountIn := calldataload(add(inputs.offset, 0x20))
                            //amountOutMin := calldataload(add(inputs.offset, 0x40))
                            // 0x60 offset is the path, decoded below
                            payerIsUser := calldataload(add(inputs.offset, 0x80))
                        }
                        bytes calldata path = inputs.toBytes(3);
                        assert(payerIsUser);
                        assert(recipient == address(this));
                        _output.token0 = path.toAddress(0);
                        _output.tokenOut = path.toAddress(params.path.length - 20);
                    } else if (command == Commands.V3_SWAP_EXACT_OUT) {
                        // equivalent: abi.decode(inputs, (address, uint256, uint256, bytes, bool))
                        address recipient;
                        //uint256 amountOut;
                        //uint256 amountInMax;
                        bool payerIsUser;
                        assembly {
                            recipient := calldataload(inputs.offset)
                            //amountOut := calldataload(add(inputs.offset, 0x20))
                            //amountInMax := calldataload(add(inputs.offset, 0x40))
                            // 0x60 offset is the path, decoded below
                            payerIsUser := calldataload(add(inputs.offset, 0x80))
                        }
                        bytes calldata path = inputs.toBytes(3);
                        assert(payerIsUser);
                        assert(recipient == address(this));
                        _output.tokenOut = params.path.toAddress(0);
                        _output.token0 = params.path.toAddress(params.path.length - 20);
                    } else if (command == Commands.PERMIT2_TRANSFER_FROM) {
                        return;
                    } else if (command == Commands.PERMIT2_PERMIT_BATCH) {
                        return;
                    } else if (command == Commands.SWEEP) {
                        // equivalent:  abi.decode(inputs, (address, address, uint256))
                        address token;
                        address recipient;
                        //uint160 amountMin;
                        assembly {
                            token := calldataload(inputs.offset)
                            recipient := calldataload(add(inputs.offset, 0x20))
                            //amountMin := calldataload(add(inputs.offset, 0x40))
                        }
                        assert(recipient == address(this));
                        // sweep is used when the router is used for transfers
                        // TODO: check if should validate token
                        Payments.sweep(token, address(this), amountMin);
                    } else if (command == Commands.TRANSFER) {
                        // equivalent:  abi.decode(inputs, (address, address, uint256))
                        address token;
                        address recipient;
                        uint256 value;
                        assembly {
                            token := calldataload(inputs.offset)
                            recipient := calldataload(add(inputs.offset, 0x20))
                            value := calldataload(add(inputs.offset, 0x40))
                        }
                        assert(recipient == address(this));
                        // TODO: check should validate token
                    } else if (command == Commands.PAY_PORTION) {
                        // TODO: check what this does and if should early return
                        // equivalent:  abi.decode(inputs, (address, address, uint256))
                        address token;
                        address recipient;
                        uint256 bips;
                        assembly {
                            token := calldataload(inputs.offset)
                            recipient := calldataload(add(inputs.offset, 0x20))
                            bips := calldataload(add(inputs.offset, 0x40))
                        }
                        assert(recipient == address(this));
                        // TODO: check should validate token
                    } else {
                        // placeholder area for command 0x07
                        revert InvalidCommandType(command);
                    }
                } else {
                    // 0x08 <= command < 0x10
                    if (command == Commands.V2_SWAP_EXACT_IN) {
                        // equivalent: abi.decode(inputs, (address, uint256, uint256, bytes, bool))
                        address recipient;
                        uint256 amountIn;
                        uint256 amountOutMin;
                        bool payerIsUser;
                        assembly {
                            recipient := calldataload(inputs.offset)
                            amountIn := calldataload(add(inputs.offset, 0x20))
                            amountOutMin := calldataload(add(inputs.offset, 0x40))
                            // 0x60 offset is the path, decoded below
                            payerIsUser := calldataload(add(inputs.offset, 0x80))
                        }
                        assert(recipient == address(this));
                        assert(payerIsUser);
                        address[] calldata path = inputs.toAddressArray(3);
                        _output.token0 = path[0];
                        _output.tokenOut = path[1];
                    } else if (command == Commands.V2_SWAP_EXACT_OUT) {
                        // equivalent: abi.decode(inputs, (address, uint256, uint256, bytes, bool))
                        address recipient;
                        uint256 amountOut;
                        uint256 amountInMax;
                        bool payerIsUser;
                        assembly {
                            recipient := calldataload(inputs.offset)
                            amountOut := calldataload(add(inputs.offset, 0x20))
                            amountInMax := calldataload(add(inputs.offset, 0x40))
                            // 0x60 offset is the path, decoded below
                            payerIsUser := calldataload(add(inputs.offset, 0x80))
                        }
                        address[] calldata path = inputs.toAddressArray(3);
                        assert(recipient == address(this));
                        assert(payerIsUser);
                        // TODO: check order in/out is correct
                        _output.token0 = path[0];
                        _output.tokenOut = path[1];
                    } else if (command == Commands.PERMIT2_PERMIT) {
                        return;
                    } else if (command == Commands.WRAP_ETH) {
                        // equivalent: abi.decode(inputs, (address, uint256))
                        address recipient;
                        uint256 amount;
                        assembly {
                            recipient := calldataload(inputs.offset)
                            amount := calldataload(add(inputs.offset, 0x20))
                        }
                        assert(recipient == address(this));
                        // TODO: check how it works with value, we may have to add return `value`
                        // or we could directly wrap here, as in uniswap adapter
                        Payments.wrapETH(map(recipient), amount);
                    } else if (command == Commands.UNWRAP_WETH) {
                        // equivalent: abi.decode(inputs, (address, uint256))
                        address recipient;
                        //uint256 amountMin;
                        assembly {
                            recipient := calldataload(inputs.offset)
                            //amountMin := calldataload(add(inputs.offset, 0x20))
                        }
                        assert(recipient == address(this));
                        // TODO: in auniswap we define but not use recipient, check if direct weth call
                    } else if (command == Commands.PERMIT2_TRANSFER_FROM_BATCH) {
                        return;
                    } else if (command == Commands.BALANCE_CHECK_ERC20) {
                        // equivalent: abi.decode(inputs, (address, address, uint256))
                        address owner;
                        address token;
                        uint256 minBalance;
                        assembly {
                            owner := calldataload(inputs.offset)
                            token := calldataload(add(inputs.offset, 0x20))
                            minBalance := calldataload(add(inputs.offset, 0x40))
                        }
                        assert(owner == address(this));
                        // TODO: we should check if it is safe to call an arbitrary contract. We may have to
                        //  forward as .staticcall to prevent race conditions
                        //success = (ERC20(token).balanceOf(owner) >= minBalance);
                        //if (!success) output = abi.encodePacked(BalanceTooLow.selector);
                    } else {
                        // placeholder area for command 0x0f
                        revert InvalidCommandType(command);
                    }
                }
            } else {
                // 0x10 <= command < 0x21
                // TODO: restrict conditions on NO_OP hook flag
                if (command == Commands.V4_SWAP) {
                    (bytes calldata actions, bytes[] calldata params) = inputs.decodeActionsRouterParams();

                    if (action < Actions.SETTLE) {
                        if (action == Actions.SWAP_EXACT_IN) {
                            IV4Router.ExactInputParams calldata swapParams = params.decodeSwapExactInParams();
                            uint256 pathLength = params.path.length;
                            Currency currencyIn = params.currencyIn;
                            PathKey calldata pathKey;
                            for (uint256 i = 0; i < pathLength; i++) {
                                pathKey = params.path[i];
                                (PoolKey memory poolKey, /*bool*/) = pathKey.getPoolAndSwapDirection(currencyIn);
                                // just an example of requirements on uniswap hook
                                // TODO: initially it would be appropriate to require hookData.length == 0
                                require(!pathKey.hooks.getHookPermissions().afterSwap, HookPermissionError());
                            }
                            _output.token0 = params.currencyIn;
                            // TODO: we should return output at the end
                            return _output;
                        } else if (action == Actions.SWAP_EXACT_IN_SINGLE) {
                            IV4Router.ExactInputSingleParams calldata swapParams = params.decodeSwapExactInSingleParams();
                            _swapExactInputSingle(swapParams);
                            return;
                        } else if (action == Actions.SWAP_EXACT_OUT) {
                            IV4Router.ExactOutputParams calldata swapParams = params.decodeSwapExactOutParams();
                            _swapExactOutput(swapParams);
                            return;
                        } else if (action == Actions.SWAP_EXACT_OUT_SINGLE) {
                            IV4Router.ExactOutputSingleParams calldata swapParams = params.decodeSwapExactOutSingleParams();
                            _swapExactOutputSingle(swapParams);
                            return;
                        }
                    } else {
                        if (action == Actions.SETTLE_PAIR) {
                            (Currency currency0, Currency currency1) = params.decodeCurrencyPair();
                            _settlePair(currency0, currency1);
                            return;
                        } else if (action == Actions.TAKE_PAIR) {
                            (Currency currency0, Currency currency1, address recipient) = params.decodeCurrencyPairAndAddress();
                            _takePair(currency0, currency1, _mapRecipient(recipient));
                            return;
                        } else if (action == Actions.SETTLE) {
                            (Currency currency, uint256 amount, bool payerIsUser) = params.decodeCurrencyUint256AndBool();
                            _settle(currency, _mapPayer(payerIsUser), _mapSettleAmount(amount, currency));
                            return;
                        } else if (action == Actions.TAKE) {
                            (Currency currency, address recipient, uint256 amount) = params.decodeCurrencyAddressAndUint256();
                            _take(currency, _mapRecipient(recipient), _mapTakeAmount(amount, currency));
                            return;
                        } else if (action == Actions.CLOSE_CURRENCY) {
                            Currency currency = params.decodeCurrency();
                            _close(currency);
                            return;
                        } else if (action == Actions.CLEAR_OR_TAKE) {
                            (Currency currency, uint256 amountMax) = params.decodeCurrencyAndUint256();
                            _clearOrTake(currency, amountMax);
                            return;
                        } else if (action == Actions.SWEEP) {
                            (Currency currency, address to) = params.decodeCurrencyAndAddress();
                            _sweep(currency, _mapRecipient(to));
                            return;
                        }
                    }
                } else if (command == Commands.V3_POSITION_MANAGER_PERMIT) {
                    return _output;
                } else if (command == Commands.V3_POSITION_MANAGER_CALL) {
                    bytes4 selector;
                    assembly {
                        selector := calldataload(inputs.offset)
                    }
                    if (!isValidAction(selector)) {
                        revert InvalidAction(selector);
                    }

                    uint256 tokenId;
                    assembly {
                        // tokenId is always the first parameter in the valid actions
                        tokenId := calldataload(add(inputs.offset, 0x04))
                    }
                    // If any other address that is not the owner wants to call this function, it also needs to be approved (in addition to this contract)
                    // This can be done in 2 ways:
                    //    1. This contract is permitted for the specific token and the caller is approved for ALL of the owner's tokens
                    //    2. This contract is permitted for ALL of the owner's tokens and the caller is permitted for the specific token
                    if (!isAuthorizedForToken(msgSender(), tokenId)) {
                        revert NotAuthorizedForToken(tokenId);
                    }

                    (success, output) = address(V3_POSITION_MANAGER).call(inputs);
                } else if (command == Commands.V4_POSITION_CALL) {
                    // should only call modifyLiquidities() to mint
                    // do not permit or approve this contract over a v4 position or someone could use this command to decrease, burn, or transfer your position
                    (bytes calldata actions, bytes[] calldata params) = inputs.decodeActionsRouterParams();

                    if (action == Actions.INCREASE_LIQUIDITY) {
                        (uint256 tokenId, uint256 liquidity, uint128 amount0Max, uint128 amount1Max, bytes calldata hookData) =
                            params.decodeModifyLiquidityParams();
                        (PoolKey memory poolKey, ) = getPoolAndPositionInfo(tokenId);
                        _output.token0 = Currency.unwrap(poolKey.currency0);
                        _output.token1 = Currency.unwrap(poolKey.currency1);
                    } else if (action == Actions.DECREASE_LIQUIDITY) {
                        (uint256 tokenId, uint256 liquidity, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData) =
                            params.decodeModifyLiquidityParams();
                        return _output;
                    } else if (action == Actions.MINT_POSITION) {
                        (
                            PoolKey calldata poolKey,
                            /*int24 tickLower*/,
                            /*int24 tickUpper*/,
                            /*uint256 liquidity*/,
                            /*uint128 amount0Max*/,
                            /*uint128 amount1Max*/,
                            address owner,
                            bytes calldata hookData
                        ) = params.decodeMintParams();
                        assert(owner == address(this));
                        _output.token0 = Currency.unwrap(poolKey.currency0);
                        _output.token1 = Currency.unwrap(poolKey.currency1);
                    } else if (action == Actions.BURN_POSITION) {
                        return _output;
                    }
                } else {
                    // placeholder area for commands 0x13-0x20
                    revert InvalidCommandType(command);
                }
            }
        } else {
            // 0x21 <= command
            if (command == Commands.EXECUTE_SUB_PLAN) {
                (bytes calldata _commands, bytes[] calldata _inputs) = inputs.decodeCommandsAndInputs();
                // TODO: check if this call could fail silently and its consequences
                (address(this)).call(abi.encodeCall(IAUniswapRouter.execute, (_commands, _inputs)));
            }
        }

        return _output;
    }
}