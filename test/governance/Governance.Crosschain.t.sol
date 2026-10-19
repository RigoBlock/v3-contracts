// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {WormholeReceiverStrategy} from "../../contracts/governance/strategies/WormholeReceiverStrategy.sol";
import {MixinVoting} from "../../contracts/governance/mixins/MixinVoting.sol";
import {CrossChainPayload, ProposalStatus, ProposedAction} from "../../contracts/governance/types/GovernanceTypes.sol";
import {IGovernanceCrosschain} from "../../contracts/governance/interfaces/governance/IGovernanceCrosschain.sol";
import {IGovernanceState} from "../../contracts/governance/interfaces/governance/IGovernanceState.sol";
import {IGovernanceUpgrade} from "../../contracts/governance/interfaces/governance/IGovernanceUpgrade.sol";
import {IGovernanceVoting} from "../../contracts/governance/interfaces/governance/IGovernanceVoting.sol";
import {RigoblockGovernance} from "../../contracts/governance/RigoblockGovernance.sol";
import {RigoblockGovernanceStrategy} from "../../contracts/governance/strategies/RigoblockGovernanceStrategy.sol";
import {TimeType} from "../../contracts/governance/types/TimeType.sol";
import {ReentrancyGuardTransient} from "../../contracts/protocol/libraries/ReentrancyGuardTransient.sol";

import {Test} from "forge-std/Test.sol";
import {ICoreBridge, CoreBridgeVM, GuardianSignature} from "wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol";
import {CHAIN_ID_ETHEREUM, CHAIN_ID_HYPER_EVM} from "wormhole-solidity-sdk/src/constants/Chains.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {IStructs} from "../../contracts/staking/interfaces/IStructs.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";
import {IStorage} from "../../contracts/staking/interfaces/IStorage.sol";
import {IERC20} from "../../contracts/tokens/ERC20/IERC20.sol";

contract Counter {
    uint256 public value;

    function increment() external {
        value++;
    }

    function setValue(uint256 newValue) external {
        value = newValue;
    }
}

contract FlakyTarget {
    error TargetRevert();

    bool public shouldRevert;

    function setShouldRevert(bool newShouldRevert) external {
        shouldRevert = newShouldRevert;
    }

    function run() external view {
        require(!shouldRevert, TargetRevert());
    }
}

/// @title Governance crosschain harness
/// @notice Deploys the governance implementation standalone and exposes strategy storage,
///     mirroring the MigrationHarness pattern used by GovernanceMigration.t.sol.
contract CrosschainHarness is RigoblockGovernance {
    // 2 is the Wormhole chain id of Ethereum, the governance hub
    constructor() RigoblockGovernance(2) {
        // governance actions that reach updateThresholds validate the canonical name via the
        // strategy; the harness skips initialization, so the name is set here
        _name().value = "Rigoblock Governance";
    }

    function setStrategy(address strategy_) external {
        _paramsWrapper().governanceParameters.strategy = strategy_;
    }

    function setParams(uint256 proposalThreshold_, uint256 quorumThreshold_) external {
        _paramsWrapper().governanceParameters.proposalThreshold = proposalThreshold_;
        _paramsWrapper().governanceParameters.quorumThreshold = quorumThreshold_;
    }

    function setTimeType(TimeType timeType_) external {
        _paramsWrapper().governanceParameters.timeType = timeType_;
    }

    /// @dev The canonical proxy is produced by etching this contract's code over its address,
    ///     which copies no storage: write the name validateParams asserts explicitly.
    function setName() external {
        _name().value = "Rigoblock Governance";
    }

    function implementation() external view returns (address) {
        return _implementation().value;
    }
}

/// @dev Strategy exposing a zero wormhole address, simulating a chain where cross-chain
///      governance is not configured.
contract ZeroWormholeStrategy {
    function wormhole() external pure returns (address) {
        return address(0);
    }
}

