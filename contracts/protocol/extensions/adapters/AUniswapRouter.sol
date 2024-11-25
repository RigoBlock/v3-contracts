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

    // assign randomly big storage slots to transient types not supported by solc
    bytes32 internal constant _ALL_COMMANDS_SLOT = bytes32(uint256(keccak256("AUniswapRouter.allCommands")) - 1);
    bytes32 internal constant _ALL_INPUTS_SLOT = bytes32(uint256(keccak256("AUniswapRouter.allInputs")) - 1);

    address private immutable _uniswapRouter;
    address private immutable _positionManager;

    // Use transient for temporary storage that doesn't need to persist
    // Initialize counters for transient storage, so we can forward sub plan to self
    // TODO: redefine private as _
    uint256 private transient tokensInCount;
    uint256 private transient tokensOutCount;
    uint256 private transient recipientsCount;

    // we keep track of all commands, appending a sub-plan's commands
    uint256 private transient _allCommandsCount;
    uint8 private transient _reentrancyDepth;

    uint256 private transient value;

    bool private transient _locked;

    /// @notice Thrown when executing commands with an expired deadline
    error TransactionDeadlinePassed();

    /// @notice Thrown when attempting to execute commands and an incorrect number of inputs are provided
    error LengthMismatch();
    error TokenNotWhitelisted(address token);
    error RecipientIsNotSmartPool();
    error ApprovalFailed(address target);
    error TargetIsNotContract();
    error ReentrantCall();
    error NestedSubPlan();

    constructor(address _universalRouter, address _v4positionManager) {
        _uniswapRouter = _universalRouter;
        _positionManager = _v4positionManager;
    }

    modifier checkDeadline(uint256 deadline) {
        require(block.timestamp <= deadline, TransactionDeadlinePassed());
        _;
    }

    modifier nonReentrant() {
        if (!_locked) {
            _locked = true;
            _reentrancyDepth = 0;
        } else {
            require(msg.sender == address(this), ReentrantCall());
        }
        _reentrancyDepth++;
        _;
        _reentrancyDepth--;
        if (_reentrancyDepth == 0) {
            _locked = false;
        }
    }

    struct AllCommands {
        bytes1[] values;
    }

    function allCommands() internal pure returns (AllCommands storage s) {
        bytes32 cSlot = _commandsSlot();
        assembly {
            s.slot := cSlot
        }
    }

    struct InputsStorage {
        mapping(uint256 => bytes) values;
    }

    function allInputs() internal pure returns (InputsStorage storage s) {
        bytes32 iSlot = _inputsSlot();
        assembly {
            s.slot := iSlot
        }
    }

    function _commandsSlot() private pure returns (bytes32) {
        return _ALL_COMMANDS_SLOT;
    }

    function _inputsSlot() private pure returns (bytes32) {
        return _ALL_INPUTS_SLOT;
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
    function execute(bytes calldata commands, bytes[] calldata inputs)
        public
        payable
        override
        nonReentrant
        returns (bytes memory returnData)
    {
        // TODO: check we want to silence warning and are successfully doing so
        // solhint-disable transient-storage-not-cleared
        // duplicate check from universal router, as we manipulate inputs before forwarding
        uint256 numCommands = commands.length;
        require(numCommands == inputs.length, LengthMismatch());

        // loop through all given commands, verify their inputs and pass along outputs as defined
        for (uint256 i = 0; i < numCommands; i++) {
            uint256 command = uint8(commands[i] & Commands.COMMAND_TYPE_MASK);
            bytes calldata input = inputs[i];

            // Handle EXECUTE_SUB_PLAN by forwarding to self and then forwarding the underlying subcommands, stored where?
            if (command == Commands.EXECUTE_SUB_PLAN) {
                (bytes memory subCommands, bytes[] memory subInputs) = abi.decode(input, (bytes, bytes[]));
                
                // ensure a sub-plan does not include nested sub-plans
                for (uint j = 0; j < subCommands.length; j++) {
                    uint256 subCommand = uint8(subCommands[j] & Commands.COMMAND_TYPE_MASK);
                    require(subCommand != Commands.EXECUTE_SUB_PLAN, NestedSubPlan());
                }

                try IAUniswapRouter(address(this)).execute(subCommands, subInputs) returns (bytes memory) {

                } catch Error(string memory reason) {
                    revert(reason);
                }
            } else {
                RelevantInputs memory relevantInputs = _decodeInput(commands[i], input);

                if (relevantInputs.recipient != SKIP_FLAG) {
                    //bytes1[] storage _commands = allCommands().values;
                    //bytes[] storage _inputs = allInputs().values;

                    bytes32 commandsSlot = _commandsSlot();
                    bytes32 inputsSlot = _inputsSlot();
                    //bytes32 inputsSlot = allInputs().values.slot;

                    assembly {
                        // Store command in temporary storage
                        let count := _allCommandsCount.slot
                        let commandSlot := add(commandsSlot, mul(count, 0x20))
                        tstore(commandSlot, command)

                        // Store input offset and length in temporary storage
                        let inputSlot := add(inputsSlot, mul(count, 0x40))
                        let dataOffset := add(input.offset, 0x20)
                        let dataLength := input.length

                        // Store the offset and length
                        tstore(inputSlot, dataOffset)
                        tstore(add(inputSlot, 1), dataLength)

                        // Store the actual byte data
                        for { let k := 0 } lt(k, div(add(dataLength, 31), 32)) { k := add(k, 1) } {
                            let data := calldataload(add(dataOffset, mul(k, 0x20)))
                            tstore(add(inputSlot, add(2, k)), data)  // +2 to skip over the offset and length slots
                        }
                    }
                    _allCommandsCount++;
                    _processRelevantInputs(relevantInputs);
                }
            }
        }

        // only execute when finished decoding inputs
        if (_reentrancyDepth == 1) {
            _assertTokensOutWhitelisted();
            _assertRecipientIsThisAddress();

            bytes memory finalCommands = new bytes(_allCommandsCount);
            bytes[] memory finalInputs = new bytes[](_allCommandsCount);

            bytes32 commandsSlot = _commandsSlot();
            bytes32 inputsSlot = _inputsSlot();

            for (uint256 i = 0; i < _allCommandsCount; i++) {
                assembly {
                    let commandSlot := add(commandsSlot, mul(i, 0x20))
                    mstore(add(finalCommands, add(0x20, i)), tload(commandSlot))
                    tstore(commandSlot, 0)  // Clear command from transient storage

                    // Retrieve the length and data
                    let inputSlot := add(inputsSlot, mul(i, 0x40))
                    let dataLength := tload(add(inputSlot, 1))

                    let memoryPtr := mload(0x40)
                    for { let j := 0 } lt(j, div(add(dataLength, 31), 32)) { j := add(j, 1) } {
                        mstore(add(memoryPtr, mul(j, 0x20)), tload(add(inputSlot, add(2, j))))
                        tstore(add(inputSlot, add(2, j)), 0)  // Clear input data from transient storage
                    }

                    // Set the length of the bytes array in memory
                    mstore(add(finalInputs, add(0x20, mul(i, 0x20))), dataLength)
                    // Copy the data to the correct position in the finalInputs array
                    for { let j := 0 } lt(j, div(add(dataLength, 31), 32)) { j := add(j, 1) } {
                        mstore(add(finalInputs, add(0x40, mul(i, 0x20))), mload(add(memoryPtr, mul(j, 0x20))))
                    }

                    tstore(add(inputSlot, 1), 0)  // Clear the length from transient storage

                    // Update free memory pointer
                    mstore(0x40, add(memoryPtr, and(add(dataLength, 31), not(31))))
                }
            }

            // we approve all the tokens that are exiting the smart pool
            _safeApproveTokensIn(uniswapRouter(), type(uint256).max);

            // we forward the validate filtered inputs to the Uniswap universal router
            try IAUniswapRouter(uniswapRouter()).execute{value: value}(abi.encodePacked(finalCommands), finalInputs) returns (bytes memory result) {
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
        // TODO: check clearing values is not overkill, identify use for abuse
        assembly {
            // Clear tokensIn
            for { let i := 0 } lt(i, tokensInCount.slot) { i := add(i, 1) } {
                tstore(add(1, i), 0)
            }
            // Clear tokensOut
            for { let i := 0 } lt(i, tokensOutCount.slot) { i := add(i, 1) } {
                tstore(add(1000, i), 0)
            }
            // Clear recipients
            for { let i := 0 } lt(i, recipientsCount.slot) { i := add(i, 1) } {
                tstore(add(2000, i), 0)
            }
        }
        // clear counters
        tokensInCount = 0;
        tokensOutCount = 0;
        recipientsCount = 0;
        _allCommandsCount = 0;
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
