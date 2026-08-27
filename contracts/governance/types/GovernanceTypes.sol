// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {IGovernanceVoting} from "../interfaces/governance/IGovernanceVoting.sol";

/// @title GovernanceTypes - Shared types for cross-chain governance messages.
/// @notice This file holds types that are not already declared inside the public
///         governance interfaces, which must keep their types as interface members
///         for backwards compatibility with deployed contracts (e.g. AGovernance).

/// @notice Payload delivered through Wormhole to a target-chain receiver.
/// @param targetWormholeChainId Wormhole chain id of the target chain.
/// @param proposalId Mainnet proposal id that produced the message.
/// @param action Action to execute on the target chain.
struct CrossChainPayload {
    uint16 targetWormholeChainId;
    uint256 proposalId;
    IGovernanceVoting.ProposedAction action;
}
