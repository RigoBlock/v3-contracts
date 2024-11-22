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

    address public immutable POSITION_MANAGER;

    struct RelevantInputs {
        address token0;
        address token1 ;
        address tokenOut;
        address recipient;
        bool isPayableInput;
    }

    // initialize struct with nil addresses
    RelevantInputs private _relevantInputs = RelevantInputs({
        token0: address(0),
        token1: address(0),
        tokenOut: address(0),
        recipient: address(0),
        isPayableInput: false
    });

    constructor(address _positionManager) {
        POSITION_MANAGER = _positionManager;
    }

    function _decodeInput(bytes1 commandType, bytes calldata inputs)
        internal
        returns (RelevantInputs memory relevantInputs)
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
                        // TODO: check if this is duplicate from main adapter contract
                        assert(recipient == address(this));
                        _relevantInputs.token0 = path.toAddress();
                        _relevantInputs.tokenOut = path.toBytes(path.length - 20).toAddress();
                        _relevantInputs.recipient = recipient;
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
                        _relevantInputs.tokenOut = path.toAddress();
                        _relevantInputs.token0 = path.toBytes(path.length - 20).toAddress();
                        _relevantInputs.recipient = recipient;
                    } else if (command == Commands.PERMIT2_TRANSFER_FROM) {
                        // return nil values and do nothing
                        return _relevantInputs;
                    } else if (command == Commands.PERMIT2_PERMIT_BATCH) {
                        return _relevantInputs;
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
                        // TODO: check if should validate token, as should return recipient
                        //Payments.sweep(token, address(this), amountMin);
                        _relevantInputs.recipient = recipient;
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
                        _relevantInputs.recipient = recipient;
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
                        _relevantInputs.token0 = path[0];
                        _relevantInputs.tokenOut = path[1];
                        _relevantInputs.recipient = recipient;
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
                        _relevantInputs.token0 = path[0];
                        _relevantInputs.tokenOut = path[1];
                        _relevantInputs.recipient = recipient;
                    } else if (command == Commands.PERMIT2_PERMIT) {
                        return _relevantInputs;
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
                        // TODO: check why we directly call, as the core adapter will try to execute
                        //Payments.wrapETH(_mapRecipient(recipient), amount);
                        // if we call directly the target contract, we should return to skip swap checks,
                        // which would result in revert
                        _relevantInputs.recipient = recipient;
                        _relevantInputs.isPayableInput = true;
                    } else if (command == Commands.UNWRAP_WETH) {
                        // equivalent: abi.decode(inputs, (address, uint256))
                        address recipient;
                        //uint256 amountMin;
                        assembly {
                            recipient := calldataload(inputs.offset)
                            //amountMin := calldataload(add(inputs.offset, 0x20))
                        }
                        assert(recipient == address(this));
                        _relevantInputs.recipient = recipient;
                        // TODO: in auniswap we define but not use recipient, check if direct weth call
                    } else if (command == Commands.PERMIT2_TRANSFER_FROM_BATCH) {
                        return _relevantInputs;
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
                                //IV4Router.ExactInputParams calldata swapParams = paramsAtIndex.decodeSwapExactInParams();
                                IV4Router.ExactInputParams memory swapParams = abi.decode(paramsAtIndex, (IV4Router.ExactInputParams));
                                uint256 pathLength = swapParams.path.length;
                                //Currency currencyIn = swapParams.currencyIn;
                                //PathKey calldata pathKey;

                                // TODO: remove if unused
                                //for (uint256 i = 0; i < pathLength; i++) {
                                //    pathKey = swapParams.path[i];
                                //    (PoolKey memory poolKey, /*bool*/) = pathKey.getPoolAndSwapDirection(currencyIn);
                                //    // just an example of requirements on uniswap hook
                                //    // TODO: initially it would be appropriate to require hookData.length == 0
                                //    //require(!pathKey.hooks.getHookPermissions().afterSwap, HookPermissionError());
                                //}

                                _relevantInputs.token0 = Currency.unwrap(swapParams.currencyIn);
                                _relevantInputs.tokenOut = Currency.unwrap(swapParams.path[pathLength - 1].intermediateCurrency);
                            } else if (action == Actions.SWAP_EXACT_IN_SINGLE) {
                                //IV4Router.ExactInputSingleParams calldata swapParams = paramsAtIndex.decodeSwapExactInSingleParams();
                                IV4Router.ExactInputSingleParams memory swapParams = abi.decode(paramsAtIndex, (IV4Router.ExactInputSingleParams));
                                _relevantInputs.token0 = Currency.unwrap(swapParams.poolKey.currency0);
                                _relevantInputs.tokenOut = Currency.unwrap(swapParams.poolKey.currency1);
                            } else if (action == Actions.SWAP_EXACT_OUT) {
                                //IV4Router.ExactOutputParams calldata swapParams = paramsAtIndex.decodeSwapExactOutParams();
                                IV4Router.ExactOutputParams memory swapParams = abi.decode(paramsAtIndex, (IV4Router.ExactOutputParams));
                                uint256 pathLength = swapParams.path.length;
                                _relevantInputs.tokenOut = Currency.unwrap(swapParams.currencyOut);
                                _relevantInputs.token0 = Currency.unwrap(swapParams.path[pathLength - 1].intermediateCurrency);
                            } else if (action == Actions.SWAP_EXACT_OUT_SINGLE) {
                                //IV4Router.ExactOutputSingleParams calldata swapParams = paramsAtIndex.decodeSwapExactOutSingleParams();
                                IV4Router.ExactOutputSingleParams memory swapParams = abi.decode(paramsAtIndex, (IV4Router.ExactOutputSingleParams));
                                _relevantInputs.token0 = Currency.unwrap(swapParams.poolKey.currency1);
                                _relevantInputs.tokenOut = Currency.unwrap(swapParams.poolKey.currency0);
                            }
                        } else {
                            if (action == Actions.SETTLE_PAIR) {
                                // TODO: verify we cannot decode recipient, i.e. not an input for settle
                                //(Currency currency0, Currency currency1) = paramsAtIndex.decodeCurrencyPair();
                                (Currency currency0, Currency currency1) = abi.decode(paramsAtIndex, (Currency, Currency));
                                _relevantInputs.token0 = Currency.unwrap(currency0);
                                _relevantInputs.tokenOut = Currency.unwrap(currency1);
                            } else if (action == Actions.TAKE_PAIR) {
                                //(Currency currency0, Currency currency1, address recipient) = paramsAtIndex.decodeCurrencyPairAndAddress();
                                (Currency currency0, Currency currency1, address recipient) = abi.decode(paramsAtIndex, (Currency, Currency, address));
                                _relevantInputs.token0 = Currency.unwrap(currency0);
                                _relevantInputs.tokenOut = Currency.unwrap(currency1);
                                _relevantInputs.recipient = recipient;
                            } else if (action == Actions.SETTLE) {
                                //(Currency currency, uint256 amount, bool payerIsUser) = paramsAtIndex.decodeCurrencyUint256AndBool();
                                (Currency currency, /*uint256 amount*/, /*bool payerIsUser*/) = abi.decode(paramsAtIndex, (Currency, uint256, bool));
                                //_settle(currency, _mapPayer(payerIsUser), _mapSettleAmount(amount, currency));
                                _relevantInputs.token0 = Currency.unwrap(currency);
                            } else if (action == Actions.TAKE) {
                                //(Currency currency, address recipient, uint256 amount) = paramsAtIndex.decodeCurrencyAddressAndUint256();
                                (Currency currency, address recipient, /*uint256 amount*/) = abi.decode(paramsAtIndex, (Currency, address, uint256));
                                //_take(currency, _mapRecipient(recipient), _mapTakeAmount(amount, currency));
                                _relevantInputs.token0 = Currency.unwrap(currency);
                                _relevantInputs.recipient = recipient;
                            } else if (action == Actions.CLOSE_CURRENCY) {
                                // TODO: in these methods, we should check if simply return to skip checks if possible
                                //Currency currency = paramsAtIndex.decodeCurrency();
                                Currency currency = abi.decode(paramsAtIndex, (Currency));
                                //_close(currency);
                                _relevantInputs.token0 = Currency.unwrap(currency);
                                //return _relevantInputs;
                            } else if (action == Actions.CLEAR_OR_TAKE) {
                                //(Currency currency, uint256 amountMax) = paramsAtIndex.decodeCurrencyAndUint256();
                                (Currency currency, /*uint256 amountMax*/) = abi.decode(paramsAtIndex, (Currency, uint256));
                                _relevantInputs.token1 = Currency.unwrap(currency);
                                //_clearOrTake(currency, amountMax);
                                //return _relevantInputs;
                            } else if (action == Actions.SWEEP) {
                                //(Currency currency, address to) = paramsAtIndex.decodeCurrencyAndAddress();
                                (Currency currency, /*address to*/) = abi.decode(paramsAtIndex, (Currency, address));
                                //_sweep(currency, _mapRecipient(to));
                                _relevantInputs.token1 = Currency.unwrap(currency);
                                //return _relevantInputs;
                            }
                        }
                    }
                } else if (command == Commands.V3_POSITION_MANAGER_PERMIT) {
                    return _relevantInputs;
                } else if (command == Commands.V3_POSITION_MANAGER_CALL) {
                    bytes4 selector;
                    assembly {
                        selector := calldataload(inputs.offset)
                    }

                    // TODO: check why we introduced this assertion
                    //if (!isValidAction(selector)) {
                    //    revert InvalidAction(selector);
                    //}

                    uint256 tokenId;
                    assembly {
                        // tokenId is always the first parameter in the valid actions
                        tokenId := calldataload(add(inputs.offset, 0x04))
                    }

                    // If any other address that is not the owner wants to call this function, it also needs to be approved (in addition to this contract)
                    // This can be done in 2 ways:
                    //    1. This contract is permitted for the specific token and the caller is approved for ALL of the owner's tokens
                    //    2. This contract is permitted for ALL of the owner's tokens and the caller is permitted for the specific token
                    // TODO: check why we introduced this selector
                    //if (!isAuthorizedForToken(msgSender(), tokenId)) {
                    //    revert NotAuthorizedForToken(tokenId);
                    //}

                    // TODO: remove direct call to target
                    //(success, output) = address(V3_POSITION_MANAGER).call(inputs);
                } else if (command == Commands.V4_POSITION_CALL) {
                    // should only call modifyLiquidities() to mint
                    // do not permit or approve this contract over a v4 position or someone could use this command to decrease, burn, or transfer your position
                    (bytes memory actions, bytes[] memory params) = abi.decode(inputs, (bytes, bytes[]));

                    uint256 numActions = actions.length;
                    assert(numActions == params.length);

                    for (uint256 actionIndex = 0; actionIndex < numActions; actionIndex++) {
                        uint256 action = uint8(actions[actionIndex]);
                        bytes memory paramsAtIndex = params[actionIndex];

                        if (action == Actions.INCREASE_LIQUIDITY) {
                            (uint256 tokenId, /*uint256 liquidity*/, /*uint128 amount0Max*/, /*uint128 amount1Max*/, /*bytes memory hookData*/) =
                                abi.decode(paramsAtIndex, (uint256, uint256, uint128, uint128, bytes));
                            (PoolKey memory poolKey, ) = IPositionManager(POSITION_MANAGER).getPoolAndPositionInfo(tokenId);
                            _relevantInputs.token0 = Currency.unwrap(poolKey.currency0);
                            _relevantInputs.token1 = Currency.unwrap(poolKey.currency1);
                        } else if (action == Actions.DECREASE_LIQUIDITY) {
                            //(uint256 tokenId, uint256 liquidity, uint128 amount0Min, uint128 amount1Min, bytes memory hookData) =
                            //    abi.decode(paramsAtIndex, (uint256, uint256, uint128, uint128, bytes));
                            return _relevantInputs;
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
                            assert(owner == address(this));
                            _relevantInputs.token0 = Currency.unwrap(poolKey.currency0);
                            _relevantInputs.token1 = Currency.unwrap(poolKey.currency1);
                        } else if (action == Actions.BURN_POSITION) {
                            return _relevantInputs;
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
                (bytes memory _commands, bytes[] memory _inputs) = abi.decode(inputs, (bytes, bytes[]));
                // TODO: check if this call could fail silently and its consequences
                //(address(this)).call(abi.encodeCall(IAUniswapRouter.execute, (_commands, _inputs)));
                IAUniswapRouter(address(this)).execute(_commands, _inputs);
            }
        }

        return _relevantInputs;
    }
}