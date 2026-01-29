// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

import {SlotDerivation} from "./SlotDerivation.sol";
import {OpType} from "../types/Crosschain.sol";
import {Escrow} from "../deps/Escrow.sol";

/// @title EscrowFactory - Factory for creating deterministic escrow contracts
/// @notice Creates escrow contracts using CREATE2 for deterministic addresses
/// @dev Escrow contracts are deployed per pool and operation type
library EscrowFactory {
    using SlotDerivation for bytes32;

    /// @notice Emitted when a new escrow contract is deployed
    event EscrowDeployed(address indexed pool, OpType indexed opType, address escrowContract);
    error DeploymentFailed();

    /// @notice Gets the deterministic address for an escrow contract
    /// @param pool The pool address
    /// @param opType The operation type
    /// @return escrowAddress The deterministic address
    function getEscrowAddress(address pool, OpType opType) internal pure returns (address escrowAddress) {
        bytes32 salt = _getSalt(opType);
        bytes32 bytecodeHash = _getBytecodeHash(opType, pool);

        // Use pool as deployer address for CREATE2 calculation
        // When called via delegatecall from adapter, pool is the actual deployer
        escrowAddress = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), pool, salt, bytecodeHash)))));
    }

    /// @notice Deploys an escrow contract using CREATE2 (idempotent)
    /// @param pool The pool address
    /// @param opType The operation type
    /// @return escrowContract The deployed escrow contract address
    /// @dev MUST be called via delegatecall from pool context (address(this) == pool)
    function deployEscrow(address pool, OpType opType) internal returns (address escrowContract) {
        escrowContract = getEscrowAddress(pool, opType);

        // If escrow already deployed, return early (idempotent)
        // This avoids the massive gas cost of CREATE2 address collision failure
        if (escrowContract.code.length > 0) {
            return escrowContract;
        }

        // Deploy new escrow contract
        bytes32 salt = _getSalt(opType);
        Escrow escrow = new Escrow{salt: salt}(pool, opType);
        require(address(escrow) == escrowContract, DeploymentFailed());

        emit EscrowDeployed(pool, opType, escrowContract);
    }

    /// @dev Gets the salt for CREATE2 deployment
    function _getSalt(OpType opType) private pure returns (bytes32) {
        // Use opType to generate different escrow addresses per operation type
        return keccak256(abi.encodePacked(uint8(opType)));
    }

    /// @dev Gets the bytecode hash for CREATE2 address calculation
    function _getBytecodeHash(OpType opType, address pool) private pure returns (bytes32) {
        // Include opType in constructor params for bytecode hash
        return keccak256(abi.encodePacked(type(Escrow).creationCode, abi.encode(pool, opType)));
    }
}
