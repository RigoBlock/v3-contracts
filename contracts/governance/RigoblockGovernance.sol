// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.35;

import {IGovernanceState} from "./interfaces/governance/IGovernanceState.sol";
import {MixinImmutables} from "./mixins/MixinImmutables.sol";
import {MixinInitializer} from "./mixins/MixinInitializer.sol";
import {MixinState} from "./mixins/MixinState.sol";
import {MixinStorage} from "./mixins/MixinStorage.sol";
import {MixinUpgrade} from "./mixins/MixinUpgrade.sol";
import {MixinVoting} from "./mixins/MixinVoting.sol";
import {IRigoblockGovernance} from "./IRigoblockGovernance.sol";

contract RigoblockGovernance is
    IRigoblockGovernance,
    MixinStorage,
    MixinInitializer,
    MixinUpgrade,
    MixinVoting,
    MixinState
{
    /// @notice Constructor has no inputs to guarantee same deterministic address across chains.
    /// @dev Setting high proposal threshold locks propose action, which also lock vote actions.
    constructor() MixinImmutables() MixinStorage() {
        _paramsWrapper().governanceParameters = IGovernanceState.GovernanceParameters({
            strategy: address(0),
            proposalThreshold: type(uint256).max,
            quorumThreshold: 0,
            timeType: TimeType.Timestamp
        });
    }
}
