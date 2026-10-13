// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {IGovernanceState} from "../interfaces/governance/IGovernanceState.sol";
import {IGovernanceStrategy} from "../interfaces/IGovernanceStrategy.sol";
import {IGovernanceUpgrade} from "../interfaces/governance/IGovernanceUpgrade.sol";
import {IRigoblockGovernanceFactory} from "../interfaces/IRigoblockGovernanceFactory.sol";
import {MixinVoting} from "./MixinVoting.sol";

abstract contract MixinUpgrade is MixinVoting {
    /// @notice Thrown when a new threshold, implementation, or strategy is the same as the current one.
    error GovUpgradeSameAsCurrent();

    /// @notice Thrown when an upgrade target is not a contract.
    /// @param target The supplied address.
    error GovUpgradeNotContract(address target);

    /// @inheritdoc IGovernanceUpgrade
    function updateThresholds(
        uint256 newProposalThreshold,
        uint256 newQuorumThreshold
    ) external override onlyGovernance {
        IGovernanceState.GovernanceParameters storage params = _governanceParameters();
        require(
            newProposalThreshold != params.proposalThreshold || newQuorumThreshold != params.quorumThreshold,
            GovUpgradeSameAsCurrent()
        );
        // the post-update parameters must satisfy the strategy's validation so a proposal can never
        // brick the governance with out-of-bounds thresholds; an unchanged threshold is validated in
        // its current form, which supply inflation may have drifted out of range
        IGovernanceStrategy(params.strategy).validateParams(
            IRigoblockGovernanceFactory.Parameters({
                name: _name().value,
                governanceStrategy: params.strategy,
                proposalThreshold: newProposalThreshold,
                quorumThreshold: newQuorumThreshold,
                timeType: params.timeType,
                implementation: address(this)
            })
        );
        params.proposalThreshold = newProposalThreshold;
        params.quorumThreshold = newQuorumThreshold;
        emit ProposalThresholdSet(newProposalThreshold);
    }

    /// @inheritdoc IGovernanceUpgrade
    function upgradeImplementation(address newImplementation) external override onlyGovernance {
        // we read the current implementation address from the governance proxy storage
        address currentImplementation = _implementation().value;

        // transaction reverted if implementation is same as current
        require(newImplementation != currentImplementation, GovUpgradeSameAsCurrent());

        // prevent accidental setting implementation to EOA
        require(_isContract(newImplementation), GovUpgradeNotContract(newImplementation));

        // we write new address to storage at implementation slot location and emit eip1967 log
        _implementation().value = newImplementation;
        emit Upgraded(newImplementation);
    }

    /// @inheritdoc IGovernanceUpgrade
    function upgradeStrategy(address newStrategy) external override onlyGovernance {
        address oldStrategy = _governanceParameters().strategy;
        require(newStrategy != oldStrategy, GovUpgradeSameAsCurrent());
        require(_isContract(newStrategy), GovUpgradeNotContract(newStrategy));

        // we write the new address in the strategy storage slot
        _governanceParameters().strategy = newStrategy;
        emit StrategyUpgraded(newStrategy);
    }

    /// @dev Returns whether an address is a contract.
    /// @return Bool target address has code.
    function _isContract(address target) private view returns (bool) {
        return target.code.length > 0;
    }
}
