// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2023 Rigo Intl.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.

*/

pragma solidity >=0.8.0 <0.9.0;

import "../../utils/storageSlot/StorageSlot.sol";
import "../interfaces/IGovernanceStrategy.sol";
import "./MixinStorage.sol"; // storage inherits from interface which declares events

abstract contract MixinUpgrade is MixinStorage {
    // TODO: check if should remove this modifier as these methods can only be invoked by other locked methods
    // locks direct calls to this contract
    modifier onlyDelegatecall() {
        assert(_implementation != address(this));
        _;
    }

    // upgrades must go through voting
    modifier onlyGovernance() {
        require(msg.sender == address(this), "GOV_UPGRADE_APPROVAL_ERROR");
        _;
    }

    /// @inheritdoc IGovernanceUpgrade
    function upgradeImplementation(address newImplementation) external override onlyDelegatecall onlyGovernance {

        // we read the current implementation address from the pool proxy storage
        address currentImplementation = StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value;

        // transaction reverted if implementation is same as current
        require(newImplementation != currentImplementation, "UPGRADE_SAME_AS_CURRENT_ERROR");

        // prevent accidental setting implementation to EOA
        require(_isContract(newImplementation), "UPGRADE_NOT_CONTRACT_ERROR");

        // we write new address to storage at implementation slot location and emit eip1967 log
        StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value = newImplementation;
        emit Upgraded(newImplementation);
    }

    /// @inheritdoc IGovernanceUpgrade
    function updateThresholds(
        uint256 newProposalThreshold,
        uint256 newQuorumThreshold
    ) external override onlyDelegatecall onlyGovernance {
        IGovernanceStrategy(_governanceStrategy().value).assertValidThresholds(newProposalThreshold, newQuorumThreshold);
        _governanceParameters().proposalThreshold = newProposalThreshold;
        _governanceParameters().quorumThreshold = newQuorumThreshold;
        emit ThresholdsUpdated(newProposalThreshold, newQuorumThreshold);
    }

    /// @inheritdoc IGovernanceUpgrade
    function updateGovernanceStrategy(address newStrategy) external override onlyDelegatecall onlyGovernance  {
        address oldStrategy = _governanceStrategy().value;
        assert(newStrategy != oldStrategy);
        require(_isContract(newStrategy), "UPGRADE_NOT_CONTRACT_ERROR");
        _governanceStrategy().value = newStrategy;
        emit StrategyUpdated(newStrategy);
    }

    /// @dev Returns whether an address is a contract.
    /// @return Bool target address has code.
    function _isContract(address target) private view returns (bool) {
        return target.code.length > 0;
    }
}
