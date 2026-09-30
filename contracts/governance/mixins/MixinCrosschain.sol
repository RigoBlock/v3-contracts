// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {ICoreBridge, CoreBridgeVM} from "wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol";
import {CrossChainPayload} from "../types/GovernanceTypes.sol";
import {GovernanceActionLib} from "../libraries/GovernanceActionLib.sol";
import {IGovernanceCrosschain} from "../interfaces/governance/IGovernanceCrosschain.sol";
import {IGovernanceStrategy} from "../interfaces/IGovernanceStrategy.sol";
import {IGovernanceVoting} from "../interfaces/governance/IGovernanceVoting.sol";
import {MixinStorage} from "./MixinStorage.sol";

/// @title Cross-chain governance receiver mixin.
/// @notice Executes actions decided by the sender-chain governance and delivered through Wormhole.
abstract contract MixinCrosschain is MixinStorage {
    /// @inheritdoc IGovernanceCrosschain
    function receiveMessage(bytes memory encodedMessage) external override {
        address wormholeAddress = _wormhole();
        require(wormholeAddress != address(0), GovReceiverNotConfigured());
        ICoreBridge wormhole = ICoreBridge(wormholeAddress);

        // verify the VAA. Forged or malformed messages return valid == false.
        (CoreBridgeVM memory verifiedVaa, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedMessage);
        require(valid, GovReceiverInvalidVaa(reason));

        // the trusted emitter is the sender-chain governance proxy, deployed at the same address
        // as this receiver on every chain
        require(
            verifiedVaa.emitterChainId == _EMITTER_CHAIN_ID &&
                verifiedVaa.emitterAddress == bytes32(uint256(uint160(address(this)))),
            GovReceiverUnknownEmitter()
        );

        uint16 localChainId = _localWormholeChainId();

        // a receiver must not accept messages from its own chain
        require(_EMITTER_CHAIN_ID != localChainId, GovReceiverLocalEmitter(localChainId));

        // sequences must be strictly monotonically increasing but need not be consecutive
        // (audited Uniswap receiver model): a message that reverts on execution never
        // clogs the pipeline, as any later message still passes the check; re-delivered
        // messages are rejected by the same check
        uint64 sequence = verifiedVaa.sequence;
        uint64 minimum = _crosschainSequence().value;
        require(sequence >= minimum, GovReceiverInvalidSequence(sequence, minimum));
        _crosschainSequence().value = sequence + 1;

        require(verifiedVaa.timestamp + _MESSAGE_TIMEOUT >= block.timestamp, GovReceiverMessageExpired(sequence));

        CrossChainPayload memory payload = abi.decode(verifiedVaa.payload, (CrossChainPayload));

        // prevent the same VAA from being executed on the wrong chain
        require(
            payload.targetWormholeChainId == localChainId,
            GovReceiverWrongChain(payload.targetWormholeChainId, localChainId)
        );

        // a failing action reverts the whole message with the target's return data
        for (uint256 i = 0; i < payload.actions.length; i++) {
            GovernanceActionLib.execute(payload.actions[i]);
        }
    }

    /// @inheritdoc IGovernanceCrosschain
    function nextMinimumSequence() external view override returns (uint64) {
        return _crosschainSequence().value;
    }

    /// @dev Returns the Wormhole core contract from the strategy, or the zero address when the
    ///      strategy does not enable cross-chain governance.
    function _wormhole() private view returns (address) {
        address strategy = _governanceParameters().strategy;
        if (strategy == address(0)) {
            return address(0);
        }
        return IGovernanceStrategy(strategy).wormhole();
    }

    /// @dev Returns the Wormhole chain id of the current chain from the strategy.
    function _localWormholeChainId() private view returns (uint16) {
        return IGovernanceStrategy(_governanceParameters().strategy).wormholeChainId();
    }
}
