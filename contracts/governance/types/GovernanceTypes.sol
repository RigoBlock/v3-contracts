// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.0;

/// @title GovernanceTypes - Shared types for governance.
/// @notice Shared governance structs and types live here and are imported by the public
///         interfaces and implementations alike.
///         The native proposal-state enum lives here under the name `ProposalStatus`:
///         two inherited enums cannot share the `ProposalState` name (solc 9097
///         "Identifier already declared" — see `IRigoblockGovernance`, which inherits
///         both `IGovernanceState` and OZ's `IGovernor`), and a name distinct from
///         the OZ enum keeps every use site unambiguous.

/// @notice Native Rigoblock proposal states, a superset of the OZ Governor numbering
///         (adds Qualified). Encoded as uint8; value numbering is part of the
///         externally observable surface and must never change.
enum ProposalStatus {
    Pending,
    Active,
    Canceled,
    Qualified,
    Defeated,
    Succeeded,
    Queued,
    Expired,
    Executed
}

/// @notice A single governance action: a contract call with optional native value.
/// @param target The contract to call.
/// @param data The calldata for the call.
/// @param value The native value attached to the call.
struct ProposedAction {
    address target;
    bytes data;
    uint256 value;
}

/// @notice Per-proposal data the strategy hooks receive and the governance snapshots.
/// @param quorum The quorum threshold snapshotted at proposal time.
/// @param votingPower Total voting power snapshotted on the proposal's first vote; 0 until then.
struct ProposalExtraData {
    uint128 quorum;
    uint128 votingPower;
}

/// @notice Payload delivered through Wormhole to a target-chain receiver.
/// @param targetWormholeChainId Wormhole chain id of the target chain.
/// @param proposalId Mainnet proposal id that produced the message.
/// @param actions Actions to execute on the target chain, in order. Actions may target
///         external contracts or the governance itself (e.g. implementation upgrades).
struct CrossChainPayload {
    uint16 targetWormholeChainId;
    uint256 proposalId;
    ProposedAction[] actions;
}
