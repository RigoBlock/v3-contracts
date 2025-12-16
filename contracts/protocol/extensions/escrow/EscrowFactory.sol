// SPDX-License-Identifier: Apache-2.0-or-later
/*

 Copyright 2025 Rigo Intl.

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

pragma solidity 0.8.28;

import {SlotDerivation} from "../../libraries/SlotDerivation.sol";
import {OpType} from "../../types/Crosschain.sol";
import {IEscrowContract} from "./IEscrowContract.sol";
import {TransferEscrow} from "./TransferEscrow.sol";

/// @title EscrowFactory - Factory for creating deterministic escrow contracts
/// @notice Creates escrow contracts using CREATE2 for deterministic addresses
/// @dev Escrow contracts are deployed per pool and operation type
library EscrowFactory {
    using SlotDerivation for bytes32;

    /// @notice Storage slot for escrow contracts mapping
    bytes32 private constant _ESCROW_CONTRACTS_SLOT = 
        0x09040af395217ff2320f5fd2feffe9cbcfd5e6f9c0234bd4ec2ab0caced5e4a5;

    /// @notice Emitted when a new escrow contract is deployed
    event EscrowDeployed(address indexed pool, OpType indexed opType, address escrowContract);

    error EscrowAlreadyExists();
    error InvalidOpType();
    error DeploymentFailed();

    /// @notice Gets the deterministic address for an escrow contract
    /// @param pool The pool address
    /// @param opType The operation type
    /// @return escrowAddress The deterministic address
    function getEscrowAddress(address pool, OpType opType) internal view returns (address escrowAddress) {
        bytes32 salt = _getSalt(pool, opType);
        bytes32 bytecodeHash = _getBytecodeHash(opType, pool);
        
        escrowAddress = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            bytecodeHash
        )))));
    }

    /// @notice Deploys an escrow contract using CREATE2
    /// @param pool The pool address
    /// @param opType The operation type
    /// @return escrowContract The deployed escrow contract address
    function deployEscrow(address pool, OpType opType) internal returns (address escrowContract) {
        // Check if escrow already exists
        escrowContract = _getStoredEscrow(pool, opType);
        if (escrowContract != address(0)) {
            revert EscrowAlreadyExists();
        }

        bytes32 salt = _getSalt(pool, opType);
        
        if (opType == OpType.Transfer || opType == OpType.Sync) {
            escrowContract = address(new TransferEscrow{salt: salt}(pool));
        } else {
            revert InvalidOpType();
        }

        require(escrowContract != address(0), DeploymentFailed());

        // Store the escrow contract address
        _setStoredEscrow(pool, opType, escrowContract);

        emit EscrowDeployed(pool, opType, escrowContract);
    }

    /// @notice Deploys escrow if needed using precomputed address for gas efficiency
    /// @param pool The pool address
    /// @param opType The operation type  
    /// @param expectedAddress The precomputed escrow address
    /// @return escrowContract The escrow contract address (existing or newly deployed)
    function deployEscrowIfNeeded(address pool, OpType opType, address expectedAddress) internal returns (address escrowContract) {
        address storedEscrow = _getStoredEscrow(pool, opType);
        
        if (storedEscrow == address(0)) {
            escrowContract = deployEscrow(pool, opType);
            require(escrowContract == expectedAddress, "Address mismatch");
        } else {
            escrowContract = storedEscrow;
        }
    }

    /// @dev Gets the salt for CREATE2 deployment
    function _getSalt(address pool, OpType opType) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(pool, uint8(opType)));
    }

    /// @dev Gets the bytecode hash for CREATE2 address calculation
    function _getBytecodeHash(OpType opType, address pool) private pure returns (bytes32) {
        // All operations use TransferEscrow now
        return keccak256(abi.encodePacked(
            type(TransferEscrow).creationCode,
            abi.encode(pool)
        ));
    }

    /// @dev Gets stored escrow contract address from storage
    function _getStoredEscrow(address pool, OpType opType) private view returns (address escrowContract) {
        bytes32 key = keccak256(abi.encodePacked(pool, uint8(opType)));
        bytes32 slot = _ESCROW_CONTRACTS_SLOT.deriveMapping(key);
        assembly {
            escrowContract := sload(slot)
        }
    }

    /// @dev Sets stored escrow contract address in storage
    function _setStoredEscrow(address pool, OpType opType, address escrowContract) private {
        bytes32 key = keccak256(abi.encodePacked(pool, uint8(opType)));
        bytes32 slot = _ESCROW_CONTRACTS_SLOT.deriveMapping(key);
        assembly {
            sstore(slot, escrowContract)
        }
    }
}