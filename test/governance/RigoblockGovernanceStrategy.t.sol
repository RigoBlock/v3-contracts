// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;
import {CrossChainPayload} from "../../contracts/governance/types/GovernanceTypes.sol";

import {Test} from "forge-std/Test.sol";
import {ICoreBridge} from "wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol";
import {IGovernanceState} from "../../contracts/governance/interfaces/governance/IGovernanceState.sol";
import {IGovernanceVoting} from "../../contracts/governance/interfaces/governance/IGovernanceVoting.sol";
import {RigoblockGovernanceStrategy} from "../../contracts/governance/strategies/RigoblockGovernanceStrategy.sol";
import {TimeType} from "../../contracts/governance/types/TimeType.sol";
import {IStorage} from "../../contracts/staking/interfaces/IStorage.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";

contract RigoblockGovernanceStrategyTest is Test {
    address internal constant STAKING = address(0x1111);
    address internal constant TARGET = address(0x3333);
    address internal constant WORMHOLE = address(0x4444);
    uint16 internal constant LOCAL_CHAIN_ID = 2;
    uint16 internal constant TARGET_CHAIN_ID = 47;
    uint256 internal constant FEE = 0.001 ether;

    RigoblockGovernanceStrategy internal strategy;

    function setUp() public {
        strategy = new RigoblockGovernanceStrategy(STAKING, WORMHOLE, LOCAL_CHAIN_ID);
        vm.mockCall(WORMHOLE, abi.encodeWithSelector(ICoreBridge.messageFee.selector), abi.encode(FEE));
        vm.mockCall(STAKING, abi.encodeWithSelector(IStorage.epochDurationInSeconds.selector), abi.encode(7 days));
    }

    function _action(
        address target,
        bytes memory data,
        uint256 value
    ) private pure returns (IGovernanceVoting.ProposedAction memory) {
        return IGovernanceVoting.ProposedAction({target: target, data: data, value: value});
    }

    function _payload(uint16 targetChainId) private pure returns (bytes memory) {
        IGovernanceVoting.ProposedAction memory action = _action(TARGET, "", 0);
        CrossChainPayload memory crossChainPayload = CrossChainPayload({
            targetWormholeChainId: targetChainId,
            proposalId: 1,
            action: action
        });
        return abi.encode(crossChainPayload);
    }

    function _wormholeData(uint16 targetChainId) private pure returns (bytes memory) {
        return
            abi.encodeWithSelector(ICoreBridge.publishMessage.selector, uint32(0), _payload(targetChainId), uint8(1));
    }

    function test_beforePropose_NonWormhole_Passes() public view {
        IGovernanceVoting.ProposedAction memory action = _action(TARGET, "", 0);
        IGovernanceVoting.ProposedAction memory result = strategy.beforePropose(action);
        assertEq(result.target, action.target);
        assertEq(result.data, action.data);
        assertEq(result.value, action.value);
    }

    function test_beforePropose_WormholeCorrect_Passes() public {
        vm.chainId(1);
        IGovernanceVoting.ProposedAction memory result = strategy.beforePropose(
            _action(WORMHOLE, _wormholeData(TARGET_CHAIN_ID), 0)
        );
        assertEq(result.target, WORMHOLE);
    }

    function test_beforePropose_NotMainnet_Reverts() public {
        vm.chainId(LOCAL_CHAIN_ID);
        vm.expectRevert(RigoblockGovernanceStrategy.GovCrosschainNotMainnet.selector);
        strategy.beforePropose(_action(WORMHOLE, _wormholeData(TARGET_CHAIN_ID), 0));
    }

    function test_beforePropose_WormholeInvalidData_Reverts() public {
        vm.chainId(1);
        bytes memory data = abi.encodePacked(bytes4(keccak256("unknown()")));
        vm.expectRevert(RigoblockGovernanceStrategy.GovCrosschainInvalidData.selector);
        strategy.beforePropose(_action(WORMHOLE, data, 0));
    }

    function test_beforePropose_WormholeTargetSelf_Reverts() public {
        vm.chainId(1);
        vm.expectRevert(
            abi.encodeWithSelector(RigoblockGovernanceStrategy.GovCrosschainTargetSelf.selector, LOCAL_CHAIN_ID)
        );
        strategy.beforePropose(_action(WORMHOLE, _wormholeData(LOCAL_CHAIN_ID), 0));
    }

    function test_beforePropose_WormholeNonZeroValue_Reverts() public {
        vm.chainId(1);
        uint256 value = 0.5 ether;
        vm.expectRevert(abi.encodeWithSelector(RigoblockGovernanceStrategy.GovCrosschainInvalidValue.selector, value));
        strategy.beforePropose(_action(WORMHOLE, _wormholeData(TARGET_CHAIN_ID), value));
    }

    function test_beforeExecute_NonWormhole_ReturnsUnchanged() public {
        IGovernanceVoting.ProposedAction memory action = _action(TARGET, "", 0.123 ether);
        IGovernanceVoting.ProposedAction memory result = strategy.beforeExecute(action);
        assertEq(result.target, action.target);
        assertEq(result.data, action.data);
        assertEq(result.value, action.value);
    }

    function test_beforeExecute_Wormhole_ReturnsFee() public {
        IGovernanceVoting.ProposedAction memory action = _action(WORMHOLE, _wormholeData(TARGET_CHAIN_ID), 0);
        IGovernanceVoting.ProposedAction memory result = strategy.beforeExecute(action);
        assertEq(result.target, WORMHOLE);
        assertEq(result.value, FEE);
    }

    function test_beforeExecute_Wormhole_OverridesProposerValue() public {
        // Wormhole's publishMessage requires msg.value == messageFee(), so any wrapper value
        // set at proposal time must be replaced by the fee rather than added to it.
        IGovernanceVoting.ProposedAction memory action = _action(WORMHOLE, _wormholeData(TARGET_CHAIN_ID), 1 ether);
        IGovernanceVoting.ProposedAction memory result = strategy.beforeExecute(action);
        assertEq(result.value, FEE);
    }

    function test_VotingTimestamps_Blocknumber_StartsNextBlock() public view {
        (uint256 startBlockOrTime, uint256 endBlockOrTime) = strategy.votingTimestamps(TimeType.Blocknumber);
        assertEq(startBlockOrTime, block.number + 1);
        assertEq(endBlockOrTime, startBlockOrTime + 7 days);
    }

    function test_VotingTimestamps_Timestamp_StartsNextTimestamp() public {
        vm.mockCall(
            STAKING,
            abi.encodeWithSelector(IStaking.getCurrentEpochEarliestEndTimeInSeconds.selector),
            abi.encode(block.timestamp - 1)
        );
        (uint256 startBlockOrTime, uint256 endBlockOrTime) = strategy.votingTimestamps(TimeType.Timestamp);
        assertEq(startBlockOrTime, block.timestamp + 1);
        assertEq(endBlockOrTime, startBlockOrTime + 7 days);
    }

    function test_GetProposalState_Blocknumber_ComparesBlockNumber() public {
        vm.roll(block.number + 100);

        IGovernanceState.Proposal memory proposal = IGovernanceState.Proposal({
            actionsLength: 1,
            startBlockOrTime: block.number + 1,
            endBlockOrTime: block.number + 100,
            votesFor: 0,
            votesAgainst: 0,
            votesAbstain: 0,
            executed: false
        });
        assertEq(
            uint256(strategy.getProposalState(proposal, 100, TimeType.Blocknumber)),
            uint256(IGovernanceState.ProposalState.Pending)
        );

        proposal.startBlockOrTime = block.number - 2;
        proposal.endBlockOrTime = block.number - 1;
        proposal.votesFor = 200;
        assertEq(
            uint256(strategy.getProposalState(proposal, 100, TimeType.Blocknumber)),
            uint256(IGovernanceState.ProposalState.Succeeded)
        );
    }
}
