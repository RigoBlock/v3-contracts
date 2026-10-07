// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {GovernanceMode} from "../../contracts/governance/strategies/RigoblockGovernanceStrategy.sol";
import {CrossChainPayload} from "../../contracts/governance/types/GovernanceTypes.sol";
import {IGovernanceCrosschain} from "../../contracts/governance/interfaces/governance/IGovernanceCrosschain.sol";
import {IGovernanceVoting} from "../../contracts/governance/interfaces/governance/IGovernanceVoting.sol";
import {MixinVoting} from "../../contracts/governance/mixins/MixinVoting.sol";
import {RigoblockGovernanceStrategy} from "../../contracts/governance/strategies/RigoblockGovernanceStrategy.sol";
import {Counter, CrosschainHarness} from "./Governance.Crosschain.t.sol";

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ICoreBridge, CoreBridgeVM, GuardianSignature} from "wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol";
import {CHAIN_ID_ETHEREUM, CHAIN_ID_HYPER_EVM} from "wormhole-solidity-sdk/src/constants/Chains.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {IStructs} from "../../contracts/staking/interfaces/IStructs.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";
import {IStorage} from "../../contracts/staking/interfaces/IStorage.sol";

/// @title Fork test: multiple Wormhole messages from a single proposal, delivered in order.
/// @notice Runs against the real Wormhole core contract on a mainnet fork: real publishMessage,
///     real per-emitter sequence assignment, real messageFee. Only parseAndVerifyVM — which
///     requires live guardian signatures — is mocked at the receiver boundary. One harness
///     contract plays both roles: the sender phase uses a strategy whose local Wormhole id is
///     Ethereum's, then the strategy is swapped and the harness receives the messages it
///     published itself (mirroring production, where the same deterministic proxy address
///     carries a per-chain strategy).
contract GovernanceCrosschainForkTest is Test {
    uint16 internal constant EMITTER_CHAIN = CHAIN_ID_ETHEREUM;
    uint16 internal constant TARGET_CHAIN = CHAIN_ID_HYPER_EVM;
    address internal constant STAKING = address(0x1111);
    address internal constant WORMHOLE = Constants.WORMHOLE_ETHEREUM;
    uint256 internal constant DELEGATED_BALANCE = 1_000_000e18;

    CrosschainHarness internal governance;
    Counter internal counter;
    address internal whale = makeAddr("whale");
    address internal ethRecipient = makeAddr("ethRecipient");

    function setUp() public {
        vm.createSelectFork("mainnet", Constants.MAINNET_BLOCK);

        // sender role: the strategy's local Wormhole id is Ethereum's
        governance = new CrosschainHarness();
        governance.setStrategy(
            address(new RigoblockGovernanceStrategy(STAKING, WORMHOLE, EMITTER_CHAIN, GovernanceMode.Sender))
        );
        governance.setParams(1, 1);

        counter = new Counter();

        // local staking voting mocks used by the harness's own governance
        IStructs.StoredBalance memory balance = IStructs.StoredBalance({
            currentEpoch: 1,
            currentEpochBalance: uint96(DELEGATED_BALANCE),
            nextEpochBalance: uint96(DELEGATED_BALANCE)
        });
        vm.mockCall(
            STAKING,
            abi.encodeWithSelector(IStaking.getOwnerStakeByStatus.selector, whale, IStructs.StakeStatus.DELEGATED),
            abi.encode(balance)
        );
        vm.mockCall(
            STAKING,
            abi.encodeWithSelector(IStaking.getGlobalStakeByStatus.selector, IStructs.StakeStatus.DELEGATED),
            abi.encode(balance)
        );
        vm.mockCall(
            STAKING,
            abi.encodeWithSelector(IStaking.getCurrentEpochEarliestEndTimeInSeconds.selector),
            abi.encode(block.timestamp - 1)
        );
        vm.mockCall(STAKING, abi.encodeWithSelector(IStorage.epochDurationInSeconds.selector), abi.encode(7 days));
    }

    function _wormholeAction(
        IGovernanceVoting.ProposedAction[] memory innerActions
    ) private pure returns (IGovernanceVoting.ProposedAction memory) {
        return
            IGovernanceVoting.ProposedAction({
                target: WORMHOLE,
                data: abi.encodeWithSelector(
                    ICoreBridge.publishMessage.selector,
                    uint32(0),
                    abi.encode(
                        CrossChainPayload({targetWormholeChainId: TARGET_CHAIN, proposalId: 1, actions: innerActions})
                    ),
                    uint8(200)
                ),
                value: 0
            });
    }

    function _buildVaa(bytes memory payload, uint64 sequence) private view returns (CoreBridgeVM memory) {
        return
            CoreBridgeVM({
                version: 1,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: EMITTER_CHAIN,
                emitterAddress: bytes32(uint256(uint160(address(governance)))),
                sequence: sequence,
                consistencyLevel: 200,
                payload: payload,
                guardianSetIndex: 0,
                signatures: new GuardianSignature[](0),
                hash: keccak256(abi.encode(payload, sequence))
            });
    }

    /// @notice Reads the payloads published by the real Wormhole core contract during execute,
    ///     asserting they carry consecutive sequences starting at the emitter's next sequence.
    function _publishedPayloads(uint64 expectedFirstSequence) private returns (bytes[] memory) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes[] memory payloads = new bytes[](2);
        uint256 count;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(WORMHOLE) && logs[i].topics[0] == ICoreBridge.LogMessagePublished.selector) {
                (uint64 sequence, , bytes memory payload, ) = abi.decode(logs[i].data, (uint64, uint32, bytes, uint8));
                assertEq(sequence, expectedFirstSequence + count);
                payloads[count] = payload;
                count++;
            }
        }
        assertEq(count, 2);
        return payloads;
    }

    function testFork_MultipleMessagesFromSingleProposal_ExecuteInOrderOnReceiver() public {
        // one proposal publishing two batched messages: message 1 carries two actions
        // (the typical coupled upgrade), message 2 a single action
        IGovernanceVoting.ProposedAction[] memory batchOne = new IGovernanceVoting.ProposedAction[](2);
        batchOne[0] = IGovernanceVoting.ProposedAction({
            target: address(counter),
            data: abi.encodeCall(Counter.increment, ()),
            value: 0
        });
        batchOne[1] = IGovernanceVoting.ProposedAction({
            target: address(counter),
            data: abi.encodeCall(Counter.setValue, (42)),
            value: 0
        });
        IGovernanceVoting.ProposedAction[] memory batchTwo = new IGovernanceVoting.ProposedAction[](1);
        batchTwo[0] = IGovernanceVoting.ProposedAction({
            target: address(counter),
            data: abi.encodeCall(Counter.increment, ()),
            value: 0
        });

        IGovernanceVoting.ProposedAction[] memory actions = new IGovernanceVoting.ProposedAction[](3);
        actions[0] = _wormholeAction(batchOne);
        actions[1] = _wormholeAction(batchTwo);
        actions[2] = IGovernanceVoting.ProposedAction({target: ethRecipient, data: "", value: 1 wei});

        vm.prank(whale);
        uint256 proposalId = governance.propose(actions, "crosschain batch");
        vm.warp(block.timestamp + 2);
        vm.prank(whale);
        governance.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));
        vm.warp(block.timestamp + 1);

        // the executor must attach the summed action values: the wormhole fee (zero on mainnet
        // at the fork block) plus the 1 wei transfer
        vm.expectRevert(
            abi.encodeWithSelector(MixinVoting.GovExecutionValueMismatch.selector, uint256(1 wei), uint256(0))
        );
        governance.execute{value: 0}(proposalId);

        uint64 firstSequence = ICoreBridge(WORMHOLE).nextSequence(address(governance));
        vm.recordLogs();
        governance.execute{value: 1 wei}(proposalId);

        // the real Wormhole core assigned consecutive sequences to the two publishMessage calls
        bytes[] memory payloads = _publishedPayloads(firstSequence);

        // swap to the receiver role: the strategy's local Wormhole id is now the target chain.
        // The receiver path only reads wormhole()/wormholeChainId(), so any non-receiver mode works.
        governance.setStrategy(
            address(new RigoblockGovernanceStrategy(STAKING, WORMHOLE, TARGET_CHAIN, GovernanceMode.Sender))
        );

        // delivering the two VAAs in order executes both batches in order
        vm.mockCall(
            WORMHOLE,
            abi.encodeWithSelector(ICoreBridge.parseAndVerifyVM.selector),
            abi.encode(_buildVaa(payloads[0], firstSequence), true, "")
        );
        governance.receiveMessage("");
        assertEq(counter.value(), 42);
        assertEq(governance.nextMinimumSequence(), firstSequence + 1);

        vm.mockCall(
            WORMHOLE,
            abi.encodeWithSelector(ICoreBridge.parseAndVerifyVM.selector),
            abi.encode(_buildVaa(payloads[1], firstSequence + 1), true, "")
        );
        governance.receiveMessage("");
        assertEq(counter.value(), 43);
        assertEq(governance.nextMinimumSequence(), firstSequence + 2);
        assertEq(ethRecipient.balance, 1 wei);

        // re-delivering an already-executed VAA is rejected by the monotonic sequence check
        vm.mockCall(
            WORMHOLE,
            abi.encodeWithSelector(ICoreBridge.parseAndVerifyVM.selector),
            abi.encode(_buildVaa(payloads[0], firstSequence), true, "")
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernanceCrosschain.GovReceiverInvalidSequence.selector,
                firstSequence,
                firstSequence + 2
            )
        );
        governance.receiveMessage("");
        assertEq(counter.value(), 43);
    }
}
