// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.0;

import {IGovernanceVoting} from "../interfaces/governance/IGovernanceVoting.sol";

/// @notice Native Rigoblock proposal states.
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

/// @notice Governance mode of a chain, fixed in the strategy at deployment.
enum GovernanceMode {
    Sender,
    Dual,
    Receiver
}

/// @notice Payload delivered through Wormhole to a target-chain receiver.
/// @param targetWormholeChainId Wormhole chain id of the target chain.
/// @param proposalId Mainnet proposal id that produced the message.
/// @param actions Actions to execute on the target chain.
struct CrossChainPayload {
    uint16 targetWormholeChainId;
    uint256 proposalId;
    IGovernanceVoting.ProposedAction[] actions;
}
