// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {CrosschainReceiver} from "../crosschain/CrosschainReceiver.sol";

/// @title CrosschainReceiverProxy - ERC-1967 proxy for the cross-chain governance receiver.
/// @notice Holds the receiver implementation pointer and a local owner. The owner is a
///         Rigoblock-controlled wallet on this chain: it can upgrade the receiver logic,
///         covering Wormhole liveness outages and receiver states that cannot otherwise
///         be recovered. See docs/wormhole/GOVERNANCE_CROSSCHAIN.md.
contract CrosschainReceiverProxy {
    /// @notice Emitted when the implementation is written to proxy storage.
    /// @param newImplementation Address of the new implementation.
    event Upgraded(address indexed newImplementation);

    // stores the receiver implementation address
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // stores the owner address allowed to upgrade the implementation
    bytes32 internal constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    /// @notice Thrown when the caller is not the owner.
    error ReceiverProxyNotOwner(address caller);

    /// @notice Thrown when an implementation or owner address is invalid.
    error ReceiverProxyInvalidAddress();

    /// @param implementation Address of the initial CrosschainReceiver implementation.
    /// @param owner Address of the recovery wallet allowed to upgrade the implementation.
    constructor(address implementation, address owner) {
        assert(_IMPLEMENTATION_SLOT == bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1));
        assert(_ADMIN_SLOT == bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1));
        require(implementation.code.length != 0 && owner != address(0), ReceiverProxyInvalidAddress());

        _getImplementation().value = implementation;
        _getOwner().value = owner;
        emit Upgraded(implementation);

        // initialize receiver state in the proxy context
        (, bytes memory returnData) = implementation.delegatecall(abi.encodeCall(CrosschainReceiver.initialize, ()));
        assert(returnData.length == 0);
    }

    /// @notice Upgrades the receiver implementation, optionally running an initializer.
    /// @dev Only callable by the owner recovery wallet.
    /// @param newImplementation Address of the new implementation.
    /// @param data Optional initializer calldata executed via delegatecall on the new implementation.
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable {
        require(msg.sender == _getOwner().value, ReceiverProxyNotOwner(msg.sender));
        require(newImplementation.code.length != 0, ReceiverProxyInvalidAddress());

        _getImplementation().value = newImplementation;
        emit Upgraded(newImplementation);

        if (data.length != 0) {
            (bool success, bytes memory returndata) = newImplementation.delegatecall(data);
            if (!success) {
                // forwards the original revert payload, preserving custom errors
                // solhint-disable-next-line no-inline-assembly
                assembly {
                    revert(add(returndata, 0x20), mload(returndata))
                }
            }
        }
    }

    /* solhint-disable no-complex-fallback */
    /// @notice Fallback function forwards all transactions and returns all received return data.
    fallback() external payable {
        address implementation = _getImplementation().value;
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

    /// @notice Allows this contract to receive ether for actions with value.
    receive() external payable {}

    /// @notice Implementation slot is accessed directly.
    /// @return s Storage slot of the receiver implementation.
    function _getImplementation() private pure returns (AddressSlot storage s) {
        assembly {
            s.slot := _IMPLEMENTATION_SLOT
        }
    }

    /// @notice Owner slot is accessed directly.
    /// @return s Storage slot of the owner.
    function _getOwner() private pure returns (AddressSlot storage s) {
        assembly {
            s.slot := _ADMIN_SLOT
        }
    }

    struct AddressSlot {
        address value;
    }
}
