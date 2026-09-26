// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {ICrosschainReceiver} from "../interfaces/ICrosschainReceiver.sol";
import {IGovernanceStrategy} from "../interfaces/IGovernanceStrategy.sol";
import {IGovernanceVoting} from "../interfaces/governance/IGovernanceVoting.sol";
import {CrossChainPayload} from "../types/GovernanceTypes.sol";
import {ICoreBridge, CoreBridgeVM} from "wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol";
import {MixinStorage} from "./MixinStorage.sol";

/// @title Cross-chain governance receiver mixin.
/// @notice Gives the governance implementation the ability to execute actions decided by the
///         governance on the sender chain, delivered through Wormhole. The governance proxy is the
///         receiver hub on each chain: its deterministic address is known in advance on every chain,
///         so no dedicated receiver contract or proxy is needed.
/// @dev The Wormhole configuration (core contract and local chain id) is read from the governance
///      strategy, so receiver capability is opt-in per chain via strategy configuration and can only
///      be changed through a governance proposal. The trusted emitter is the governance proxy on the
///      sender chain (Ethereum mainnet), which is deployed at the same address on every chain and is
///      therefore a compile-time constant.
/// @dev A reverting action is skipped, not propagated: it is stored in failedActions, emitted as
///      CrossChainActionFailed, and can be re-executed via retryFailedAction once its preconditions
///      are fixed, so receiveMessage can never be bricked by target behavior. Unrecoverable states
///      (e.g. a Wormhole outage) are handled by the governance itself, which can upgrade the
///      implementation or the strategy through a local proposal. See docs/wormhole/GOVERNANCE_CROSSCHAIN.md.
abstract contract MixinCrosschain is MixinStorage, ICrosschainReceiver {
    /// @notice Maximum number of queued messages executed per receiveMessage call, bounding the gas
    ///         spent draining the queue; the remainder is processed by subsequent deliveries.
    uint256 private constant _MAX_QUEUE_DRAIN = 8;

    /// @inheritdoc ICrosschainReceiver
    function receiveMessage(bytes memory encodedMessage) external override {
        address wormholeAddress = _wormhole();
        require(wormholeAddress != address(0), GovReceiverNotConfigured());
        ICoreBridge wormhole = ICoreBridge(wormholeAddress);

        // HelloWorld step 1: verify the VAA. Forged or malformed messages return valid == false.
        (CoreBridgeVM memory verifiedVaa, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedMessage);
        require(valid, GovReceiverInvalidVaa(reason));

        // HelloWorld step 2: assert the emitter is the governance proxy on the sender chain.
        require(
            verifiedVaa.emitterChainId == _EMITTER_CHAIN_ID && verifiedVaa.emitterAddress == _EXPECTED_EMITTER,
            GovReceiverUnknownEmitter()
        );

        uint16 localChainId = _localWormholeChainId();

        // HelloWorld registerEmitter guard: a receiver must not accept messages from its own chain.
        require(_EMITTER_CHAIN_ID != localChainId, GovReceiverLocalEmitter(localChainId));

        // HelloWorld step 3: replay protection using the verified VAA hash.
        require(!_consumedVaa().consumedVaa[verifiedVaa.hash], GovReceiverAlreadyConsumed(verifiedVaa.hash));

        CrossChainPayload memory payload = abi.decode(verifiedVaa.payload, (CrossChainPayload));

        // Prevent the same VAA from being executed on the wrong chain.
        require(
            payload.targetWormholeChainId == localChainId,
            GovReceiverWrongChain(payload.targetWormholeChainId, localChainId)
        );

        // Mark the VAA consumed only after emitter and target-chain checks pass.
        // This prevents a VAA intended for a different chain from being burned here.
        _consumedVaa().consumedVaa[verifiedVaa.hash] = true;

        // Ordered execution uses Wormhole's per-emitter sequence number, starting at 0.
        uint64 sequence = verifiedVaa.sequence;
        uint64 expected = _crosschainSequence().value;
        require(sequence >= expected, GovReceiverSequenceTooOld(sequence, expected));

        if (sequence > expected) {
            _queuedPayload().queuedPayload[sequence] = abi.encode(payload.action);
        } else {
            _executeAction(sequence, payload.action);
            expected = sequence + 1;
        }

        // always attempt a drain, so a delivery that was queued still processes ready predecessors
        expected = _drainQueue(expected);
        _crosschainSequence().value = expected;
    }

    /// @inheritdoc ICrosschainReceiver
    function retryFailedAction(uint64 sequence) external override {
        IGovernanceVoting.ProposedAction memory action = _failedAction().failedAction[sequence];
        require(action.target != address(0), GovReceiverNothingToRetry(sequence));

        // the entry is cleared before the call so a reentrant retry cannot execute the action twice
        delete _failedAction().failedAction[sequence];

        (bool success, bytes memory returndata) = action.target.call{value: action.value}(action.data);
        require(success, GovReceiverExecutionFailed(returndata));

        emit CrossChainActionExecuted(sequence, keccak256(abi.encode(action)));
    }

    /// @inheritdoc ICrosschainReceiver
    function expectedSequence() external view override returns (uint64) {
        return _crosschainSequence().value;
    }

    /// @inheritdoc ICrosschainReceiver
    function consumed(bytes32 vaaHash) external view override returns (bool) {
        return _consumedVaa().consumedVaa[vaaHash];
    }

    /// @inheritdoc ICrosschainReceiver
    function queuedPayloads(uint64 sequence) external view override returns (bytes memory) {
        return _queuedPayload().queuedPayload[sequence];
    }

    /// @inheritdoc ICrosschainReceiver
    function failedActions(uint64 sequence) external view override returns (IGovernanceVoting.ProposedAction memory) {
        return _failedAction().failedAction[sequence];
    }

    /// @dev Executes a single action without propagating target reverts, deferring failures.
    function _executeAction(uint64 sequence, IGovernanceVoting.ProposedAction memory action) private {
        (bool success, bytes memory returndata) = action.target.call{value: action.value}(action.data);

        if (success) {
            emit CrossChainActionExecuted(sequence, keccak256(abi.encode(action)));
        } else {
            _failedAction().failedAction[sequence] = action;
            emit CrossChainActionFailed(sequence, keccak256(abi.encode(action)), returndata);
        }
    }

    /// @dev Executes ready queued messages in order, at most _MAX_QUEUE_DRAIN per call, and returns
    ///      the updated expected sequence.
    function _drainQueue(uint64 expected) private returns (uint64) {
        uint256 drained;

        while (drained < _MAX_QUEUE_DRAIN) {
            bytes memory encodedAction = _queuedPayload().queuedPayload[expected];
            if (encodedAction.length == 0) break;

            delete _queuedPayload().queuedPayload[expected];
            IGovernanceVoting.ProposedAction memory action = abi.decode(
                encodedAction,
                (IGovernanceVoting.ProposedAction)
            );
            _executeAction(expected, action);

            unchecked {
                expected++;
                drained++;
            }
        }

        return expected;
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
