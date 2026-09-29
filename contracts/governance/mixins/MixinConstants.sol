// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {IRigoblockGovernance} from "../IRigoblockGovernance.sol";

/// @notice Constants are copied in the bytecode and not assigned a storage slot, can safely be added to this contract.
abstract contract MixinConstants is IRigoblockGovernance {
    /// @notice Contract version
    string internal constant VERSION = "1.3.0";

    /// @notice Maximum operations per proposal
    uint256 internal constant PROPOSAL_MAX_OPERATIONS = 10;

    /// @notice Fixed EIP-712 domain name. OZ's EIP712 binds name and version as immutables at
    ///         construction, so the signing domain cannot use the per-governance storage name.
    string internal constant _EIP712_NAME = "Rigoblock Governance";

    bytes32 internal constant _GOVERNANCE_PARAMS_SLOT =
        0x0116feaee435dceaf94f40403a5223724fba6d709cb4ce4aea5becab48feb141;

    // implementation slot is same as declared in proxy
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    bytes32 internal constant _NAME_SLOT = 0x553222b140782d4f4112160b374e6b1dc38e2837c7dcbf3ef473031724ed3bd4;

    bytes32 internal constant _PROPOSAL_SLOT = 0x52dbe777b6bf9bbaf43befe2c8e8af61027e6a0a8901def318a34b207514b5bc;

    bytes32 internal constant _PROPOSAL_COUNT_SLOT = 0x7d19d505a441201fb38442238c5f65c45e6231c74b35aed1c92ad842019eab9f;

    bytes32 internal constant _PROPOSAL_QUORUM_SLOT =
        0xf4c156034b6fb4a58e020267d829cfaef00618984d103ed2c234f43e7575a62e;

    bytes32 internal constant _PROPOSED_ACTION_SLOT =
        0xe4ff3d203d0a873fb9ffd3a1bbd07943574a73114c5affe6aa0217c743adeb06;

    bytes32 internal constant _RECEIPT_SLOT = 0x5a7421539532aa5504e4251551519aa0a06f7c2a3b40bbade5235843e09ad5fe;

    /// @notice Wormhole chain id of the sender chain (Ethereum mainnet).
    uint16 internal constant _EMITTER_CHAIN_ID = 2;

    /// @notice Maximum age of a delivered message; older VAAs revert and can be skipped
    ///         by delivering any later sequence.
    uint256 internal constant _MESSAGE_TIMEOUT = 2 days;

    /// @notice Minimum Wormhole sequence number accepted by the cross-chain receiver. The
    ///         monotonic sequence doubles as replay protection: executed sequences can never
    ///         be re-executed, and gaps are allowed so a failed message never clogs the pipeline.
    bytes32 internal constant _CROSSCHAIN_SEQUENCE_SLOT =
        0xac0ac78c54bb73764538302bc1bda8524f435b774942256fff0e0adfcc8e9619;

    bytes32 internal constant _PROPOSAL_META_SLOT = 0x58222ce86aa7f6a1af2e7980a00d98a125b9758d945ecd9df9aabbdab887f816;

    /// @notice Maps the OpenZeppelin proposal hash to the Rigoblock sequential proposal id, so
    ///         the OZ execute(targets, values, calldatas, descriptionHash) flow resolves to the
    ///         stored proposal.
    bytes32 internal constant _OZ_PROPOSAL_HASH_SLOT =
        0x6abe3cd9b47f70564dddb4a5361bb8553e8f9b2cf9a797f1f7cb404dd33df356;
}
