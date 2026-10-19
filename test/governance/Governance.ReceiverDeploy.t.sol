// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {CHAIN_ID_ETHEREUM} from "wormhole-solidity-sdk/src/constants/Chains.sol";

import {Constants} from "../../contracts/test/Constants.sol";
import {IGovernanceState} from "../../contracts/governance/interfaces/governance/IGovernanceState.sol";
import {IRigoblockGovernanceFactory} from "../../contracts/governance/interfaces/IRigoblockGovernanceFactory.sol";
import {IWormholeReceiverStrategy} from "../../contracts/governance/strategies/interfaces/IWormholeReceiverStrategy.sol";
import {RigoblockGovernance} from "../../contracts/governance/RigoblockGovernance.sol";
import {TimeType} from "../../contracts/governance/types/TimeType.sol";
import {WormholeReceiverStrategy} from "../../contracts/governance/strategies/WormholeReceiverStrategy.sol";

/// @notice The canonical factory runtime code, captured from deployments/mainnet (the
///         deployments directory is gitignored). Foundry compiles the factory and proxy with
///         different metadata than the original Hardhat build, which would shift the proxy's
///         CREATE2 address; etching the deployed runtime reproduces the exact cross-chain
///         bytecode (and therefore the exact proxy address) on a blank chain.
contract WormholeCoreStub {
    function chainId() external pure returns (uint16) {
        return 47;
    }
}

/// @title Receiver-chain governance deployment in the real on-chain order.
/// @notice On a fresh receiver chain the receiver strategy is deployed before the governance
///         proxy exists: the factory's initializer requires a live strategy, and the proxy's
///         CREATE2 address is knowable in advance. This test reproduces that order with the
///         canonical factory code and no mocked init parameters: implementation and strategy
///         first, then the proxy via createGovernance, asserting the proxy lands at the
///         recorded deterministic address and the recovery veto is reachable from it. The
///         deploy-script gate that re-derives this address is covered by
///         Governance.DeterministicDeployment.spec.ts.
contract GovernanceReceiverDeployTest is Test {
    uint256 internal constant PROPOSAL_THRESHOLD = 100_000e18;
    uint256 internal constant QUORUM_THRESHOLD = 400_000e18;
    uint256 internal constant RECOVERY_WINDOW = 60 days;

    address internal recovery = makeAddr("recovery");

    IRigoblockGovernanceFactory internal factory;
    RigoblockGovernance internal implementation;
    WormholeReceiverStrategy internal strategy;

    function setUp() public {
        // canonical factory runtime at its canonical address
        bytes memory factoryRuntime = vm.parseBytes(
            vm.readFile("test/fixtures/governance/RigoblockGovernanceFactory.mainnet.hex")
        );
        vm.etch(Constants.GOV_FACTORY, factoryRuntime);
        factory = IRigoblockGovernanceFactory(Constants.GOV_FACTORY);

        // the implementation constructor takes the hub's Wormhole chain id (Ethereum)
        implementation = new RigoblockGovernance(CHAIN_ID_ETHEREUM);

        // a blank receiver chain has no governance proxy yet: the strategy must be deployable
        // anyway. Before this train the constructor probed governanceProxy.code.length, which
        // made the receiver flow unbootstrappable; the address is now a plain immutable input.
        assertEq(Constants.GOV_PROXY.code.length, 0);
        strategy = new WormholeReceiverStrategy(address(new WormholeCoreStub()), Constants.GOV_PROXY, recovery);
    }

    function test_ReceiverDeploy_ProxyLandsAtRecordedAddress() public {
        vm.prank(Constants.GOV_CREATOR);
        address proxy = factory.createGovernance(
            address(implementation),
            address(strategy),
            PROPOSAL_THRESHOLD,
            QUORUM_THRESHOLD,
            TimeType.Timestamp,
            "Rigoblock Governance"
        );

        assertEq(proxy, Constants.GOV_PROXY);

        // initialization ran inside the proxy constructor: the strategy and thresholds are live
        IGovernanceState.GovernanceParameters memory params = IGovernanceState(proxy).governanceParameters().params;
        assertEq(params.strategy, address(strategy));
        assertEq(params.proposalThreshold, PROPOSAL_THRESHOLD);
        assertEq(params.quorumThreshold, QUORUM_THRESHOLD);
        assertEq(uint256(params.timeType), uint256(TimeType.Timestamp));
    }

    function test_ReceiverDeploy_RecoveryVetoReachableFromProxy() public {
        vm.prank(Constants.GOV_CREATOR);
        factory.createGovernance(
            address(implementation),
            address(strategy),
            PROPOSAL_THRESHOLD,
            QUORUM_THRESHOLD,
            TimeType.Timestamp,
            "Rigoblock Governance"
        );

        vm.prank(recovery);
        strategy.requestRecover();
        vm.warp(block.timestamp + RECOVERY_WINDOW);

        // only the governance proxy can veto a recovery: the strategy authenticates the address
        // recorded at deployment, which requires no code at deploy time
        vm.prank(makeAddr("notTheProxy"));
        vm.expectRevert(
            abi.encodeWithSelector(IWormholeReceiverStrategy.GovRecoveryUnauthorized.selector, makeAddr("notTheProxy"))
        );
        strategy.rejectRecover();

        vm.prank(Constants.GOV_PROXY);
        strategy.rejectRecover();
        assertEq(strategy.getVotingPower(recovery), 0);
    }
}
