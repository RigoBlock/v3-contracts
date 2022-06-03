// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

library StorageSlot {
    struct AddressSlot {
        address value;
    }

    function getAddressSlot(bytes32 slot) internal pure returns (AddressSlot storage r) {
        assembly {
            r.slot := slot
        }
    }
}

// Factory can be beacon, owned by the governance
interface IBeacon {
    function implementation() external view returns (address);
}

/// @title IRigoblockPoolProxy - Helper interface of the proxy to access admin slot
/// @author Gabriele Rigo - <gab@rigoblock.com>
interface IRigoblockPool {

    function _initializePool(
        string memory _dragoName,
        string memory _dragoSymbol,
        uint256 _dragoId,
        address _owner,
        address _authority
    ) external;
    function _getBeacon() external view returns (address);
}

/// @title RigoblockPoolProxy - Proxy contract forwards calls to the implementation address returned by the admin.
/// @author Gabriele Rigo - <gab@rigoblock.com>
contract RigoblockPoolProxy {
    // beacon slot is used to store beacon address, a contract that returns the address of the implementation contract.
    // Reduced deployment cost by using internal variable.
    bytes32 internal constant _BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    /// @dev Sets address of beacon contract.
    /// @param _beacon Beacon address.
    /// @param _data Initialization parameters.
    constructor(address _beacon, bytes memory _data) { // TODO: check if constructor should be payable
        assert(_BEACON_SLOT == bytes32(uint256(keccak256('eip1967.proxy.beacon')) - 1));
        StorageSlot.getAddressSlot(_BEACON_SLOT).value = _beacon;
        // we pass _data as abi.encodeWithSelector(RigoblockPool.initiatePool.selector, (name, symbol, id, owner, authority))
        (bool success, ) = address(IRigoblockPool(
            IBeacon(_beacon).implementation()
        )).delegatecall(_data);

        if (success == false) {
            revert("POOL_INITIALIZATION_FAILED_ERROR");
        }
    }

    /// @dev Fallback function forwards all transactions and returns all received return data.
    fallback() external payable {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let _beaconSlot := sload(0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50)
            let _beacon := mload(_beaconSlot)
            // 0x2bad8ba0 == keccak("_getBeacon()"). The value is right padded to 32-bytes with 0s
            if eq(calldataload(0), 0x2bad8ba000000000000000000000000000000000000000000000000000000000) {
                mstore(0, _beacon)
                return(0, 0x20)
            }
            // we must find the implementation address
            let x := mload(0x40)
            // 0x5c60da1b == keccak("implementation()")
            mstore(x, 0x5c60da1b)
            let _implementation := call(
                5000,   // 5k gas
                _beacon, // destination address
                0,      // 0 value
                x,      // inputs are stored at location x
                0x04,   // inputs are 4 bytes long (signature)
                x,      // store output over input (saves space)
                0x20)   // outputs are 32 bytes long
            calldatacopy(0, 0, calldatasize())
            let success := delegatecall(gas(), _implementation, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if eq(success, 0) {
                revert(0, returndatasize())
            }
            return(0, returndatasize())
        }
    }

    // TODO: following function is commented as we are trying to save space, but must check that applications
    // recognize EIP1967 proxy standard
    /*function _getBeacon() internal view returns (address) {
        return StorageSlot.getAddressSlot(_BEACON_SLOT).value;
    }*/
}