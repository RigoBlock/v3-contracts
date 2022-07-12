// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import "../../utils/storageSlot/StorageSlot.sol";
import { IRigoblockPoolProxyFactory as Beacon } from "../interfaces/IRigoblockPoolProxyFactory.sol";

/// @title RigoblockPoolProxy - Proxy contract forwards calls to the implementation address returned by the admin.
/// @author Gabriele Rigo - <gab@rigoblock.com>
contract RigoblockPoolProxy {
    // beacon slot is used to store beacon address, a contract that returns the address of the implementation contract.
    // Reduced deployment cost by using internal variable.
    bytes32 internal constant _BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    /// @dev Sets address of beacon contract.
    /// @param _beacon Beacon address.
    /// @param _data Initialization parameters.
    constructor(address _beacon, bytes memory _data) payable {
        // store beacon address in beacon slot value
        assert(_BEACON_SLOT == bytes32(uint256(keccak256('eip1967.proxy.beacon')) - 1));
        StorageSlot.getAddressSlot(_BEACON_SLOT).value = _beacon;

        // initialize pool
        // _data = abi.encodeWithSelector(IRigoblockPool._initializePool.selector, name, symbol, owner)
        (bool success, ) = Beacon(_beacon).implementation().delegatecall(_data);

        // should never be false as initialization parameters are checked with error returned.
        assert(success == true);
    }

    /// @dev Fallback function forwards all transactions and returns all received return data.
    fallback() external payable {
        address _implementation = Beacon(
            StorageSlot.getAddressSlot(_BEACON_SLOT).value
        ).implementation();
        // solhint-disable-next-line no-inline-assembly
        assembly {
            calldatacopy(0, 0, calldatasize())
            let success := delegatecall(gas(), _implementation, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if eq(success, 0) {
                revert(0, returndatasize())
            }
            return(0, returndatasize())
        }
    }
}
