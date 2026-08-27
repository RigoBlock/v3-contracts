// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import "./interfaces/governance/IGovernanceEvents.sol";
import "./interfaces/governance/IGovernanceInitializer.sol";
import "./interfaces/governance/IGovernanceState.sol";
import "./interfaces/governance/IGovernanceUpgrade.sol";
import "./interfaces/governance/IGovernanceVoting.sol";

interface IRigoblockGovernance is
    IGovernanceEvents,
    IGovernanceInitializer,
    IGovernanceUpgrade,
    IGovernanceVoting,
    IGovernanceState
{}
