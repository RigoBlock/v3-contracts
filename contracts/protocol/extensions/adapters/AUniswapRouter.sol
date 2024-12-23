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

import {TransientSlot} from "@openzeppelin/contracts/contracts/utils/TransientSlot.sol";
import "@uniswap/v4-periphery/src/libraries/CalldataDecoder.sol";
import "./AUniswapDecoder.sol";
import "./interfaces/IAUniswapRouter.sol";
import "../../../libraries/EnumerableSet.sol";

/// @title AUniswapRouter - Allows interactions with the Uniswap universal router contracts.
/// @notice This contract is used as a bridge between a Rigoblock smart pool contract and the Uniswap universal router.
/// @dev This contract ensures that tokens approvals are set and removed correctly, and that recipient and tokens are validated.
/// @author Gabriele Rigo - <gab@rigoblock.com>
contract AUniswapRouter is IAUniswapRouter, AUniswapDecoder {
    using CalldataDecoder for bytes;
    using EnumerableSet for Set;
    // TODO: these will be conflicting with persistent storage slots?
    using TransientSlot for UintsSlot;
    using TransientSlot for AddressesSlot;

    // transient storage slots
    bytes32 internal constant _ALL_COMMANDS_SLOT = bytes32(uint256(keccak256("AUniswapRouter.allCommands")) - 1);
    bytes32 internal constant _ALL_INPUTS_SLOT = bytes32(uint256(keccak256("AUniswapRouter.allInputs")) - 1);
    bytes32 internal constant _LOCK_SLOT = bytes32(uint256(keccak256("AUniswapRouter.lock")) - 1);
    bytes32 private constant _REENTRANCY_DEPTH_SLOT = bytes32(uint256(keccak256("AUniswapRouter.reentrancy.depth")) - 1);
    bytes32 private constant _TOKENS_IN_SLOT = bytes32(uint256(keccak256("AUniswapRouter.tokensIn")) - 1);
    bytes32 private constant _TOKENS_OUT_SLOT = bytes32(uint256(keccak256("AUniswapRouter.tokensOut")) - 1);
    bytes32 private constant _TRANSACTION_VALUE_SLOT = bytes32(uint256(keccak256("AUniswapRouter.transaction.value")) - 1);

    // TODO: verify import from common library as EApps uses the same slot
    // persistent storage slots
    bytes32 private constant _TOKEN_REGISTRY_SLOT == bytes32(uint256(keccak256("pool.proxy.token.registry")) - 1)
    bytes32 private constant _UNIV4_TOKEN_IDS_SLOT = bytes32(uint256(keccak256("Proxy.uniV4.tokenIds")) - 1);

    uint256 private constant NIL_VALUE = 0;
    uint256 private constant _MAX_TOKEN_COUNT = 255;

    // TODO: check store as inintiate instances
    address private immutable _uniswapRouter;
    address private immutable _positionManager;

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

    function _commandsSlot() private pure returns (bytes32) { return _ALL_COMMANDS_SLOT; }
    function _inputsSlot() private pure returns (bytes32) { return _ALL_INPUTS_SLOT; }
    function _lockSlot() private pure returns (bytes32) { return _LOCK_SLOT; }
    function _reentrancyDepthSlot() private pure returns (bytes32) { return _REENTRANCY_DEPTH_SLOT; }
    function _tokensInSlot() private pure returns (bytes32) { return _TOKENS_IN_SLOT; }
    function _tokensOutSlot() private pure returns (bytes32) { return _TOKENS_OUT_SLOT; }
    function _valueSlot() private pure returns (bytes32) { return _TRANSACTION_VALUE_SLOT; }

    // TODO: these should be only delegatecall to avoid users storing tokens and positions in this contract?
    // however, functions will fail as the contract will try to get a price feed from itself, which will revert
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
        nonReentrant()
        returns (bytes memory returnData)
    {
        // solhint-disable transient-storage-not-cleared
        // duplicate check from universal router, as we manipulate inputs before forwarding
        uint256 numCommands = commands.length;
        require(numCommands == inputs.length, LengthMismatch());

        // loop through all given commands, verify their inputs and pass along outputs as defined
        for (uint256 i = 0; i < numCommands; i++) {
            bytes calldata input = inputs[i];
            (InputState memory inputState, Parameters memory params) = _decodeInput(commands[i], input);

            // we temporary store only if the returned input exists
            // TODO: verify we are always writing filteredInput for implemented commands
            if (inputState.filteredInput.length > 0) {
                _processInputState(inputState);
                _processParams(params);
                _allCommandsCount++;
            }
        }

        // only execute when finished decoding inputs
        if (_reentrancyDepth == 1) {
            _assertTokensOutHavePriceFeed();
            _assertRecipientIsThisAddress();
            _updateTokenIdsAsNeeded();

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

    // TODO: must make sure we are writing to the proxy storage, not the adapter storage
    // active applications are stored as a packed single uint256, without length
    struct TokenIdSlot {
        uint256[] tokenIds;
    }

    function uniV4TokenIds() internal pure returns (TokenIdSlot storage s) {
        assembly {
            s.slot := _TOKEN_IDS_SLOT;
        }
    }

    // applications stored as bitmap
    struct ApplicationsSlot {
        uint256 applications;
    }

    // TODO: added slot to purge application, but can do in future release
    function activeApplications() internal pure returns (ApplicationsSlot storage s) {
        assembly {
            s.slot := _APPLICATIONS_SLOT;
        }
    }

    struct ActiveTokensSlot {
        address[] tokens;
    }

    function activeTokens() internal pure returns (ActiveTokensSlot storage s) {
        assembly {
            s.slot := _TOKEN_REGISTRY_SLOT;
        }
    }

    function _assertTokensOutHavePriceFeed() private {
        // array length is stored at slot position
        uint256 length = _tokensOutSlot().slot;
        bytes32 tokensSlot = _tokensOutSlot().deriveArray();

        // load active tokens from storage
        AddressSet[] storage activeTokensSlot = activeTokens();

        for (uint i = 0; i < length; i++) {
            address tokenOut;
            bytes32 offset = _tokensOutSlot().offset(i);
            tokenOut = offset.tload();
            offset.tstore(0); // clear temporary storage slot

            // we push any target token, even null or base token, which is added at mint and never purged.
            // Position 0 is sentinel for non active.
            if (activeTokensSlot.positions[tokenOut] == 0) {
                require(activeTokensSlot().tokens.length <= _MAX_TOKEN_COUNT, MaxActiveTokenReached());

                // verify price feed exists. Call context sender is pool, call will be staticcall to oracle extension.
                require(IEOracle(address(this)).hasPriceFeed(tokenOut), TokenPriceFeedError(tokenOut));
                // TODO: verify variables names correct
                // verify tokenOut has a price feed in the oracle extension
                activeTokensSlot().tokens.push();
                activeTokensSlot().positions[tokenOut] == activeTokensSlot().tokens.length;

                // TODO: complete EnumberableSet library and type definition, possily use method
                //_activeTokensSlot().addUnique(tokenOut);
            }
        }
        _tokensOutSlot().tstore(0); // clear temporary storage
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

    // TODO: should store length at slot, and elements of array at slot hash
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

    function _processParams(Parameters memory params) {
        // update tokenIds in proxy persistent storage. No benefit in appending to array for later executing.
        uint256[] storage tokenIds = uniV4TokenIds().slot;
        if (params.tokenId != 0) {
            // negative value is a sentinel for burn
            if (params.tokenId > 0) {
                require(tokenIds.length < 255, UniV4PositionsLimitExceeded());
                tokenIds.push(params.tokenId);
            } else {
                for (uint i = 0; i < tokenIds.length; i++) {
                    if (tokenIds[i] == tokenId) {
                        tokenIds[i] = tokenIds[tokenIds.length];
                        tokenIds.pop();
                        break;
                    }
                }
            }
        }

        // simple request, no benefit in adding to temporary storage
        require(recipient == address(this), RecipientIsNotSmartPool());

        // append tokensIn, tokensOut
    }
}
