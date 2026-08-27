// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.35;
import {CrossChainPayload} from "../../contracts/governance/types/GovernanceTypes.sol";

import {Test} from "forge-std/Test.sol";
import {ICoreBridge} from "wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol";
import {IGovernanceVoting} from "../../contracts/governance/interfaces/governance/IGovernanceVoting.sol";
import {RigoblockGovernanceStrategy} from "../../contracts/governance/strategies/RigoblockGovernanceStrategy.sol";

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

    function _action(address target, bytes memory data, uint256 value) private pure returns (IGovernanceVoting.ProposedAction memory) {
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
        IGovernanceVoting.ProposedAction memory result = strategy.beforePropose(_action(WORMHOLE, _wormholeData(TARGET_CHAIN_ID), 0));
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
}
