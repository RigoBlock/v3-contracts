// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {ICoreBridge} from "wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol";
import {RigoblockGovernanceStrategy} from "../../contracts/governance/strategies/RigoblockGovernanceStrategy.sol";
import {IGovernanceCrosschain} from "../../contracts/governance/interfaces/governance/IGovernanceCrosschain.sol";
import {IGovernanceVoting} from "../../contracts/governance/interfaces/governance/IGovernanceVoting.sol";

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
    }

    function _action(
        address target,
        bytes memory data,
        uint256 value
    ) private pure returns (IGovernanceVoting.ProposedAction memory) {
        return IGovernanceVoting.ProposedAction({target: target, data: data, value: value});
    }

    function _payload(uint16 targetChainId) private pure returns (bytes memory) {
        IGovernanceVoting.ProposedAction memory action = IGovernanceVoting.ProposedAction({
            target: TARGET,
            data: bytes(""),
            value: 0
        });
        IGovernanceCrosschain.CrossChainPayload memory crossChainPayload = IGovernanceCrosschain.CrossChainPayload({
            targetWormholeChainId: targetChainId,
            proposalId: 1,
            action: action
        });
        return abi.encode(crossChainPayload);
    }

    function test_ValidateAction_NonWormhole_Passes() public view {
        strategy.validateAction(_action(TARGET, "", 0));
    }

    function test_ValidateAction_WormholeCorrect_Passes() public view {
        bytes memory data = abi.encodeWithSelector(
            ICoreBridge.publishMessage.selector,
            uint32(0),
            _payload(TARGET_CHAIN_ID),
            uint8(1)
        );
        strategy.validateAction(_action(WORMHOLE, data, FEE));
    }

    function test_ValidateAction_WormholeInvalidData_Reverts() public {
        bytes memory data = abi.encodePacked(bytes4(keccak256("unknown()")));
        vm.expectRevert(RigoblockGovernanceStrategy.GovCrosschainInvalidData.selector);
        strategy.validateAction(_action(WORMHOLE, data, FEE));
    }

    function test_ValidateAction_WormholeInvalidValue_Reverts() public {
        bytes memory data = abi.encodeWithSelector(
            ICoreBridge.publishMessage.selector,
            uint32(0),
            _payload(TARGET_CHAIN_ID),
            uint8(1)
        );
        vm.expectRevert(
            abi.encodeWithSelector(RigoblockGovernanceStrategy.GovCrosschainInvalidValue.selector, FEE, FEE - 1)
        );
        strategy.validateAction(_action(WORMHOLE, data, FEE - 1));
    }

    function test_ValidateAction_WormholeTargetSelf_Reverts() public {
        bytes memory data = abi.encodeWithSelector(
            ICoreBridge.publishMessage.selector,
            uint32(0),
            _payload(LOCAL_CHAIN_ID),
            uint8(1)
        );
        vm.expectRevert(
            abi.encodeWithSelector(RigoblockGovernanceStrategy.GovCrosschainTargetSelf.selector, LOCAL_CHAIN_ID)
        );
        strategy.validateAction(_action(WORMHOLE, data, FEE));
    }
}