/// @title Tests for the cross-chain receiver implemented inside the governance.
/// @notice Wormhole's parseAndVerifyVM is mocked: these tests exercise the governance's own
///     state machine (ordering, replay protection, gaps, expiry), not VAA cryptography.
contract GovernanceCrosschainTest is Test {
    uint16 internal constant EMITTER_CHAIN = CHAIN_ID_ETHEREUM;
    uint16 internal constant TARGET_CHAIN = CHAIN_ID_HYPER_EVM;
    address internal constant STAKING = address(0x1111);
    address internal constant GRG = address(0x2222);
    address internal wormhole;
    uint256 internal constant DELEGATED_BALANCE = 1_000_000e18;

    CrosschainHarness internal governance;
    RigoblockGovernanceStrategy internal strategy;
    Counter internal counter;
    address internal whale = makeAddr("whale");

    function setUp() public {
        wormhole = makeAddr("wormhole");
        // enough code for the constructor's code.length check; the local Wormhole chain id is
        // read from the core contract, which is not deployed in these tests
        vm.etch(wormhole, hex"00");
        vm.mockCall(wormhole, abi.encodeWithSelector(ICoreBridge.chainId.selector), abi.encode(TARGET_CHAIN));
        strategy = new RigoblockGovernanceStrategy(STAKING, wormhole);
        governance = new CrosschainHarness();
        governance.setStrategy(address(strategy));
        counter = new Counter();
    }

    function _encodePayload(ProposedAction memory action) private pure returns (bytes memory) {
        ProposedAction[] memory actions = new ProposedAction[](1);
        actions[0] = action;
        return _encodePayload(actions, 1);
    }

    function _encodePayload(ProposedAction[] memory actions, uint256 proposalId) private pure returns (bytes memory) {
        return
            abi.encode(
                CrossChainPayload({targetWormholeChainId: TARGET_CHAIN, proposalId: proposalId, actions: actions})
            );
    }

    function _buildVaa(bytes memory payload, uint64 sequence) private view returns (CoreBridgeVM memory) {
        return _buildVaa(payload, sequence, uint32(block.timestamp));
    }

    function _buildVaa(
        bytes memory payload,
        uint64 sequence,
        uint32 timestamp
    ) private view returns (CoreBridgeVM memory) {
        return
            CoreBridgeVM({
                version: 1,
                timestamp: timestamp,
                nonce: 0,
                emitterChainId: EMITTER_CHAIN,
                emitterAddress: bytes32(uint256(uint160(address(governance)))),
                sequence: sequence,
                consistencyLevel: 202,
                payload: payload,
                guardianSetIndex: 0,
                signatures: new GuardianSignature[](0),
                hash: keccak256(abi.encode(payload, sequence))
            });
    }

    function _mockParseAndVerify(CoreBridgeVM memory vaa) private {
        vm.mockCall(wormhole, abi.encodeWithSelector(ICoreBridge.parseAndVerifyVM.selector), abi.encode(vaa, true, ""));
    }

    function _buildIncrementAction() private view returns (ProposedAction memory) {
        return ProposedAction({target: address(counter), data: abi.encodeCall(Counter.increment, ()), value: 0});
    }

    function _wrap(ProposedAction memory action) private pure returns (ProposedAction[] memory) {
        ProposedAction[] memory actions = new ProposedAction[](1);
        actions[0] = action;
        return actions;
    }

    function test_ReceiveMessage_HappyPath() public {
        ProposedAction memory action = _buildIncrementAction();
        bytes memory payload = _encodePayload(action);
        _mockParseAndVerify(_buildVaa(payload, 0));

        governance.receiveMessage("");
        assertEq(counter.value(), 1);
        assertEq(governance.nextMinimumSequence(), 1);
    }

    /// @notice A governance whose strategy is the zero address cannot receive: the strategy is
    ///     asserted non-null at initialization, so this state is only reachable through direct
    ///     storage manipulation.
    function test_ReceiveMessage_WithoutStrategy_Reverts() public {
        CrosschainHarness unconfigured = new CrosschainHarness();

        ProposedAction memory action = _buildIncrementAction();
        _mockParseAndVerify(_buildVaa(_encodePayload(action), 0));

        vm.expectRevert();
        unconfigured.receiveMessage("");
    }

    /// @notice A strategy that exposes a zero wormhole address (a chain without cross-chain
    ///     governance configured) cannot receive: the uncallable core bridge reverts the
    ///     verification call. Configuration is enforced by both strategies' constructors.
    function test_ReceiveMessage_WormholeDisabledInStrategy_Reverts() public {
        CrosschainHarness otherChain = new CrosschainHarness();
        otherChain.setStrategy(address(new ZeroWormholeStrategy()));

        ProposedAction memory action = _buildIncrementAction();
        _mockParseAndVerify(_buildVaa(_encodePayload(action), 0));

        vm.expectRevert();
        otherChain.receiveMessage("");
    }

    function test_ReceiveMessage_UnknownEmitter_Reverts() public {
        ProposedAction memory action = _buildIncrementAction();
        bytes memory payload = _encodePayload(action);
        CoreBridgeVM memory vaa = _buildVaa(payload, 0);
        vaa.emitterAddress = bytes32(uint256(1));
        _mockParseAndVerify(vaa);

        vm.expectRevert(IGovernanceCrosschain.GovReceiverUnknownEmitter.selector);
        governance.receiveMessage("");
    }

    function test_ReceiveMessage_UnknownEmitterChain_Reverts() public {
        ProposedAction memory action = _buildIncrementAction();
        bytes memory payload = _encodePayload(action);
        CoreBridgeVM memory vaa = _buildVaa(payload, 0);
        vaa.emitterChainId = EMITTER_CHAIN + 1;
        _mockParseAndVerify(vaa);

        vm.expectRevert(IGovernanceCrosschain.GovReceiverUnknownEmitter.selector);
        governance.receiveMessage("");
    }

    function test_ReceiveMessage_WrongChain_Reverts() public {
        ProposedAction memory action = _buildIncrementAction();
        bytes memory payload = abi.encode(
            CrossChainPayload({targetWormholeChainId: 9999, proposalId: 1, actions: _wrap(action)})
        );
        _mockParseAndVerify(_buildVaa(payload, 0));

        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernanceCrosschain.GovReceiverWrongChain.selector,
                uint16(9999),
                uint16(TARGET_CHAIN)
            )
        );
        governance.receiveMessage("");
    }

    function test_ReceiveMessage_LocalEmitter_Reverts() public {
        // a chain whose Wormhole chain id equals the emitter's (i.e. the sender chain itself)
        vm.mockCall(wormhole, abi.encodeWithSelector(ICoreBridge.chainId.selector), abi.encode(EMITTER_CHAIN));
        governance.setStrategy(address(new RigoblockGovernanceStrategy(STAKING, wormhole)));

        ProposedAction memory action = _buildIncrementAction();
        bytes memory payload = _encodePayload(action);
        _mockParseAndVerify(_buildVaa(payload, 0));

        vm.expectRevert(abi.encodeWithSelector(IGovernanceCrosschain.GovReceiverLocalEmitter.selector, EMITTER_CHAIN));
        governance.receiveMessage("");
    }

    function test_ReceiveMessage_InvalidVaa_Reverts() public {
        vm.mockCall(
            wormhole,
            abi.encodeWithSelector(ICoreBridge.parseAndVerifyVM.selector),
            abi.encode(_buildVaa("", 0), false, "invalid signature")
        );

        vm.expectRevert(
            abi.encodeWithSelector(IGovernanceCrosschain.GovReceiverInvalidVaa.selector, "invalid signature")
        );
        governance.receiveMessage("");
    }

    function test_ReceiveMessage_MalformedPayload_Reverts() public {
        CoreBridgeVM memory vaa = _buildVaa(hex"1234", 0);
        _mockParseAndVerify(vaa);

        vm.expectRevert();
        governance.receiveMessage("");

        // the nonce did not advance, so later valid messages are not bricked
        assertEq(governance.nextMinimumSequence(), 0);
    }

    /// @notice A re-delivered VAA is rejected by the monotonic sequence check.
    function test_ReceiveMessage_ReplayedVaa_Reverts() public {
        ProposedAction memory action = _buildIncrementAction();
        bytes memory payload = _encodePayload(action);
        _mockParseAndVerify(_buildVaa(payload, 0));

        governance.receiveMessage("");
        assertEq(counter.value(), 1);

        vm.expectRevert(
            abi.encodeWithSelector(IGovernanceCrosschain.GovReceiverInvalidSequence.selector, uint64(0), uint64(1))
        );
        governance.receiveMessage("");
        assertEq(counter.value(), 1);
        assertEq(governance.nextMinimumSequence(), 1);
    }

    /// @notice An action that re-enters receiveMessage mid-execution is rejected by the
    ///     transient reentrancy guard before it can touch state, reverting the whole batch
    ///     atomically; the sequence stays unconsumed.
    function test_ReceiveMessage_Reentrancy_BumpsSequenceBeforeExecution() public {
        ReentrantRelayerTarget relayerTarget = new ReentrantRelayerTarget(address(governance));
        ProposedAction memory action = ProposedAction({
            target: address(relayerTarget),
            data: abi.encodeCall(ReentrantRelayerTarget.reenter, ("")),
            value: 0
        });
        bytes memory payload = _encodePayload(action);
        _mockParseAndVerify(_buildVaa(payload, 0));

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        governance.receiveMessage("");

        assertEq(governance.nextMinimumSequence(), 0);
    }

    /// @notice A governance-approved re-send executes as a new message: the sender chain
    ///     published the action again, so it carries a new sequence and is not a replay.
    function test_ReceiveMessage_ResentAction_ExecutesAsNewMessage() public {
        ProposedAction memory action = _buildIncrementAction();
        bytes memory payload = _encodePayload(action);

        _mockParseAndVerify(_buildVaa(payload, 0));
        governance.receiveMessage("");
        assertEq(counter.value(), 1);
        assertEq(governance.nextMinimumSequence(), 1);

        // the sender chain re-publishes the same action (new sequence, new VAA)
        _mockParseAndVerify(_buildVaa(payload, 1));
        governance.receiveMessage("");
        assertEq(counter.value(), 2);
        assertEq(governance.nextMinimumSequence(), 2);
    }

    /// @notice Sequences need not be consecutive (audited Uniswap receiver model): a message
    ///     with a higher sequence delivers even if earlier sequences never executed, and a
    ///     later message with a lower sequence is rejected.
    function test_ReceiveMessage_GapAllowed_HigherSequenceSkipsMissing() public {
        ProposedAction memory action1 = _buildIncrementAction();
        ProposedAction memory action2 = ProposedAction({
            target: address(counter),
            data: abi.encodeCall(Counter.setValue, (42)),
            value: 0
        });

        // sequence 1 delivers first: sequence 0 never executed, the gap is allowed
        _mockParseAndVerify(_buildVaa(_encodePayload(action2), 1));
        governance.receiveMessage("");
        assertEq(counter.value(), 42);
        assertEq(governance.nextMinimumSequence(), 2);

        // the stale sequence 0 message is now permanently rejected
        _mockParseAndVerify(_buildVaa(_encodePayload(action1), 0));
        vm.expectRevert(
            abi.encodeWithSelector(IGovernanceCrosschain.GovReceiverInvalidSequence.selector, uint64(0), uint64(2))
        );
        governance.receiveMessage("");
        assertEq(governance.nextMinimumSequence(), 2);
    }

    /// @notice A reverting action reverts the whole message with the target's return data and
    ///     is not consumed: the sequence does not advance, so the same VAA can be re-delivered
    ///     (e.g. after the failure condition is fixed) or skipped by a later sequence.
    function test_ReceiveMessage_ExecutionFailure_RevertsAndStaysRedeliverable() public {
        FlakyTarget flaky = new FlakyTarget();
        flaky.setShouldRevert(true);
        ProposedAction memory action = ProposedAction({
            target: address(flaky),
            data: abi.encodeCall(FlakyTarget.run, ()),
            value: 0
        });
        bytes memory payload = _encodePayload(action);
        _mockParseAndVerify(_buildVaa(payload, 0));

        vm.expectRevert(abi.encodeWithSelector(FlakyTarget.TargetRevert.selector));
        governance.receiveMessage("");

        // not consumed: same VAA re-delivers, and succeeds once the target stops reverting
        assertEq(governance.nextMinimumSequence(), 0);
        flaky.setShouldRevert(false);
        governance.receiveMessage("");
        assertEq(governance.nextMinimumSequence(), 1);
    }

    /// @notice The message after a failed one still executes: the failed sequence stays
    ///     unconsumed but never clogs the pipeline.
    function test_ReceiveMessage_FailureDoesNotBlockNextMessage() public {
        FlakyTarget flaky = new FlakyTarget();
        flaky.setShouldRevert(true);

        ProposedAction memory failingAction = ProposedAction({
            target: address(flaky),
            data: abi.encodeCall(FlakyTarget.run, ()),
            value: 0
        });
        ProposedAction memory goodAction = _buildIncrementAction();

        _mockParseAndVerify(_buildVaa(_encodePayload(failingAction), 0));
        vm.expectRevert(abi.encodeWithSelector(FlakyTarget.TargetRevert.selector));
        governance.receiveMessage("");
        assertEq(governance.nextMinimumSequence(), 0);

        _mockParseAndVerify(_buildVaa(_encodePayload(_wrap(goodAction), 2), 1));
        governance.receiveMessage("");

        assertEq(counter.value(), 1);
        assertEq(governance.nextMinimumSequence(), 2);
    }

    /// @notice Recovery from a failed action can be a re-delivery of the same VAA (it was not
    ///     consumed): a value-carrying action with an unfunded governance fails once, then
    ///     succeeds once re-delivered after funding.
    function test_ReceiveMessage_FailedAction_RecoveredByRedelivery() public {
        address recipient = address(0xBEEF);
        ProposedAction memory action = ProposedAction({target: recipient, data: "", value: 0.25 ether});

        // the governance holds no native balance: the action reverts and is not consumed
        _mockParseAndVerify(_buildVaa(_encodePayload(action), 0));
        vm.expectRevert();
        governance.receiveMessage("");
        assertEq(recipient.balance, 0);
        assertEq(governance.nextMinimumSequence(), 0);

        // fund the governance and re-deliver the same VAA: it now executes
        vm.deal(address(governance), 0.25 ether);
        governance.receiveMessage("");

        assertEq(recipient.balance, 0.25 ether);
        assertEq(address(governance).balance, 0);
    }

    function test_ReceiveMessage_PaysActionValueFromGovernanceBalance() public {
        address recipient = address(0xBEEF);
        vm.deal(address(governance), 1 ether);

        ProposedAction memory action = ProposedAction({target: recipient, data: "", value: 0.25 ether});
        _mockParseAndVerify(_buildVaa(_encodePayload(action), 0));

        governance.receiveMessage("");
        assertEq(recipient.balance, 0.25 ether);
        assertEq(address(governance).balance, 0.75 ether);
    }

    /// @notice A single message carries a batch of actions, executed in order: the typical
    ///     case of coupling an adapter upgrade with an implementation upgrade lands atomically.
    function test_ReceiveMessage_BatchActions_ExecuteInOrder() public {
        ProposedAction[] memory actions = new ProposedAction[](3);
        actions[0] = _buildIncrementAction();
        actions[1] = ProposedAction({target: address(counter), data: abi.encodeCall(Counter.setValue, (42)), value: 0});
        actions[2] = _buildIncrementAction();
        _mockParseAndVerify(_buildVaa(_encodePayload(actions, 1), 0));

        governance.receiveMessage("");
        assertEq(counter.value(), 43);
        assertEq(governance.nextMinimumSequence(), 1);
    }

    /// @notice A batch can upgrade the receiver itself: implementation and strategy are swapped
    ///     through self-targeted actions, exercising the same onlyGovernance path as local voting.
    function test_ReceiveMessage_BatchWithSelfUpgrades_Executes() public {
        CrosschainHarness newImpl = new CrosschainHarness();
        WormholeReceiverStrategy newStrategy = new WormholeReceiverStrategy(
            wormhole,
            Constants.GOV_PROXY,
            makeAddr("recovery")
        );

        ProposedAction[] memory actions = new ProposedAction[](2);
        actions[0] = ProposedAction({
            target: address(governance),
            data: abi.encodeCall(IGovernanceUpgrade.upgradeImplementation, (address(newImpl))),
            value: 0
        });
        actions[1] = ProposedAction({
            target: address(governance),
            data: abi.encodeCall(IGovernanceUpgrade.upgradeStrategy, (address(newStrategy))),
            value: 0
        });
        _mockParseAndVerify(_buildVaa(_encodePayload(actions, 1), 0));

        governance.receiveMessage("");
        assertEq(governance.implementation(), address(newImpl));
        assertEq(governance.governanceParameters().params.strategy, address(newStrategy));
    }

    /// @notice Voting thresholds can also be upgraded cross-chain through the self-call path.
    ///     The receive path executes stored actions directly; threshold bounds are validated
    ///     at execution time via validateParams, so the GRG supply is mocked to keep the
    ///     proposed values in bounds.
    function test_ReceiveMessage_UpgradesThresholds_ViaSelfCall() public {
        // 50M supply keeps 500k/2M in bounds: proposal [1%, 2%] = [500k, 1M], quorum [4%, 10%] = [2M, 5M]
        vm.mockCall(STAKING, abi.encodeWithSelector(IStaking.getGrgContract.selector), abi.encode(GRG));
        vm.mockCall(GRG, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(50_000_000e18));
        uint256 proposalThreshold = 500_000e18;
        uint256 quorumThreshold = 2_000_000e18;
        ProposedAction[] memory actions = new ProposedAction[](1);
        actions[0] = ProposedAction({
            target: address(governance),
            data: abi.encodeCall(IGovernanceUpgrade.updateThresholds, (proposalThreshold, quorumThreshold)),
            value: 0
        });
        _mockParseAndVerify(_buildVaa(_encodePayload(actions, 1), 0));

        governance.receiveMessage("");
        IGovernanceState.GovernanceParameters memory params = governance.governanceParameters().params;
        assertEq(params.proposalThreshold, proposalThreshold);
        assertEq(params.quorumThreshold, quorumThreshold);
    }

    /// @notice A message older than the execution window reverts with GovReceiverMessageExpired
    ///     and is not consumed: it can never become executable years later, and the next
    ///     sequence still delivers, so it does not clog the pipeline.
    function test_ReceiveMessage_ExpiredMessage_RevertsAndDoesNotClog() public {
        vm.warp(1_700_000_000);
        ProposedAction memory action = _buildIncrementAction();
        _mockParseAndVerify(_buildVaa(_encodePayload(action), 0, uint32(block.timestamp - 3 days)));

        vm.expectRevert(abi.encodeWithSelector(IGovernanceCrosschain.GovReceiverMessageExpired.selector, uint64(0)));
        governance.receiveMessage("");
        assertEq(counter.value(), 0);
        assertEq(governance.nextMinimumSequence(), 0);

        // the next message executes: the expired one did not clog the pipeline
        _mockParseAndVerify(_buildVaa(_encodePayload(action), 1));
        governance.receiveMessage("");
        assertEq(counter.value(), 1);
        assertEq(governance.nextMinimumSequence(), 2);

        // the expired message stays expired: after seq 1 executed, its sequence is also stale
        _mockParseAndVerify(_buildVaa(_encodePayload(action), 0, uint32(block.timestamp - 3 days)));
        vm.expectRevert(abi.encodeWithSelector(IGovernanceCrosschain.GovReceiverInvalidSequence.selector, 0, 2));
        governance.receiveMessage("");
    }

    /// @notice Expiry is not permanent data loss: the sender chain re-sends the action with a
    ///     fresh timestamp and the new message executes.
    function test_ReceiveMessage_ExpiredMessage_ResentWithFreshTimestamp_Executes() public {
        vm.warp(1_700_000_000);
        ProposedAction memory action = _buildIncrementAction();
        _mockParseAndVerify(_buildVaa(_encodePayload(action), 0, uint32(block.timestamp - 3 days)));
        vm.expectRevert(abi.encodeWithSelector(IGovernanceCrosschain.GovReceiverMessageExpired.selector, uint64(0)));
        governance.receiveMessage("");
        assertEq(counter.value(), 0);

        _mockParseAndVerify(_buildVaa(_encodePayload(_wrap(action), 2), 1));
        governance.receiveMessage("");
        assertEq(counter.value(), 1);
    }

    /// @notice The expiry window is inclusive: a VAA whose timestamp is exactly at the
    ///     boundary (block.timestamp == vaa.timestamp + 2 days) still executes.
    function test_ReceiveMessage_ExpiryBoundary_ExactTimeout_Executes() public {
        vm.warp(1_700_000_000);
        ProposedAction memory action = _buildIncrementAction();
        _mockParseAndVerify(_buildVaa(_encodePayload(action), 0, uint32(block.timestamp - 2 days)));

        governance.receiveMessage("");
        assertEq(counter.value(), 1);
        assertEq(governance.nextMinimumSequence(), 1);
    }

    /// @notice One second past the boundary the message is expired and not consumed.
    function test_ReceiveMessage_ExpiryBoundary_OneSecondPast_Reverts() public {
        vm.warp(1_700_000_000);
        ProposedAction memory action = _buildIncrementAction();
        _mockParseAndVerify(_buildVaa(_encodePayload(action), 0, uint32(block.timestamp - 2 days - 1)));

        vm.expectRevert(abi.encodeWithSelector(IGovernanceCrosschain.GovReceiverMessageExpired.selector, uint64(0)));
        governance.receiveMessage("");
        assertEq(counter.value(), 0);
        assertEq(governance.nextMinimumSequence(), 0);
    }

    /// @notice A failed call inside a batch reverts the whole message atomically: nothing
    ///     executes and the sequence does not advance.
    function test_ReceiveMessage_FailedCallInBatch_RevertsAtomically() public {
        FlakyTarget flaky = new FlakyTarget();
        flaky.setShouldRevert(true);

        ProposedAction[] memory actions = new ProposedAction[](2);
        actions[0] = ProposedAction({target: address(flaky), data: abi.encodeCall(FlakyTarget.run, ()), value: 0});
        actions[1] = _buildIncrementAction();
        _mockParseAndVerify(_buildVaa(_encodePayload(actions, 1), 0));

        vm.expectRevert(abi.encodeWithSelector(FlakyTarget.TargetRevert.selector));
        governance.receiveMessage("");

        assertEq(counter.value(), 0);
        assertEq(governance.nextMinimumSequence(), 0);
    }

    function test_ReceiveMessage_ExecutesOnlyGovernanceAction() public {
        // an action calling the governance itself executes with msg.sender == governance,
        // i.e. the sender chain holds the same authority as local voters
        CrosschainHarness newImpl = new CrosschainHarness();
        ProposedAction memory action = ProposedAction({
            target: address(governance),
            data: abi.encodeCall(IGovernanceUpgrade.upgradeImplementation, (address(newImpl))),
            value: 0
        });
        _mockParseAndVerify(_buildVaa(_encodePayload(action), 0));

        governance.receiveMessage("");
        assertEq(governance.implementation(), address(newImpl));
    }

    /// @notice The sender-chain governance is a fully functional local governance: it can make
    ///     and execute its own proposals with its own voting power and, independently, receive
    ///     cross-chain actions (e.g. a future hub migration delivering actions to mainnet).
    function test_LocalGovernance_CoexistsWithCrosschainReceive() public {
        // local voting power comes from the staking contract on this chain
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
            abi.encode(block.timestamp + 1)
        );
        // the first vote's best-effort roll calls endEpoch: return proper ABI data, a bare
        // no-code call would revert in a way that bypasses the strategy's try/catch
        vm.mockCall(STAKING, abi.encodeWithSelector(IStaking.endEpoch.selector), abi.encode(uint256(0)));
        vm.mockCall(STAKING, abi.encodeWithSelector(IStorage.epochDurationInSeconds.selector), abi.encode(7 days));

        // the cross-chain capability works...
        _mockParseAndVerify(_buildVaa(_encodePayload(_buildIncrementAction()), 0));
        governance.receiveMessage("");
        assertEq(counter.value(), 1);
        assertEq(governance.nextMinimumSequence(), 1);

        // ...and so does local governance on the same contract
        governance.setParams(1, 1);
        ProposedAction[] memory actions = new ProposedAction[](1);
        actions[0] = _buildIncrementAction();
        vm.prank(whale);
        uint256 proposalId = governance.propose(actions, "local proposal");

        vm.warp(block.timestamp + 2);
        vm.prank(whale);
        governance.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Qualified));

        vm.warp(block.timestamp + 1);
        governance.execute(proposalId);
        assertEq(counter.value(), 2);
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Executed));
    }

    /// @notice Regression: the qualified-majority denominator is the total voting power snapshotted
    ///     on the first vote. Shrinking the live delegated balance after votes are recorded
    ///     must not qualify a proposal that lacked two-thirds of the snapshot.
    function test_QualifiedConsensus_DenominatorShrinkAfterVote_DoesNotQualify() public {
        address voter = makeAddr("voter");
        uint256 attackerStake = 410_000e18;

        IStructs.StoredBalance memory whaleBalance = IStructs.StoredBalance({
            currentEpoch: 1,
            currentEpochBalance: uint96(DELEGATED_BALANCE),
            nextEpochBalance: uint96(DELEGATED_BALANCE)
        });
        IStructs.StoredBalance memory voterBalance = IStructs.StoredBalance({
            currentEpoch: 1,
            currentEpochBalance: uint96(attackerStake),
            nextEpochBalance: uint96(attackerStake)
        });
        vm.mockCall(
            STAKING,
            abi.encodeWithSelector(IStaking.getOwnerStakeByStatus.selector, whale, IStructs.StakeStatus.DELEGATED),
            abi.encode(whaleBalance)
        );
        vm.mockCall(
            STAKING,
            abi.encodeWithSelector(IStaking.getOwnerStakeByStatus.selector, voter, IStructs.StakeStatus.DELEGATED),
            abi.encode(voterBalance)
        );
        vm.mockCall(
            STAKING,
            abi.encodeWithSelector(IStaking.getGlobalStakeByStatus.selector, IStructs.StakeStatus.DELEGATED),
            abi.encode(whaleBalance) // 1,000,000 delegated at the first vote
        );
        vm.mockCall(
            STAKING,
            abi.encodeWithSelector(IStaking.getCurrentEpochEarliestEndTimeInSeconds.selector),
            abi.encode(block.timestamp + 1)
        );
        // the first vote's best-effort roll calls endEpoch: return proper ABI data, a bare
        // no-code call would revert in a way that bypasses the strategy's try/catch
        vm.mockCall(STAKING, abi.encodeWithSelector(IStaking.endEpoch.selector), abi.encode(uint256(0)));
        vm.mockCall(STAKING, abi.encodeWithSelector(IStorage.epochDurationInSeconds.selector), abi.encode(7 days));

        governance.setParams(1, 400_000e18);
        ProposedAction[] memory actions = new ProposedAction[](1);
        actions[0] = _buildIncrementAction();
        vm.prank(whale);
        uint256 proposalId = governance.propose(actions, "snapshot denominator");

        vm.warp(block.timestamp + 2);
        vm.prank(voter);
        governance.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));
        // 410k of a 1M snapshot (41%) is below the two-thirds threshold
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Active));

        // the attack: the live delegated supply shrinks to 590k, which would qualify 410k
        // against the shrunken electorate (3 * 410k > 2 * 590k) if the strategy read it live
        IStructs.StoredBalance memory shrunkBalance = IStructs.StoredBalance({
            currentEpoch: 2,
            currentEpochBalance: uint96(DELEGATED_BALANCE - attackerStake),
            nextEpochBalance: uint96(DELEGATED_BALANCE - attackerStake)
        });
        vm.mockCall(
            STAKING,
            abi.encodeWithSelector(IStaking.getGlobalStakeByStatus.selector, IStructs.StakeStatus.DELEGATED),
            abi.encode(shrunkBalance)
        );
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Active));
    }

    /// @notice With a Receiver-mode strategy installed, local proposal creation reverts at the
    ///     proxy level, while the cross-chain receive path keeps executing unaffected.
    function test_Receiver_LocalProposeReverts_ReceiveStillExecutes() public {
        WormholeReceiverStrategy receiverStrategy = new WormholeReceiverStrategy(
            wormhole,
            Constants.GOV_PROXY,
            makeAddr("recovery")
        );
        governance.setStrategy(address(receiverStrategy));

        ProposedAction[] memory actions = new ProposedAction[](1);
        actions[0] = _buildIncrementAction();
        // the voting-power gate fires before the strategy hook: getVotingPower returns 0 on a
        // receiver chain, so proposal creation is fail-closed either way. The harness leaves the
        // proposal threshold uninitialized (uint256.max).
        vm.expectRevert(abi.encodeWithSelector(MixinVoting.GovLowVotingPower.selector, 0, type(uint256).max));
        governance.propose(actions, "receiver local proposal");

        _mockParseAndVerify(_buildVaa(_encodePayload(_buildIncrementAction()), 0));
        governance.receiveMessage("");
        assertEq(counter.value(), 1);
        assertEq(governance.nextMinimumSequence(), 1);
    }
}

/// @title Re-entrancy probe for the cross-chain receiver.
/// @notice Re-delivers the VAA it was invoked with, so a re-entrant receiveMessage lands
///     mid-execution, while the outer message's sequence has already been consumed.
contract ReentrantRelayerTarget {
    address internal immutable governance;

    constructor(address governance_) {
        governance = governance_;
    }

    function reenter(bytes memory vaa) external {
        IGovernanceCrosschain(governance).receiveMessage(vaa);
    }
}
