// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.0;

enum OpType {
    Transfer,
    Sync,
    Unknown
}

struct DestinationMessage {
    OpType opType;
    uint256 navTolerance;  // Not used in Transfer mode, only for Sync operations
    bool shouldUnwrap;
    uint256 sourceAmount;   // Original amount sent from source (before solver fees)
}

struct SourceMessage {
    OpType opType;
    uint256 navTolerance;  // Not used in Sync mode
    uint256 sourceNativeAmount;
    bool shouldUnwrapOnDestination;
}