// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Constants} from "../../contracts/test/Constants.sol";

import {A0xRouter} from "../../contracts/protocol/extensions/adapters/A0xRouter.sol";
import {IA0xRouter} from "../../contracts/protocol/extensions/adapters/interfaces/IA0xRouter.sol";
import {SmartPool} from "../../contracts/protocol/SmartPool.sol";

import {ExtensionsMap} from "../../contracts/protocol/deps/ExtensionsMap.sol";
import {ExtensionsMapDeployer} from "../../contracts/protocol/deps/ExtensionsMapDeployer.sol";
import {EApps} from "../../contracts/protocol/extensions/EApps.sol";
import {EOracle} from "../../contracts/protocol/extensions/EOracle.sol";
import {EUpgrade} from "../../contracts/protocol/extensions/EUpgrade.sol";
import {ECrosschain} from "../../contracts/protocol/extensions/ECrosschain.sol";
import {ENavView} from "../../contracts/protocol/extensions/ENavView.sol";

import {ISmartPool} from "../../contracts/protocol/ISmartPool.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {IAuthority} from "../../contracts/protocol/interfaces/IAuthority.sol";
import {IOwnedUninitialized} from "../../contracts/utils/owned/IOwnedUninitialized.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {IPoolRegistry} from "../../contracts/protocol/interfaces/IPoolRegistry.sol";
import {Extensions, DeploymentParams} from "../../contracts/protocol/types/DeploymentParams.sol";

/// @notice Minimal interface for the 0x Deployer/Registry
interface I0xDeployer {
    function ownerOf(uint256 tokenId) external view returns (address);
    function prev(uint128 featureId) external view returns (address);
}

