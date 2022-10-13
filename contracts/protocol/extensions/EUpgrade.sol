// SPDX-License-Identifier: Apache 2.0

pragma solidity 0.8.17;

import "./adapters/interfaces/IEUpgrade.sol";
import {IRigoblockPoolProxyFactory as Beacon} from "../interfaces/IRigoblockPoolProxyFactory.sol";
import "../../utils/storageSlot/StorageSlot.sol";

contract EUpgrade is IEUpgrade {
    address private immutable eUpgrade;
    // TODO: check if should move beacon to implementation
    address private immutable factory;

    constructor(address _factory) {
        eUpgrade = address(this);
        factory = _factory;
    }

    /// @inheritdoc IEUpgrade
    function upgradeImplementation() external override {
        // prevent direct calls to this contract
        require(eUpgrade != address(this), "EUPGRADE_DIRECT_CALL_ERROR");

        // read implementation address from factory
        address newImplementation = Beacon(factory).implementation();

        // sanity check that the new implementation is a contract
        require(_isContract(newImplementation), "EUPGRADE_IMPLEMENTATION_NOT_CONTRACT_ERROR");

        // we define the storage area where we will write new implementation as the eip1967 implementation slot
        bytes32 implementationSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        assert(implementationSlot == bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1));

        // we read the current implementation address from the pool proxy storage
        address currentImplementation = StorageSlot.getAddressSlot(implementationSlot).value;

        // transaction reverted if implementation is same as current
        require(newImplementation != currentImplementation, "EUPGRADE_IMPLEMENTATION_SAME_AS_CURRENT_ERROR");

        // we write new address to storage at implementation slot location and emit eip1967 log
        StorageSlot.getAddressSlot(implementationSlot).value = newImplementation;
        emit Upgraded(newImplementation);
    }

    function _isContract(address _target) private view returns (bool) {
        return _target.code.length > 0;
    }
}