// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Constants} from "../../contracts/test/Constants.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {ISmartPoolOwnerActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolOwnerActions.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {IAMulticall} from "../../contracts/protocol/extensions/adapters/interfaces/IAMulticall.sol";
import {IAStaking} from "../../contracts/protocol/extensions/adapters/interfaces/IAStaking.sol";
import {IAuthority} from "../../contracts/protocol/interfaces/IAuthority.sol";
import {Delegation} from "../../contracts/protocol/types/Delegation.sol";

/// @dev Minimal single-overload interface so `.selector` is unambiguous (IAMulticall overloads multicall).
interface IMulticallSimple {
    function multicall(bytes[] calldata data) external returns (bytes[] memory results);
}

/// @dev Local copy of the core onlyOwner auth error so we do not need to import the implementation.
error PoolCallerIsNotOwner();

/// @title MulticallDelegationSecurityForkTest
/// @notice Proves that delegating the AMulticall selectors to an agent does not escalate privileges.
/// @dev The operator does NOT delegate multicall: the NAV shield simulates
///      multicall([tx, updateUnitaryValue]) via eth_call FROM THE VAULT OWNER (who always
///      passes the fallback write-mode gate), and no execution flow multicalls. These tests
///      are kept as executable documentation in case multicall delegation is ever
///      reconsidered: each inner call re-enters the pool and is individually selector-checked
///      (adapter selectors run in write mode only for the owner or an address delegated that
///      exact selector), and core admin methods (setOwner, updateDelegation) are
///      direct-dispatch onlyOwner and never reach the delegation check. Uses the real mainnet
///      factory/authority/implementation.
contract MulticallDelegationSecurityForkTest is Test {
    address private constant AUTHORITY = Constants.AUTHORITY;
    address private constant FACTORY = Constants.FACTORY;

    bytes4 private constant MULTICALL_SELECTOR = IMulticallSimple.multicall.selector;

    address internal poolOwner;
    address internal agent;
    address internal outsider;
    address internal pool;

    function setUp() public {
        vm.createSelectFork("mainnet", Constants.MAINNET_BLOCK);

        require(address(AUTHORITY).code.length > 0, "Fork guard: authority has no code - check mainnet RPC");
        require(
            IAuthority(AUTHORITY).getApplicationAdapter(MULTICALL_SELECTOR) != address(0),
            "multicall selector not mapped on mainnet authority"
        );
        require(
            IAuthority(AUTHORITY).getApplicationAdapter(IAStaking.stake.selector) != address(0),
            "stake selector not mapped on mainnet authority"
        );

        poolOwner = makeAddr("poolOwner");
        agent = makeAddr("agent");
        outsider = makeAddr("outsider");

        vm.prank(poolOwner);
        (pool, ) = IRigoblockPoolProxyFactory(FACTORY).createPool("MulticallSec", "MCS", Constants.ETH_WETH);
    }

    function _grantSelector(address delegate, bytes4 selector) internal {
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = Delegation({delegated: delegate, selector: selector, isDelegated: true});
        vm.prank(poolOwner);
        ISmartPoolOwnerActions(pool).updateDelegation(delegations);
    }

    function _singleInner(bytes memory inner) internal pure returns (bytes[] memory data) {
        data = new bytes[](1);
        data[0] = inner;
    }

    function _assertAgentDelegatedSelectorsUnchanged() internal {
        bytes4[] memory selectors = ISmartPoolState(pool).getDelegatedSelectors(agent);
        assertEq(selectors.length, 1);
        assertEq(selectors[0], MULTICALL_SELECTOR);
    }

    /// @notice Positive control: an agent granted only multicall can batch a call whose inner
    ///         selectors it is entitled to (nested multicall wrapping updateUnitaryValue).
    function test_AgentWithOnlyMulticall_CanBatchAllowedCalls() public {
        _grantSelector(agent, MULTICALL_SELECTOR);

        bytes[] memory innermost = _singleInner(abi.encodeCall(ISmartPoolActions.updateUnitaryValue, ()));
        bytes[] memory inner = _singleInner(abi.encodeCall(IMulticallSimple.multicall, (innermost)));
        bytes[] memory outer = _singleInner(abi.encodeCall(IMulticallSimple.multicall, (inner)));

        vm.prank(agent);
        bytes[] memory results = IAMulticall(pool).multicall(outer);
        assertEq(results.length, 1);
        _assertAgentDelegatedSelectorsUnchanged();
    }

    /// @notice Sanity: the owner can always batch via multicall (owner write path).
    function test_OwnerCanBatchViaMulticall() public {
        bytes[] memory data = _singleInner(abi.encodeCall(ISmartPoolActions.updateUnitaryValue, ()));
        vm.prank(poolOwner);
        IAMulticall(pool).multicall(data);
    }

    /// @notice An address with no delegation gets a staticcall (read-only) outer call: a
    ///         state-changing inner call reverts.
    function test_OutsiderWithoutDelegation_CannotBatchStateChangingCall() public {
        bytes[] memory data = _singleInner(abi.encodeCall(ISmartPoolActions.updateUnitaryValue, ()));
        vm.prank(outsider);
        vm.expectRevert();
        IAMulticall(pool).multicall(data);
    }

    /// @notice CRITICAL: a multicall-delegated agent cannot take ownership by wrapping setOwner.
    ///         setOwner is a core method: it direct-dispatches and its onlyOwner check sees
    ///         msg.sender == agent, so it reverts before any delegation logic runs.
    function test_MulticallDelegatedAgent_CannotTakeOwnership() public {
        _grantSelector(agent, MULTICALL_SELECTOR);

        bytes[] memory data = _singleInner(abi.encodeCall(ISmartPoolOwnerActions.setOwner, (agent)));
        vm.prank(agent);
        vm.expectRevert(PoolCallerIsNotOwner.selector);
        IAMulticall(pool).multicall(data);

        assertEq(ISmartPoolState(pool).owner(), poolOwner);
        _assertAgentDelegatedSelectorsUnchanged();
    }

    /// @notice CRITICAL: a multicall-delegated agent cannot grant itself further delegations by
    ///         wrapping updateDelegation (same direct-dispatch onlyOwner path).
    function test_MulticallDelegatedAgent_CannotSelfGrantDelegation() public {
        _grantSelector(agent, MULTICALL_SELECTOR);

        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = Delegation({delegated: agent, selector: IAStaking.stake.selector, isDelegated: true});
        bytes[] memory data = _singleInner(abi.encodeCall(ISmartPoolOwnerActions.updateDelegation, (delegations)));

        vm.prank(agent);
        vm.expectRevert(PoolCallerIsNotOwner.selector);
        IAMulticall(pool).multicall(data);

        _assertAgentDelegatedSelectorsUnchanged();
    }

    /// @notice An adapter selector the agent was NOT delegated still routes to staticcall when
    ///         wrapped inside multicall, so a state-changing adapter call reverts.
    function test_MulticallDelegatedAgent_CannotExecuteNonDelegatedAdapterSelector() public {
        _grantSelector(agent, MULTICALL_SELECTOR);

        bytes[] memory data = _singleInner(abi.encodeCall(IAStaking.stake, (1)));
        vm.prank(agent);
        vm.expectRevert();
        IAMulticall(pool).multicall(data);

        _assertAgentDelegatedSelectorsUnchanged();
    }

    /// @notice Control: even with multicall delegated, a direct setOwner call from the agent
    ///         reverts (no fallback involved at all for core methods).
    function test_AgentCannotCallSetOwnerDirectly() public {
        _grantSelector(agent, MULTICALL_SELECTOR);

        vm.prank(agent);
        vm.expectRevert(PoolCallerIsNotOwner.selector);
        ISmartPoolOwnerActions(pool).setOwner(agent);

        assertEq(ISmartPoolState(pool).owner(), poolOwner);
    }

    /// @notice setOperator is permissionless but only records isApproved[msg.sender][operator]:
    ///         the agent self-granting via multicall acquires no rights over the owner's
    ///         holdings — only the owner can register an operator for themselves.
    function test_AgentSelfGrantingOperatorViaMulticallIsInert() public {
        _grantSelector(agent, MULTICALL_SELECTOR);
        assertFalse(ISmartPoolState(pool).isOperator(poolOwner, agent));

        bytes[] memory data = _singleInner(abi.encodeCall(ISmartPoolActions.setOperator, (agent, true)));
        vm.prank(agent);
        bytes[] memory results = IAMulticall(pool).multicall(data);
        assertEq(results.length, 1);

        assertFalse(ISmartPoolState(pool).isOperator(poolOwner, agent));
        assertEq(ISmartPoolState(pool).owner(), poolOwner);
        _assertAgentDelegatedSelectorsUnchanged();
    }
}
