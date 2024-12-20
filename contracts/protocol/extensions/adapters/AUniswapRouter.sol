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
import "../../../libraries/EnumerableSet.sol";

/// @title AUniswapRouter - Allows interactions with the Uniswap universal router contracts.
/// @notice This contract is used as a bridge between a Rigoblock smart pool contract and the Uniswap universal router.
/// @dev This contract ensures that tokens are approved and disapproved correctly, and that recipients and tokens are validated.
/// @author Gabriele Rigo - <gab@rigoblock.com>
contract AUniswapRouter is IAUniswapRouter, AUniswapDecoder {
    using CalldataDecoder for bytes;
    using EnumerableSet for Set;

    // assign randomly big storage slots to transient types not supported by solc
    bytes32 internal constant _ALL_COMMANDS_SLOT = bytes32(uint256(keccak256("AUniswapRouter.allCommands")) - 1);
    bytes32 internal constant _ALL_INPUTS_SLOT = bytes32(uint256(keccak256("AUniswapRouter.allInputs")) - 1);
    bytes32 private constant _TOKENS_IN_SLOT = bytes32(uint256(keccak256("AUniswapRouter.tokensIn")) - 1);
    bytes32 private constant _TOKENS_OUT_SLOT = bytes32(uint256(keccak256("AUniswapRouter.tokensOut")) - 1);
    bytes32 private constant _RECIPIENTS_SLOT = bytes32(uint256(keccak256("AUniswapRouter.recipients")) - 1);

    uint256 private constant NIL_VALUE = 0;

    // TODO: check store as inintiate instances
    address private immutable _uniswapRouter;
    address private immutable _positionManager;

    // we keep track of all commands, appending a sub-plan's commands
    uint256 private transient _allCommandsCount;
    uint8 private transient _reentrancyDepth;

    uint256 private transient _value;

    bool private transient _locked;

    /// @notice Thrown when executing commands with an expired deadline
    error TransactionDeadlinePassed();

    /// @notice Thrown when attempting to execute commands and an incorrect number of inputs are provided
    error LengthMismatch();
    error TokenPriceFeedError(address token);
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
        // solhint-disable transient-storage-not-cleared
        // duplicate check from universal router, as we manipulate inputs before forwarding
        uint256 numCommands = commands.length;
        require(numCommands == inputs.length, LengthMismatch());

        // loop through all given commands, verify their inputs and pass along outputs as defined
        for (uint256 i = 0; i < numCommands; i++) {
            bytes calldata input = inputs[i];
            InputState memory inputState = _decodeInput(commands[i], input);

            // we temporary store only if the returned input exists
            // TODO: verify we are always writing filteredInput for implemented commands
            if (inputState.filteredInput.length > 0) {
                _processInputState(inputState);
                _allCommandsCount++;
            }
        }

        // only execute when finished decoding inputs
        if (_reentrancyDepth == 1) {
            _assertTokensOutHavePriceFeed();
            _assertRecipientIsThisAddress();

            (bytes memory finalCommands, bytes[] memory finalInputs) = _loadFinalCommandsAndInputs();

            // we approve all the tokens that are exiting the smart pool
            _safeApproveTokensIn(uniswapRouter(), type(uint256).max);

            // we forward the validate filtered inputs to the Uniswap universal router
            try IAUniswapRouter(uniswapRouter()).execute{value: _value}(abi.encodePacked(finalCommands), finalInputs) returns (bytes memory result) {
                returnData = result;
            } catch Error(string memory reason) {
                revert(reason);
            } catch (bytes memory lowLevelData) {
                revert(string(lowLevelData));
            }

            // we remove allowance without clearing storage
            _safeApproveTokensIn(uniswapRouter(), 1);
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

    // active applications are stored as a packed single uint256, without length
    struct TokenIdSlot {
        uint256[] tokenIds;
    }

    function uniV4TokenIds() internal pure returns (ApplicationsSlot storage s) {
        assembly {
            s.slot := _APPLICATIONS_SLOT;
        }
    }

    function _tokensInSlot() internal pure override returns (bytes32) { return _TOKENS_IN_SLOT; }
    function _tokensOutSlot() internal pure override returns (bytes32) { return _TOKENS_OUT_SLOT; }
    function _recipientsSlot() internal pure override returns (bytes32) { return _RECIPIENTS_SLOT; }

    function _addressesSlot(bytes32 slot) internal pure override returns (AddressesSlot storage s) {
        assembly {
            s.slot := slot
        }
    }

    function _assertRecipientIsThisAddress() private {
        AddressesSlot storage rSlot = _addressesSlot(_recipientsSlot());
        for (uint i = 0 ; i < _recipientsCount--; i++) {
            address recipient;
            assembly {
                recipient := tload(add(rSlot.slot, i))
                // we can safely clear slot as we do not need it any more
                tstore(add(rSlot.slot, i), 0)
            }
            require(recipient == address(this), RecipientIsNotSmartPool());
        }
    }

    function _assertTokensOutHavePriceFeed() private {
        AddressesSlot storage tOSlot = _addressesSlot(_tokensOutSlot());
        for (uint i = 0; i < _tokensOutCount--; i++) {
            address tokenOut;
            assembly {
                tokenOut := tload(add(tOSlot.slot, i))
                // we can safely clear slot as we do not need it any more
                tstore(add(tOSlot.slot, i), 0)
            }

            // TODO: we could alternatively directly read from storage slot. Actually we should because this is an adapter.
            Slot storage tokenRegistrySlot = IRigoblockV3PoolState(address(this)).tokenRegistry();
            // we always allow move to base token, which is never added to the tracked list as already stored in its own slot.
            // Base token price feed check is performed at pool initialization
            if (tokenOut != IRigoblockV3Pool(payable(address(this))).getPool().baseToken) {
                // first check in the list of owned assets. If a token is already active, no further check is needed
                if (tokenRegistrySlot.positions[tokenOut] == 0) {
                    // TODO: check if we want to return last obs timestamp from eoracle and assert non null, to save gas
                    // a token is tradable if has price feed against chain currency
                    require(IEOracle(address(this)).hasPriceFeed(tokenOut), TokenPriceFeedError(tokenOut));
                    // TODO: complete the implementation of `addUnique` in enumerable set and assert list is less than 1000 tokens
                    // max num elements assertion should be performed in library that uses EnumerableSet but implements methods
                    // for the active lists, even though we want to abstract that as we do not want to change core when adding new
                    // applications or storage slots
                    _activeTokensSlot().addUnique(tokenOut);
                }
            }
        }
    }

    function _safeApprove(
        address token,
        address spender,
        uint256 amount
    ) private {
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

    // TODO: verify logic is correct when 1. wrapping/unwrapping eth 2. adding to a liquidity position 3. removing from liquidity
    // adding to liquidity should be ok 
    // removing liquidity should instead add token, they should enter the tokensOut checks
    // wrapping should remove, but we could accept if does not (as it's eth)
    // TODO: check this condition is correct, as otherwise it could fail for eth
    function _safeApproveTokensIn(address spender, uint256 amount) private {
        AddressesSlot storage tSlot = _addressesSlot(_tokensInSlot());
        for (uint i = 0; i < _tokensInCount--; i++) {
            address tokenIn;
            assembly {
                tokenIn := tload(add(tSlot.slot, i))
            }

            // early return for chain currency
            // TODO: as eth is only one and is used frequently, we could leave it in the list even if sold. TDB.
            if (tokenIn == ZERO_ADDRESS) {
                if (address(this).balance <= 1) {
                    remove(tokenIn);
                }
                return;
            }

            _safeApprove(tokenIn, spender, amount);

            // assert no approval inflation exists after removing approval
            if (amount == 1) {
                assert(IERC20(tokenIn).allowance(address(this), uniswapRouter()) == 1);
                
                // remove from active tokens if sold entire balance or left 1 to prevent clearing storage
                if (IERC20(tokenIn).balanceOf(address(this)) <= 1) {
                    remove(tokenIn);
                }
                
                // we can safely clear slot as we do not need it any more
                assembly {
                    tstore(add(tSlot.slot, i), 0)
                }
            }
        }
    }

    // loads final values and clears slots after storing them in memory
    function _loadFinalCommandsAndInputs() private returns (bytes memory, bytes[] memory) {
        bytes memory finalCommands = new bytes(_allCommandsCount);
        bytes[] memory finalInputs = new bytes[](_allCommandsCount);

        bytes32 commandsSlot = _commandsSlot();
        bytes32 inputsSlot = _inputsSlot();

        for (uint256 i = 0; i < _allCommandsCount--; i++) {
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
        return (finalCommands, finalInputs);
    }

    function _processInputState(
        InputState memory state
    ) private {
        uint256 inputValue = state.value;
        uint256 command = state.command;
        bytes memory input = state.filteredInput;

        bytes32 commandsSlot = _commandsSlot();
        bytes32 inputsSlot = _inputsSlot();

        assembly {
            // Store command in temporary storage
            let count := _allCommandsCount.slot
            let commandSlot := add(commandsSlot, mul(count, 0x20))
            tstore(commandSlot, command)

            // Store input offset and length in temporary storage
            let inputSlot := add(inputsSlot, mul(count, 0x40))
            let dataOffset := add(input, 0x20)
            let dataLength := mload(input)

            // Store the offset and length
            tstore(inputSlot, dataOffset)
            tstore(add(inputSlot, 1), dataLength)

            // Store the actual byte data
            for { let k := 0 } lt(k, div(add(dataLength, 31), 32)) { k := add(k, 1) } {
                let data := mload(add(dataOffset, mul(k, 0x20)))
                tstore(add(inputSlot, add(2, k)), data)  // +2 to skip over the offset and length slots
            }
        }

        // We assume wrapETH can be invoked multiple times for multiple swaps, and forward the total as msg.value
        if (inputValue > NIL_VALUE) {
            _value += inputValue;
        }
    }
}
