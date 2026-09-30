// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.0;

import {IGovernor as IOZGovernor} from "@openzeppelin-gov/governance/IGovernor.sol";
import "./interfaces/governance/IGovernanceCrosschain.sol";
import "./interfaces/governance/IGovernanceEvents.sol";
import "./interfaces/governance/IGovernanceInitializer.sol";
import "./interfaces/governance/IGovernanceState.sol";
import "./interfaces/governance/IGovernanceUpgrade.sol";
import "./interfaces/governance/IGovernanceVoting.sol";

/// @title Rigoblock governance aggregate interface.
/// @dev Inherits the OpenZeppelin Governor and ERC-6372 interfaces so external tooling
///      compatibility (Tally) is enforced at compile time. Specification: docs/governance/TALLY_COMPAT.md.
abstract contract IRigoblockGovernance is
    IGovernanceCrosschain,
    IGovernanceEvents,
    IGovernanceInitializer,
    IGovernanceUpgrade,
    IGovernanceVoting,
    IGovernanceState,
    IOZGovernor
{}
