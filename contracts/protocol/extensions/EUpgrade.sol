// SPDX-License-Identifier: Apache 2.0

pragma solidity 0.8.17;

import "./adapters/interfaces/IEUpgrade.sol";
import {IRigoblockPoolProxyFactory as Beacon} from "../interfaces/IRigoblockPoolProxyFactory.sol";
import "../../utils/storageSlot/StorageSlot.sol";

contract EUpgrade is IEUpgrade {
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    // check rename beacon to admin or any other slot, i.e. factory slot
    bytes32 internal constant _BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    address private immutable _eUpgrade;

    constructor(address _factory) {
        assert(_IMPLEMENTATION_SLOT == bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1));
        assert(_BEACON_SLOT == bytes32(uint256(keccak256("eip1967.proxy.beacon")) - 1));
        StorageSlot.getAddressSlot(_BEACON_SLOT).value = _factory;
        _eUpgrade = address(this);
    }

    /// @inheritdoc IEUpgrade
    function upgradeImplementation() external override {
        require(_eUpgrade != address(this));
        address newImplementation = Beacon(StorageSlot.getAddressSlot(_BEACON_SLOT).value).implementation();
        require(_isContract(newImplementation));
        address currentImplementation = StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value;
        require(newImplementation != currentImplementation);
        StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value = newImplementation;
        emit Upgraded(newImplementation);
    }

    function _isContract(address _target) private view returns (bool) {
        return _target.code.length > 0;
    }
}