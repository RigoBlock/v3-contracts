// SPDX-License-Identifier: Apache-2.0-or-later
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

import "@uniswap/v4-periphery/src/libraries/CalldataDecoder.sol";
import "./AUniswapDecoder.sol";
import "./interfaces/IAUniswapRouter.sol";

/// @title AUniswapRouter - Allows interactions with the Uniswap universal router contracts.
/// @notice This contract is used as a bridge between a Rigoblock smart pool contract and the Uniswap universal router.
/// @dev This contract ensures that tokens are approved and disapproved correctly, and that recipients and tokens are validated.
/// @author Gabriele Rigo - <gab@rigoblock.com>
contract AUniswapRouter is IAUniswapRouter, AUniswapDecoder {
    using CalldataDecoder for bytes;

    address private immutable _uniswapRouter;
    address private immutable _positionManager;

    // Use transient for temporary storage that doesn't need to persist
    // Initialize counters for transient storage, so we can forward sub plan to self
    uint256 private transient tokensInCount;
    uint256 private transient tokensOutCount;
    uint256 private transient recipientsCount;

    uint256 private transient value;

    /// @notice Thrown when executing commands with an expired deadline
    error TransactionDeadlinePassed();

    /// @notice Thrown when attempting to execute commands and an incorrect number of inputs are provided
    error LengthMismatch();
    error TokenNotWhitelisted(address token);
    error RecipientIsNotSmartPool();
    error ApprovalFailed(address target);
    error TargetIsNotContract();

    constructor(address _universalRouter, address _v4positionManager) {
        _uniswapRouter = _universalRouter;
        _positionManager = _v4positionManager;
    }

    modifier checkDeadline(uint256 deadline) {
        require(block.timestamp <= deadline, TransactionDeadlinePassed());
        _;
    }

    /// @inheritdoc IAUniswapRouter
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        override
        checkDeadline(deadline)
        returns (bytes memory returnData)
    {
        return execute(commands, inputs);
    }

    /// @inheritdoc IAUniswapRouter
    // TODO: protect from reentrancy
    function execute(bytes calldata commands, bytes[] calldata inputs)
        public
        payable
        override
        returns (bytes memory returnData)
    {
        // TODO: check we want to silence warning and are successfully doing so
        // solhint-disable transient-storage-not-cleared
        // duplicate check from universal router, as we manipulate inputs before forwarding
        uint256 numCommands = commands.length;
        require(numCommands == inputs.length, LengthMismatch());

        bytes[] memory newInputs = new bytes[](numCommands);
        uint256[] memory newCommands = new uint256[](numCommands);
        uint256 newNumCommands = 0;

        // loop through all given commands, verify their inputs and pass along outputs as defined
        for (uint256 i = 0; i < numCommands; i++) {
            uint256 command = uint8(commands[i] & Commands.COMMAND_TYPE_MASK);
            bytes calldata input = inputs[i];

            // Handle EXECUTE_SUB_PLAN separately
            // TODO: to avoid complex logic, we could make assumption that subplans are executed last, so we could store them in an array, skip appending
            //  and execute them via a new execute call to self
            if (command == Commands.EXECUTE_SUB_PLAN) {
                //(bytes memory subCommands, bytes[] memory subInputs) = abi.decode(input, (bytes, bytes[]));
                (bytes calldata subCommands, bytes[] calldata subInputs) = input.decodeActionsRouterParams();

                bytes[] memory newSubInputs = new bytes[](subCommands.length);
                uint256[] memory newSubCommands = new uint256[](subCommands.length);
                uint256 newSubNumCommands = 0;

                for (uint256 j = 0; j < subCommands.length; j++) {
                    uint256 subCommand = uint8(subCommands[j] & Commands.COMMAND_TYPE_MASK);
                    bytes calldata subInput = subInputs[j];

                    RelevantInputs memory relevantSubInputs = _decodeInput(subCommands[j], subInput);

                    if (relevantSubInputs.recipient != SKIP_FLAG) {
                        // Add the subInput to newSubInputs at the newSubNumCommands position
                        // probably newSubNumCommands could be substituted with j
                        newSubInputs[newSubNumCommands] = subInput;
                        newSubCommands[newSubNumCommands] = subCommand;
                        // TODO: can use inputs length if saves gas by not adding to newSubNumCommands
                        newSubNumCommands++;
                        // TODO: check if passing a struct removes error of too many variables
                        _processRelevantInputs(relevantSubInputs);
                    }
                }

                // Adjust the length of newSubInputs to remove empty fields
                assembly {
                    mstore(newSubInputs, newSubNumCommands)
                    mstore(newSubCommands, newSubNumCommands)
                }

                newInputs[newNumCommands] = abi.encode(abi.encodePacked(newSubCommands), newSubInputs);
                newCommands[newNumCommands] = command;
                newNumCommands++;

                continue;
            }

            RelevantInputs memory relevantInputs = _decodeInput(commands[i], input);

            if (relevantInputs.recipient != SKIP_FLAG) {
                // Add the input to newInputs at the newNumCommands position
                newInputs[newNumCommands] = input;
                newCommands[newNumCommands] = command;
                newNumCommands++;
                _processRelevantInputs(relevantInputs);
            }
        }

        _assertTokensOutWhitelisted();
        _assertRecipientIsThisAddress();

        // we approve all the tokens that are exiting the smart pool
        _safeApproveTokensIn(uniswapRouter(), type(uint256).max);

        // we forward the validate filtered inputs to the Uniswap universal router
        // TODO: commands should be modified to newCommands, including only the filtered ones
        // TODO: if we prompt call to router only after last command decoding, we could possibly simplify by handling EXECUTE_SUB_PLAN as forwarding
        //  to self and making sure the transactions are executed in the correct order, while preserving inputs
        try IAUniswapRouter(uniswapRouter()).execute{value: value}(abi.encodePacked(newCommands), newInputs) returns (bytes memory result) {
            returnData = result;
        } catch Error(string memory reason) {
            revert(reason);
        } catch (bytes memory lowLevelData) {
            revert(string(lowLevelData));
        }

        // we remove allowance without clearing storage
        _safeApproveTokensIn(uniswapRouter(), 1);

        // we clear transient storage
        _clearTransientStorage();
    }

    /// @inheritdoc IAUniswapRouter
    function positionManager() public view override(IAUniswapRouter, AUniswapDecoder) returns (address) {
        return _positionManager;
    }

    /// @inheritdoc IAUniswapRouter
    function uniswapRouter() public view override returns (address universalRouter) {
        return _uniswapRouter;
    }

    function _clearTransientStorage() private {
        uint256 length;
        
        // Clear tokensIn
        assembly {
            length := tload(tokensInCount.slot)
            tstore(tokensInCount.slot, 0)
        }
        for (uint256 i = 0; i < length; i++) {
            assembly {
                tstore(add(1, i), 0)  // Clear starting from slot 1
            }
        }

        // Clear tokensOut
        assembly {
            length := tload(tokensOutCount.slot)
            tstore(tokensOutCount.slot, 0)
        }
        for (uint256 i = 0; i < length; i++) {
            assembly {
                tstore(add(1000, i), 0)  // Clear starting from slot 1000
            }
        }

        // Clear recipients
        assembly {
            length := tload(recipientsCount.slot)
            tstore(recipientsCount.slot, 0)
        }
        for (uint256 i = 0; i < length; i++) {
            assembly {
                tstore(add(2000, i), 0)  // Clear starting from slot 2000
            }
        }
    }

    // TODO: we want just an oracle to exist, but not sure will be launched at v4 release.
    // we will have to store the list of owned tokens once done in order to calculate value.
    function _assertTokensOutWhitelisted() private view {
        for (uint i = 0; i < tokensOutCount; i++) {
            address tokenOut;
            assembly {
                tokenOut := tload(add(1000, i))
            }

            // we allow swapping to base token even if not whitelisted token
            if (tokenOut != IRigoblockV3Pool(payable(address(this))).getPool().baseToken) {
                require(IEWhitelist(address(this)).isWhitelistedToken(tokenOut), TokenNotWhitelisted(tokenOut));
            }
        }
    }

    // TODO: should move method to /lib or similar to reuse for any other methot that requires approval
    function _safeApprove(
        address token,
        address spender,
        uint256 amount
    ) private {
        require(_isContract(token), TargetIsNotContract());
        try IERC20(token).approve(spender, amount) returns (bool success) {
            assert(success);
        } catch {
            try IERC20(token).approve(spender, amount) {}
            // USDT on mainnet requires approval to be set to 0 before being reset again
            catch {
                try IERC20(token).approve(spender, 0) {
                    IERC20(token).approve(spender, amount);
                } catch {
                    // TODO: assert we end up here when `tokenIn` is an EOA
                    // it will end here in any other failure and if it is an EOA
                    revert ApprovalFailed(token);
                }
            }
        }
    }

    function _safeApproveTokensIn(address spender, uint256 amount) private {
        for (uint i = 0; i < tokensInCount; i++) {
            address tokenIn;
            assembly {
                tokenIn := tload(add(1, i))
            }
            _safeApprove(tokenIn, spender, amount);

            // assert no approval inflation exists after removing approval
            if (amount == 1) {
                assert(IERC20(tokenIn).allowance(address(this), uniswapRouter()) == 1);
            }
        }
    }

    function _processRelevantInputs(
        RelevantInputs memory relevantInputs
    ) private {
        address token0 = relevantInputs.token0;
        address token1 = relevantInputs.token1;
        address tokenOut = relevantInputs.tokenOut;
        address recipient = relevantInputs.recipient;
        uint256 inputValue = relevantInputs.value;

        // TODO: check if we are using correct slots
        if (token0 != ZERO_ADDRESS && !_contains(1, tokensInCount, token0)) {
            // equivalent to tokensIn[tokensInCount++] = relevantInputs.token0
            assembly {
                tstore(add(1, tokensInCount.slot), token0)
                tstore(0, add(tokensInCount.slot, 1))
            }
        }

        // TODO: we may not have to assert token1 != token0, as it will not be added if not unique, but might save some gas
        if (token1 != ZERO_ADDRESS && token0 != token1 && !_contains(1, tokensInCount, token1)) {
            // equivalent to tokensIn[tokensInCount++] = relevantInputs.token1;
            assembly {
                tstore(add(1, add(tokensInCount.slot, 1)), token1)
                tstore(0, add(tokensInCount.slot, 2))
            }
        }

        if (tokenOut != ZERO_ADDRESS && !_contains(1000, tokensOutCount, tokenOut)) {
            // equivalent to tokensOut[tokensOutCount++] = relevantInputs.tokenOut;
            assembly {
                tstore(add(1000, tokensOutCount.slot), tokenOut)
                tstore(1, add(tokensOutCount.slot, 1))
            }
        }

        if (recipient != ZERO_ADDRESS && !_contains(2000, recipientsCount, recipient)) {
            // equivalent to recipients[recipientsCount++] = relevantInputs.recipient;
            assembly {
                tstore(add(2000, recipientsCount.slot), recipient)
                tstore(2, add(recipientsCount.slot, 1))
            }
        }

        // We assume wrapETH can be invoked multiple times for multiple swaps, and forward the total as msg.value
        if (inputValue > NIL_VALUE) {
            value += inputValue;
        }
    }

    // instead of overriding the inputs recipient, we simply validate, so we do not need to re-encode the params.
    function _assertRecipientIsThisAddress() private view {
        for (uint i = 0 ; i < recipientsCount; i++) {
            address recipient;
            assembly {
                recipient := tload(add(2000, i))
            }
            require(recipient == address(this), RecipientIsNotSmartPool());
        }
    }

    function _contains(uint256 startSlot, uint256 length, address target) private view returns (bool) {
        for (uint i = 0; i < length; i++) {
            address storedValue;
            assembly {
                storedValue := tload(add(startSlot, i))
            }
            if (storedValue == target) {
                return true;
            }
        }
        return false;
    }

    function _isContract(address target) private view returns (bool) {
        return target.code.length > 0;
    }
}
