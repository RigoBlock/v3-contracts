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
import "./MixinStorage.sol"; // storage inherits from interface which declares events

abstract contract MixinUpgrade is MixinStorage {
    modifier onlyDelegatecall() virtual;

    /// @inheritdoc IRigoblockGovernance
    function upgradeImplementation(address newImplementation) external onlyDelegatecall override {
        // upgrade must go through voting
        require(msg.sender == address(this), "GOV_UPGRADE_APPROVAL_ERROR");

        // we define the storage area where we will write new implementation as the eip1967 implementation slot
        bytes32 implementationSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        assert(implementationSlot == bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1));

        // we read the current implementation address from the pool proxy storage
        address currentImplementation = StorageSlot.getAddressSlot(implementationSlot).value;

        // transaction reverted if implementation is same as current
        require(newImplementation != currentImplementation, "UPGRADE_SAME_AS_CURRENT_ERROR");

        // we write new address to storage at implementation slot location and emit eip1967 log
        StorageSlot.getAddressSlot(implementationSlot).value = newImplementation;
        emit Upgraded(newImplementation);
    }

    /// @inheritdoc IRigoblockGovernance
    function updateThresholds(uint256 newProposalThreshold, uint256 newQuorumThreshold)
        external
        onlyDelegatecall
        override
    {
        require(msg.sender == address(this), "GOV_UPGRADE_ONLY_SELF_ERROR");
        paramsWrapper().treasuryParameters.proposalThreshold = newProposalThreshold;
        paramsWrapper().treasuryParameters.quorumThreshold = newQuorumThreshold;
    }
}