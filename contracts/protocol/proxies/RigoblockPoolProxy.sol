// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import "../../utils/storageSlot/StorageSlot.sol";
import "../interfaces/IRigoblockPoolProxy.sol";

/// @title RigoblockPoolProxy - Proxy contract forwards calls to the implementation address returned by the admin.
/// @author Gabriele Rigo - <gab@rigoblock.com>
contract RigoblockPoolProxy is IRigoblockPoolProxy {
    // implementation slot is used to store implementation address, a contract which implements the pool logic.
    // Reduced deployment cost by using internal variable.
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev Sets address of implementation contract.
    /// @param _implementation Implementation address.
    /// @param _data Initialization parameters.
    constructor(address _implementation, bytes memory _data) payable {
        // store implementation address in implementation slot value
        assert(_IMPLEMENTATION_SLOT == bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1));
        StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value = _implementation;
        emit Upgraded(_implementation);

        // initialize pool
        // _data = abi.encodeWithSelector(IRigoblockPool._initializePool.selector, name, symbol, baseToken, owner)
        (, bytes memory returnData) = _implementation.delegatecall(_data);

        // we must assert initialization didn't fail, otherwise it could fail silently and still deploy the pool.
        require(returnData.length == 0, "POOL_INITIALIZATION_FAILED_ERROR");
    }

    /* solhint-disable no-complex-fallback */
    /// @dev Fallback function forwards all transactions and returns all received return data.
    fallback() external payable {
        address implementation = StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            calldatacopy(0, 0, calldatasize())
            let success := delegatecall(gas(), implementation, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if eq(success, 0) {
                revert(0, returndatasize())
            }
            return(0, returndatasize())
        }
    }
    /* solhint-enable no-complex-fallback */
}
