// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {RigoblockGovernance} from "../../contracts/governance/RigoblockGovernance.sol";
import {IRigoblockGovernanceFactory} from "../../contracts/governance/interfaces/IRigoblockGovernanceFactory.sol";
import {IGovernanceInitializer} from "../../contracts/governance/interfaces/governance/IGovernanceInitializer.sol";
import {RigoblockGovernanceStrategy} from "../../contracts/governance/strategies/RigoblockGovernanceStrategy.sol";
import {TimeType} from "../../contracts/governance/types/TimeType.sol";

import {Test} from "forge-std/Test.sol";
import {ICoreBridge} from "wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol";
import {IERC20} from "../../contracts/tokens/ERC20/IERC20.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";

error InitParamsVerification();

/// @dev Runs initializeGovernance by delegatecall at construction time — the only context the
///      initializer accepts (onlyUninitialized requires empty code at address(this)) — and
///      propagates a failure's revert reason verbatim. The legacy proxy constructor masks the
///      initializer's custom errors into a panic, so the errors are asserted here instead.
contract InitProbe {
    bool public succeeded;

    constructor(address implementation, bytes memory data) {
        (bool ok, bytes memory returnData) = implementation.delegatecall(data);
        if (!ok) {
            // raw error propagation: bubble up the revert reason untouched
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
        succeeded = true;
    }
}

/// @dev A contract that does not implement the strategy interface.
contract NonStrategyContract {}

/// @dev A contract with an empty fallback: the probe call succeeds with empty returndata and
///      the returns-clause decode failure reverts with empty data, bypassing the catch clause.
contract EmptyFallbackContract {
    fallback() external {}
}

/// @title Tests for governance initialization parameter verification.
/// @notice The initializer is exercised through InitProbe because the production proxy
///     constructor asserts empty initialization returndata, masking every custom error into a
///     panic; the proxy is address-frozen (deterministic deployment), so the masking cannot be
///     fixed without a coordinated redeployment and is documented instead.
contract GovernanceInitializerTest is Test {
    address internal constant STAKING = address(0x1111);
    address internal constant GRG = address(0x2222);

    IRigoblockGovernanceFactory.Parameters internal _parameters;
    RigoblockGovernance internal implementation;
    RigoblockGovernanceStrategy internal strategy;
    address internal wormhole;

    constructor() {
        wormhole = makeAddr("wormhole");
        // enough code for the constructor's code.length check and chainId() probe
        vm.etch(wormhole, hex"00");
        vm.mockCall(wormhole, abi.encodeCall(ICoreBridge.chainId, ()), abi.encode(uint16(2)));
        implementation = new RigoblockGovernance(2);
        strategy = new RigoblockGovernanceStrategy(STAKING, wormhole);
    }

    // initializeGovernance reads the parameters from the calling factory contract
    function parameters() external view returns (IRigoblockGovernanceFactory.Parameters memory) {
        return _parameters;
    }

    function test_Initialize_EoaStrategy_Reverts() public {
        _parameters = _validParams();
        _parameters.governanceStrategy = address(0x4444);
        vm.expectRevert(InitParamsVerification.selector);
        new InitProbe(address(implementation), _initData());
    }

    function test_Initialize_NonInterfaceStrategy_Reverts() public {
        NonStrategyContract nonStrategy = new NonStrategyContract();
        _parameters = _validParams();
        _parameters.governanceStrategy = address(nonStrategy);
        vm.expectRevert(InitParamsVerification.selector);
        new InitProbe(address(implementation), _initData());
    }

    /// @dev A strategy-shaped contract with an empty fallback reverts with empty data, not
    ///     with InitParamsVerification: solc routes returndata-decode failures past the catch
    ///     clause. The deployment still reverts, so no garbage governance is created.
    function test_Initialize_EmptyFallbackStrategy_RevertsEmpty() public {
        EmptyFallbackContract fallbackStrategy = new EmptyFallbackContract();
        _parameters = _validParams();
        _parameters.governanceStrategy = address(fallbackStrategy);
        vm.expectRevert();
        new InitProbe(address(implementation), _initData());
    }

    function test_Initialize_ValidParams_Succeeds() public {
        _parameters = _validParams();
        vm.mockCall(STAKING, abi.encodeWithSelector(IStaking.getGrgContract.selector), abi.encode(GRG));
        vm.mockCall(GRG, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(10_000_000e18));
        InitProbe probe = new InitProbe(address(implementation), _initData());
        assertTrue(probe.succeeded());
    }

    function _initData() private pure returns (bytes memory) {
        return abi.encodeCall(IGovernanceInitializer.initializeGovernance, ());
    }

    function _validParams() private view returns (IRigoblockGovernanceFactory.Parameters memory) {
        return
            IRigoblockGovernanceFactory.Parameters({
                implementation: address(implementation),
                governanceStrategy: address(strategy),
                proposalThreshold: 100_000e18,
                quorumThreshold: 1_000_000e18,
                timeType: TimeType.Timestamp,
                name: "Rigoblock Governance"
            });
    }
}
