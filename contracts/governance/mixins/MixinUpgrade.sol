// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {IGovernanceState} from "../interfaces/governance/IGovernanceState.sol";
import {IGovernanceStrategy} from "../interfaces/IGovernanceStrategy.sol";
import {IGovernanceUpgrade} from "../interfaces/governance/IGovernanceUpgrade.sol";
import {MixinStorage} from "./MixinStorage.sol";

abstract contract MixinUpgrade is MixinStorage {
    /// @notice Thrown when an upgrade method is called by an account other than the governance proxy.
    error GovUpgradeNotApproved();

    /// @notice Thrown when a new threshold, implementation, or strategy is the same as the current one.
    error GovUpgradeSameAsCurrent();

    /// @notice Thrown when an upgrade target is not a contract.
    /// @param target The supplied address.
    error GovUpgradeNotContract(address target);

    // upgrades must go through voting, i.e. execute method, which cannot be invoked directly in the implementation
    modifier onlyGovernance() {
        require(msg.sender == address(this), GovUpgradeNotApproved());
        _;
    }

    /// @inheritdoc IGovernanceUpgrade
    function updateThresholds(
        uint256 newProposalThreshold,
        uint256 newQuorumThreshold
    ) external override onlyGovernance {
        IGovernanceState.GovernanceParameters storage params = _governanceParameters();
        // reverting only when both thresholds are unchanged, as a proposal may legitimately update a single one
        require(
            newProposalThreshold != params.proposalThreshold || newQuorumThreshold != params.quorumThreshold,
            GovUpgradeSameAsCurrent()
        );
        // an unchanged threshold is not re-validated: supply inflation can drift a previously
        // valid threshold out of range, and blocking single-threshold updates would brick governance
        IGovernanceStrategy strategy = IGovernanceStrategy(params.strategy);
        if (newProposalThreshold != params.proposalThreshold) {
            strategy.assertValidProposalThreshold(newProposalThreshold);
        }
        if (newQuorumThreshold != params.quorumThreshold) {
            strategy.assertValidQuorumThreshold(newQuorumThreshold);
        }
        params.proposalThreshold = newProposalThreshold;
        params.quorumThreshold = newQuorumThreshold;
        emit ThresholdsUpdated(newProposalThreshold, newQuorumThreshold);
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
