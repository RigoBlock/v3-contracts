// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {IRigoblockGovernance} from "../IRigoblockGovernance.sol";

/// @notice Constants are copied in the bytecode and not assigned a storage slot, can safely be added to this contract.
abstract contract MixinConstants is IRigoblockGovernance {
    /// @notice Contract version
    string internal constant VERSION = "1.1.0";

    /// @notice Maximum operations per proposal
    uint256 internal constant PROPOSAL_MAX_OPERATIONS = 10;

    /// @notice The EIP-712 typehash for the contract's domain
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @notice The EIP-712 typehash for the vote struct
    bytes32 internal constant VOTE_TYPEHASH = keccak256("Vote(uint256 proposalId,uint8 voteType)");

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

    /// @notice Wormhole-formatted address of the trusted sender-chain governance proxy. The governance
    ///         proxy is deterministically deployed at the same address on every chain, so the expected
    ///         emitter is a constant. See docs/wormhole/GOVERNANCE_CROSSCHAIN.md.
    bytes32 internal constant _EXPECTED_EMITTER = bytes32(uint256(uint160(0x5F8607739c2D2d0b57a4292868C368AB1809767a)));

    /// @notice Wormhole chain id of the sender chain (Ethereum mainnet).
    uint16 internal constant _EMITTER_CHAIN_ID = 2;

    bytes32 internal constant _CROSSCHAIN_SEQUENCE_SLOT =
        0xac0ac78c54bb73764538302bc1bda8524f435b774942256fff0e0adfcc8e9619;

    bytes32 internal constant _CROSSCHAIN_CONSUMED_SLOT =
        0x3bd8e8e33c91da57468c9ee1cbb66af5a180d31f2aaec4f722fa2a662d16c8ec;

    bytes32 internal constant _CROSSCHAIN_QUEUE_SLOT =
        0x279f36212bfd68d35cea78a95badb30afe907cfedc4501913ca1cac929f2b01f;

    bytes32 internal constant _CROSSCHAIN_FAILED_SLOT =
        0x9b3acb084638d07b9d567b826ea38a33a3bd320a8ce55638f5937893df56ff78;
}