/// @title A0xRouterFork - Fork integration tests for 0x swap aggregator adapter
/// @notice Validates A0xRouter against real 0x infrastructure on Ethereum mainnet
/// @dev Tests settler verification, bridge exclusion, approval pattern, and calldata validation
///  using real AllowanceHolder and Deployer contracts (not mocks).
contract A0xRouterForkTest is Test {
    // 0x infrastructure (from Constants.sol)
    address constant ALLOWANCE_HOLDER = Constants.ZERO_EX_ALLOWANCE_HOLDER;
    address constant DEPLOYER = Constants.ZERO_EX_DEPLOYER;

    /// @dev Feature ID 2 = Taker Submitted (same-chain swaps).
    uint128 constant SETTLER_TAKER_FEATURE = 2;

    /// @dev Feature ID 5 = Bridge (cross-chain, excluded by our adapter).
    uint128 constant SETTLER_BRIDGE_FEATURE = 5;

    // Rigoblock infrastructure
    address constant AUTHORITY = Constants.AUTHORITY;
    address constant FACTORY = Constants.FACTORY;

    // Selectors
    bytes4 constant EXEC_SELECTOR = 0x2213bc0b;
    bytes4 constant SETTLER_EXECUTE_SELECTOR = 0x1fff991f;

    uint256 mainnetFork;
    A0xRouter a0xRouter;
    address pool;
    address poolOwner;
    address currentSettler;

    function setUp() public {
        mainnetFork = vm.createSelectFork("mainnet", Constants.MAINNET_BLOCK);

        poolOwner = makeAddr("poolOwner");

        // Verify real 0x contracts exist at expected addresses
        assertTrue(ALLOWANCE_HOLDER.code.length > 0, "AllowanceHolder not deployed at expected address");
        assertTrue(DEPLOYER.code.length > 0, "Deployer not deployed at expected address");

        // Get current settler from real Deployer
        currentSettler = I0xDeployer(DEPLOYER).ownerOf(SETTLER_TAKER_FEATURE);
        assertTrue(currentSettler != address(0), "No settler registered for Feature 2");
        assertTrue(currentSettler.code.length > 0, "Current settler has no bytecode");
        console2.log("Current Feature 2 (Taker) settler:", currentSettler);

        // Deploy adapter with real 0x addresses
        a0xRouter = new A0xRouter(ALLOWANCE_HOLDER, DEPLOYER);

        // Set up pool infrastructure
        _setupPool();
    }

    /*//////////////////////////////////////////////////////////////////////////
                            REAL INFRASTRUCTURE VERIFICATION
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Verify real Deployer returns a valid settler for Feature 2
    function test_RealDeployer_ReturnsValidTakerSettler() public view {
        address settler = I0xDeployer(DEPLOYER).ownerOf(SETTLER_TAKER_FEATURE);
        assertTrue(settler != address(0), "Feature 2 settler should not be zero address");
        assertTrue(settler.code.length > 0, "Feature 2 settler should be a contract");
        console2.log("Feature 2 settler bytecode size:", settler.code.length);
    }

    /// @notice Verify previous settler (dwell time support) is accessible
    function test_RealDeployer_PrevSettlerAccessible() public view {
        address prev = I0xDeployer(DEPLOYER).prev(SETTLER_TAKER_FEATURE);
        console2.log("Previous Feature 2 settler:", prev);
        // prev may be zero if no previous deployment, or non-zero during dwell time
    }

    /*//////////////////////////////////////////////////////////////////////////
                        SETTLER VERIFICATION (AGAINST REAL DEPLOYER)
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Adapter accepts the real current settler from Deployer
    function test_Adapter_AcceptsRealCurrentSettler() public {
        deal(Constants.ETH_USDC, pool, 10000e6);

        bytes memory settlerData = _encodeSettlerExecute(
            pool,
            Constants.ETH_WETH, // WETH has price feed (wrappedNative)
            1e18
        );

        // Call should pass our validation (settler is genuine, calldata is valid).
        // The actual AllowanceHolder.exec will fail because our settler actions are empty,
        // but the revert should NOT be CounterfeitSettler/RecipientNotSmartPool/UnsupportedSettlerFunction.
        vm.prank(poolOwner);
        (bool success, bytes memory returnData) = pool.call(
            abi.encodeCall(IA0xRouter.exec, (currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData))
        );

        // Expected: call fails inside AllowanceHolder/Settler (not at our validation)
        assertFalse(success, "Call should fail (empty settler actions)");

        // Verify the error is NOT from our validation layer
        bytes4 errorSelector;
        if (returnData.length >= 4) {
            assembly {
                errorSelector := mload(add(returnData, 32))
            }
            assertTrue(errorSelector != IA0xRouter.CounterfeitSettler.selector, "Should not be CounterfeitSettler");
            assertTrue(errorSelector != IA0xRouter.RecipientNotSmartPool.selector, "Should not be RecipientNotSmartPool");
            assertTrue(errorSelector != IA0xRouter.UnsupportedSettlerFunction.selector, "Should not be UnsupportedSettlerFunction");
            assertTrue(errorSelector != IA0xRouter.InvalidSettlerCalldata.selector, "Should not be InvalidSettlerCalldata");
        }
    }

    /// @notice Adapter accepts the previous settler during dwell time
    function test_Adapter_AcceptsPrevSettlerIfAvailable() public {
        address prevSettler = I0xDeployer(DEPLOYER).prev(SETTLER_TAKER_FEATURE);
        if (prevSettler == address(0) || prevSettler.code.length == 0) {
            console2.log("No previous settler available at this block, skipping");
            return;
        }

        deal(Constants.ETH_USDC, pool, 10000e6);

        bytes memory settlerData = _encodeSettlerExecute(pool, Constants.ETH_WETH, 1e18);

        vm.prank(poolOwner);
        (bool success, bytes memory returnData) = pool.call(
            abi.encodeCall(IA0xRouter.exec, (prevSettler, Constants.ETH_USDC, 1000e6, payable(prevSettler), settlerData))
        );

        // Should fail inside exec, not at our settler validation
        assertFalse(success);
        if (returnData.length >= 4) {
            bytes4 errorSelector;
            assembly {
                errorSelector := mload(add(returnData, 32))
            }
            assertTrue(errorSelector != IA0xRouter.CounterfeitSettler.selector, "Prev settler should be accepted");
        }
    }

    /// @notice Adapter rejects addresses that are not registered settlers
    function test_Adapter_RejectsCounterfeitSettler() public {
        address fakeSettler = makeAddr("fakeSettler");

        bytes memory settlerData = _encodeSettlerExecute(pool, Constants.ETH_WETH, 1e18);

        vm.prank(poolOwner);
        vm.expectRevert(abi.encodeWithSelector(IA0xRouter.CounterfeitSettler.selector, fakeSettler));
        IA0xRouter(pool).exec(fakeSettler, Constants.ETH_USDC, 1000e6, payable(fakeSettler), settlerData);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        BRIDGE/CROSS-CHAIN EXCLUSION
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Feature 5 (Bridge) settler is rejected — different address than Feature 2
    function test_BridgeSettler_RejectedByAdapter() public {
        // Try to get the Bridge settler (Feature 5). It may be paused or not exist.
        try I0xDeployer(DEPLOYER).ownerOf(SETTLER_BRIDGE_FEATURE) returns (address bridgeSettler) {
            console2.log("Feature 5 (Bridge) settler:", bridgeSettler);

            // Bridge settler must be a different address from the Taker settler
            if (bridgeSettler != currentSettler && bridgeSettler != address(0)) {
                bytes memory settlerData = _encodeSettlerExecute(pool, Constants.ETH_WETH, 1e18);

                vm.prank(poolOwner);
                vm.expectRevert(abi.encodeWithSelector(IA0xRouter.CounterfeitSettler.selector, bridgeSettler));
                IA0xRouter(pool).exec(
                    bridgeSettler, Constants.ETH_USDC, 1000e6, payable(bridgeSettler), settlerData
                );
                console2.log("Bridge settler correctly rejected");
            } else {
                console2.log("Bridge settler same as Taker or zero - edge case at this block");
            }
        } catch {
            // Feature 5 may be paused or not exist at this block — expected
            console2.log("Feature 5 not available (paused or unregistered) - exclusion is inherent");
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                            CALLDATA VALIDATION
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Wrong recipient is rejected
    function test_CalldataValidation_RecipientNotPool() public {
        address wrongRecipient = makeAddr("wrongRecipient");

        bytes memory settlerData = _encodeSettlerExecute(wrongRecipient, Constants.ETH_WETH, 1e18);

        vm.prank(poolOwner);
        vm.expectRevert(IA0xRouter.RecipientNotSmartPool.selector);
        IA0xRouter(pool).exec(currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData);
    }

    /// @notice Unsupported function selector is rejected
    function test_CalldataValidation_UnsupportedSelector() public {
        // Construct calldata with a wrong selector
        bytes memory wrongData = abi.encodeWithSelector(
            bytes4(0xdeadbeef), pool, Constants.ETH_WETH, uint256(1e18),
            new bytes[](0), bytes32(0)
        );

        vm.prank(poolOwner);
        vm.expectRevert(IA0xRouter.UnsupportedSettlerFunction.selector);
        IA0xRouter(pool).exec(currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), wrongData);
    }

    /// @notice Calldata too short is rejected
    function test_CalldataValidation_TooShort() public {
        bytes memory shortData = hex"1fff991f0000000000000000"; // only 12 bytes of data

        vm.prank(poolOwner);
        vm.expectRevert(IA0xRouter.InvalidSettlerCalldata.selector);
        IA0xRouter(pool).exec(currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), shortData);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            APPROVAL PATTERN
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice ERC20 approval to AllowanceHolder is 0 before and after exec
    function test_ApprovalPattern_ZeroBeforeAndAfterExec() public {
        deal(Constants.ETH_USDC, pool, 10000e6);

        // Before: no approval
        uint256 allowanceBefore = IERC20(Constants.ETH_USDC).allowance(pool, ALLOWANCE_HOLDER);
        assertEq(allowanceBefore, 0, "Should start with 0 allowance");

        bytes memory settlerData = _encodeSettlerExecute(pool, Constants.ETH_WETH, 1e18);

        // Exec will fail inside AllowanceHolder/Settler (revert unwinds the approval too)
        vm.prank(poolOwner);
        (bool success,) = pool.call(
            abi.encodeCall(IA0xRouter.exec, (currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData))
        );
        assertFalse(success, "Call should fail (empty settler actions)");

        // After reverted exec: approval should still be 0 (revert unwinds state)
        uint256 allowanceAfter = IERC20(Constants.ETH_USDC).allowance(pool, ALLOWANCE_HOLDER);
        assertEq(allowanceAfter, 0, "Allowance should be 0 after reverted exec");
    }

    /// @notice Approval starts at 0 for a fresh pool
    function test_ApprovalPattern_FreshPoolHasZeroAllowance() public view {
        assertEq(
            IERC20(Constants.ETH_USDC).allowance(pool, ALLOWANCE_HOLDER),
            0,
            "Fresh pool should have 0 AllowanceHolder approval"
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                            ADAPTER PROPERTIES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Direct call to adapter reverts (must use delegatecall via pool)
    function test_DirectCall_Reverts() public {
        bytes memory settlerData = _encodeSettlerExecute(address(a0xRouter), Constants.ETH_WETH, 1e18);

        vm.expectRevert(IA0xRouter.DirectCallNotAllowed.selector);
        a0xRouter.exec(currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData);
    }

    /// @notice Required version returns expected value
    function test_RequiredVersion() public view {
        assertEq(a0xRouter.requiredVersion(), "4.0.0");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Encode Settler.execute calldata with AllowedSlippage and empty actions
    function _encodeSettlerExecute(
        address recipient,
        address buyToken,
        uint256 minAmountOut
    ) internal pure returns (bytes memory) {
        bytes[] memory actions = new bytes[](0);
        return abi.encodeWithSelector(
            SETTLER_EXECUTE_SELECTOR,
            recipient,
            buyToken,
            minAmountOut,
            actions,
            bytes32(0)
        );
    }

    /// @dev Deploy extensions, implementation, factory update, pool creation, adapter registration
    function _setupPool() private {
        // Deploy all required extensions
        EApps eApps = new EApps(Constants.GRG_STAKING, Constants.UNISWAP_V4_POSM);
        EOracle eOracle = new EOracle(Constants.ORACLE, Constants.ETH_WETH);
        EUpgrade eUpgrade = new EUpgrade(FACTORY);
        ENavView eNavView = new ENavView(Constants.GRG_STAKING, Constants.UNISWAP_V4_POSM);
        ECrosschain eCrosschain = new ECrosschain();

        Extensions memory extensions = Extensions({
            eApps: address(eApps),
            eOracle: address(eOracle),
            eUpgrade: address(eUpgrade),
            eNavView: address(eNavView),
            eCrosschain: address(eCrosschain)
        });

        // Deploy ExtensionsMap
        ExtensionsMapDeployer mapDeployer = new ExtensionsMapDeployer();
        DeploymentParams memory params = DeploymentParams({
            extensions: extensions,
            wrappedNative: Constants.ETH_WETH
        });
        bytes32 salt = keccak256(abi.encodePacked("A0X_ROUTER_FORK_TEST", block.chainid));
        address extensionsMapAddr = mapDeployer.deployExtensionsMap(params, salt);

        // Deploy new implementation
        SmartPool impl = new SmartPool(AUTHORITY, extensionsMapAddr, Constants.TOKEN_JAR);

        // Update factory implementation
        address registry = IRigoblockPoolProxyFactory(FACTORY).getRegistry();
        address rigoblockDao = IPoolRegistry(registry).rigoblockDao();
        vm.prank(rigoblockDao);
        IRigoblockPoolProxyFactory(FACTORY).setImplementation(address(impl));

        // Create pool with USDC base token
        vm.prank(poolOwner);
        (pool,) = IRigoblockPoolProxyFactory(FACTORY).createPool("0xForkTest", "0XF", Constants.ETH_USDC);
        console2.log("Pool created:", pool);

        // Register A0xRouter adapter in Authority
        address authorityOwner = IOwnedUninitialized(AUTHORITY).owner();
        vm.startPrank(authorityOwner);
        IAuthority(AUTHORITY).setAdapter(address(a0xRouter), true);
        if (!IAuthority(AUTHORITY).isWhitelister(authorityOwner)) {
            IAuthority(AUTHORITY).setWhitelister(authorityOwner, true);
        }
        IAuthority(AUTHORITY).addMethod(EXEC_SELECTOR, address(a0xRouter));
        vm.stopPrank();

        // Fund pool: user mints pool tokens
        address user = makeAddr("user");
        deal(Constants.ETH_USDC, user, 1_000_000e6);
        vm.startPrank(user);
        IERC20(Constants.ETH_USDC).approve(pool, type(uint256).max);
        ISmartPool(payable(pool)).mint(user, 100_000e6, 0);
        vm.stopPrank();
    }
}
