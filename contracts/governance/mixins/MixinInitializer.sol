// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import "../interfaces/IGovernanceStrategy.sol";
import "../interfaces/IRigoblockGovernanceFactory.sol";
import "./MixinStorage.sol";

abstract contract MixinInitializer is MixinStorage {
    error InitParamsVerification();

    modifier onlyUninitialized() {
        // proxy is always initialized in the constructor, therefore
        // empty extcodesize means the governance has not been initialized
        require(address(this).code.length == 0, "ALREADY_INITIALIZED_ERROR");
        _;
    }

    /// @inheritdoc IGovernanceInitializer
    function initializeGovernance() external override onlyUninitialized {
        IRigoblockGovernanceFactory.Parameters memory params = IRigoblockGovernanceFactory(msg.sender).parameters();

        // we require the strategy contract to implement method assertValidInitParams and are not interested in the returned error.
        try IGovernanceStrategy(params.governanceStrategy).assertValidInitParams(params) {} catch {
            revert InitParamsVerification();
        }

        _name().value = params.name;
        _paramsWrapper().governanceParameters = GovernanceParameters({
            strategy: params.governanceStrategy,
            proposalThreshold: params.proposalThreshold,
            quorumThreshold: params.quorumThreshold,
            timeType: params.timeType
        });
    }
}
