// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.35;

import "./mixins/MixinInitializer.sol";
import "./mixins/MixinState.sol";
import "./mixins/MixinStorage.sol";
import "./mixins/MixinUpgrade.sol";
import "./mixins/MixinVoting.sol";
import "./IRigoblockGovernance.sol";

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
        _paramsWrapper().governanceParameters = GovernanceParameters({
            strategy: address(0),
            proposalThreshold: type(uint256).max,
            quorumThreshold: 0,
            timeType: TimeType.Timestamp
        });
    }
}
