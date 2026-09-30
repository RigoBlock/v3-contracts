// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

interface IAUniswapRouter {
    /// @notice Thrown when a command recipient is neither the pool nor the router.
    error RecipientNotSmartPoolOrRouter();

    /// @notice Thrown when executing commands with an expired deadline.
    error TransactionDeadlinePassed();

    /// @notice Thrown when the pool is not the position owner.
    error PositionOwner();

    /// @notice Thrown when the pool reached maximum number of liquidity positions.
    error UniV4PositionsLimitExceeded();

    /// @notice Thrown when a pool hook can access liquidity deltas.
    error LiquidityMintHookError(address hook);

    /// @notice Thrown when the pool does not hold enough balance.
    error InsufficientNativeBalance();

    /// @notice Thrown when the calldata contains both mint and increase for the same tokenId.
    error PositionDoesNotExist();

    /// @notice Thrown when a universal router command is not supported.
    /// @param commandType The unsupported command byte.
    error InvalidCommandType(uint256 commandType);

    /// @notice Thrown when a v4 swap action inside a V4_SWAP command is not supported.
    /// @param action The unsupported action byte.
    error UnsupportedAction(uint256 action);

    /// @notice Emitted when a Uniswap V4 liquidity position token ID is tracked by the pool.
    /// @param tokenId The ERC-721 token ID of the newly minted V4 position.
    event UniV4PositionAdded(uint256 indexed tokenId);

    /// @notice Emitted when a tracked Uniswap V4 liquidity position token ID is removed.
    /// @param tokenId The ERC-721 token ID of the burned V4 position.
    event UniV4PositionRemoved(uint256 indexed tokenId);

    /// @notice Executes encoded commands along with provided inputs. Reverts if deadline has expired.
    /// @param commands A set of concatenated commands, each 1 byte in length.
    /// @param inputs An array of byte strings containing abi encoded inputs for each command.
    /// @param deadline The deadline by which the transaction must be executed.
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external;

    /// @notice Executes encoded commands along with provided inputs.
    /// @param commands A set of concatenated commands, each 1 byte in length.
    /// @param inputs An array of byte strings containing abi encoded inputs for each command.
    /// @dev Only mint call has access to state, will revert with direct calls unless recipient is explicitly set to this.
    function execute(bytes calldata commands, bytes[] calldata inputs) external;

    /// @notice Executes a Uniswap V4 Posm liquidity transaction.
    /// @param unlockData Encoded calldata containing actions to be executed.
    /// @param deadline Deadline of the transaction.
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external;
}
