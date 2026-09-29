// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.0;

import {IGovernanceVoting} from "../interfaces/governance/IGovernanceVoting.sol";

/// @title GovernanceTypes - Shared types for governance.
/// @notice This file holds types that are not already declared inside the public
///         governance interfaces, which must keep their types as interface members
///         for backwards compatibility with deployed contracts.
///         The native proposal-state enum lives here: inheriting an enum named
///         `ProposalState` would clash with the OpenZeppelin Governor's enum of the
///         same name. The name `ProposalStatus` keeps the two unambiguous.

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

/// @notice Payload delivered through Wormhole to a target-chain receiver.
/// @param targetWormholeChainId Wormhole chain id of the target chain.
/// @param proposalId Mainnet proposal id that produced the message.
/// @param actions Actions to execute on the target chain, in order. Actions may target
///         external contracts or the governance itself (e.g. implementation upgrades).
struct CrossChainPayload {
    uint16 targetWormholeChainId;
    uint256 proposalId;
    IGovernanceVoting.ProposedAction[] actions;
}
