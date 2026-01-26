// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.0;

enum OpType {
    Transfer,
    Sync,
    Unknown
}

struct SourceMessageParams {
    OpType opType;
    uint256 navTolerance;
    uint256 sourceNativeAmount;
    bool shouldUnwrapOnDestination;
}

struct DestinationMessageParams {
    OpType opType;
    bool shouldUnwrapNative;
}

/*//////////////////////////////////////////////////////////////
                    ACROSS MULTICALL HANDLER TYPES
//////////////////////////////////////////////////////////////*/

/// @notice Single call to be executed by Across MulticallHandler
/// @dev Matches Across protocol Call struct exactly
struct Call {
    address target; // Contract to call
    bytes callData; // Encoded function call data
    uint256 value; // ETH value to send with the call
}

/// @notice Complete instructions for MulticallHandler execution
/// @dev Matches Across protocol Instructions struct exactly
struct Instructions {
    Call[] calls; // Array of calls to execute
    address fallbackRecipient; // Where tokens go if calls fail (address(0) = revert on failure)
}
