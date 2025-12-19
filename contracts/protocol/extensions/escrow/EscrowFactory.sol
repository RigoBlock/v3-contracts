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
import {TransferEscrow} from "./TransferEscrow.sol";

/// @title EscrowFactory - Factory for creating deterministic escrow contracts
/// @notice Creates escrow contracts using CREATE2 for deterministic addresses
/// @dev Escrow contracts are deployed per pool and operation type
library EscrowFactory {
    using SlotDerivation for bytes32;

    /// @notice Emitted when a new escrow contract is deployed
    event EscrowDeployed(address indexed pool, OpType indexed opType, address escrowContract);

    error InvalidOpType();
    error DeploymentFailed();

    /// @notice Gets the deterministic address for an escrow contract
    /// @param pool The pool address
    /// @param opType The operation type
    /// @return escrowAddress The deterministic address
    function getEscrowAddress(address pool, OpType opType) internal view returns (address escrowAddress) {
        bytes32 salt = _getSalt(opType);
        bytes32 bytecodeHash = _getBytecodeHash(opType, pool);
        
        escrowAddress = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            bytecodeHash
        )))));
    }

    /// @notice Deploys an escrow contract using CREATE2 (idempotent)
    /// @param pool The pool address
    /// @param opType The operation type
    /// @return escrowContract The deployed escrow contract address
    function deployEscrow(address pool, OpType opType) internal returns (address escrowContract) {
        bytes32 salt = _getSalt(opType);
        
        // Try to deploy - if already exists, CREATE2 will succeed and return existing address
        try new TransferEscrow{salt: salt}(pool) returns (TransferEscrow escrow) {
            escrowContract = address(escrow);
            emit EscrowDeployed(pool, opType, escrowContract);
        } catch {
            // Escrow already exists at this address - compute and return it
            escrowContract = getEscrowAddress(pool, opType);
        }
        
        require(escrowContract != address(0), DeploymentFailed());
    }

    /// @notice Deploys escrow if needed (idempotent)
    /// @param pool The pool address
    /// @param opType The operation type
    /// @return escrowContract The escrow contract address (existing or newly deployed)
    function deployEscrowIfNeeded(address pool, OpType opType) internal returns (address escrowContract) {
        return deployEscrow(pool, opType);
    }

    /// @dev Gets the salt for CREATE2 deployment
    function _getSalt(OpType opType) private pure returns (bytes32) {
        // Use opType to generate different escrow addresses per operation type
        return keccak256(abi.encodePacked(uint8(opType)));
    }

    /// @dev Gets the bytecode hash for CREATE2 address calculation
    function _getBytecodeHash(OpType /* opType */, address pool) private pure returns (bytes32) {
        // All operations use TransferEscrow for now
        return keccak256(abi.encodePacked(
            type(TransferEscrow).creationCode,
            abi.encode(pool)
        ));
    }

}