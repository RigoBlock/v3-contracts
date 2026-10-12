// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {IGovernanceInitializer} from "../interfaces/governance/IGovernanceInitializer.sol";
import {IGovernanceState} from "../interfaces/governance/IGovernanceState.sol";
import {IGovernanceStrategy} from "../interfaces/IGovernanceStrategy.sol";
import {IRigoblockGovernanceFactory} from "../interfaces/IRigoblockGovernanceFactory.sol";
import {MixinStorage} from "./MixinStorage.sol";

abstract contract MixinInitializer is MixinStorage {
    error GovAlreadyInitialized();
    error InitParamsVerification();

    modifier onlyUninitialized() {
        // proxy is always initialized in the constructor, therefore
        // empty extcodesize means the governance has not been initialized
        require(address(this).code.length == 0, GovAlreadyInitialized());
        _;
    }

    /// @inheritdoc IGovernanceInitializer
    function initializeGovernance() external override onlyUninitialized {
        IRigoblockGovernanceFactory.Parameters memory params = IRigoblockGovernanceFactory(msg.sender).parameters();

        address strategy = params.governanceStrategy;
        // an EOA or non-strategy contract would answer the probe call with empty returndata, so
        // contract existence and interface conformance are asserted before the strategy is used
        require(strategy.code.length > 0, InitParamsVerification());
        try IGovernanceStrategy(strategy).wormhole() returns (address) {} catch {
            revert InitParamsVerification();
        }

        _name().value = params.name;
        _paramsWrapper().governanceParameters = IGovernanceState.GovernanceParameters({
            strategy: strategy,
            proposalThreshold: params.proposalThreshold,
            quorumThreshold: params.quorumThreshold,
            timeType: params.timeType
        });

        // called directly so the strategy's own validation errors surface
        IGovernanceStrategy(strategy).validateParams(params);
    }
}
