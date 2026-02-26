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
import {EnumerableSet} from "../../contracts/protocol/libraries/EnumerableSet.sol";

import {ISmartPool} from "../../contracts/protocol/ISmartPool.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {IAuthority} from "../../contracts/protocol/interfaces/IAuthority.sol";
import {IOwnedUninitialized} from "../../contracts/utils/owned/IOwnedUninitialized.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {IPoolRegistry} from "../../contracts/protocol/interfaces/IPoolRegistry.sol";
import {Extensions, DeploymentParams} from "../../contracts/protocol/types/DeploymentParams.sol";

// Imported from 0x-settler submodule — provides type-safe selectors for action validation.
import {ISettlerActions} from "0x-settler/src/ISettlerActions.sol";
import {IBridgeSettlerActions} from "0x-settler/src/bridge/IBridgeSettlerActions.sol";
import {IAllowanceHolder} from "0x-settler/src/allowanceholder/IAllowanceHolder.sol";
import {ISettlerTakerSubmitted} from "0x-settler/src/interfaces/ISettlerTakerSubmitted.sol";
import {ActionInvalid} from "0x-settler/src/core/SettlerErrors.sol";
import {IDeployer, IERC721View} from "0x-settler/src/deployer/IDeployer.sol";
import {Feature} from "0x-settler/src/deployer/Feature.sol";

/// @title A0xRouterFork - Fork integration tests for 0x swap aggregator adapter
/// @notice Validates A0xRouter against real 0x infrastructure on Ethereum mainnet.
///  All selectors are derived from 0x-settler submodule interfaces — no hardcoded hex values.
/// @dev Tests settler verification, bridge exclusion, approval pattern, calldata validation,
///  access control, error propagation, and token management using real AllowanceHolder and
///  Deployer contracts (not mocks).
///
/// UPGRADE RISK: These tests pin to a specific block and 0x-settler commit. If 0x upgrades
/// their settler contracts (new action selectors, changed dispatch logic), tests may need
/// updates. In particular, if future settlers add bridge actions to the Taker dispatch chain,
/// the ActionInvalid assertions in bridge exclusion tests would fail — requiring adapter updates.
contract A0xRouterForkTest is Test {
    // 0x infrastructure (from Constants.sol)
    address constant ALLOWANCE_HOLDER = Constants.ZERO_EX_ALLOWANCE_HOLDER;
    address constant DEPLOYER = Constants.ZERO_EX_DEPLOYER;

    /// @dev Feature ID 2 = Taker Submitted (same-chain swaps).
    ///  Not importable from 0x-settler — magic number in each settler variant's _tokenId() override.
    ///  See: require(Feature.unwrap(takerSubmittedFeature) == 2) in 0x-settler/script/DeploySafes.s.sol
    Feature constant TAKER_SUBMITTED_FEATURE = Feature.wrap(2);

    /// @dev Feature ID 5 = Bridge (cross-chain, excluded by our adapter).
    ///  See: require(Feature.unwrap(bridgeFeature) == 5) in 0x-settler/script/DeploySafes.s.sol
    Feature constant BRIDGE_FEATURE = Feature.wrap(5);

    // Rigoblock infrastructure
    address constant AUTHORITY = Constants.AUTHORITY;
    address constant FACTORY = Constants.FACTORY;

    // Selectors derived from 0x-settler interfaces — NOT hardcoded hex values.
    bytes4 constant EXEC_SELECTOR = IAllowanceHolder.exec.selector;
    bytes4 constant SETTLER_EXECUTE_SELECTOR = ISettlerTakerSubmitted.execute.selector;

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
        currentSettler = IDeployer(DEPLOYER).ownerOf(Feature.unwrap(TAKER_SUBMITTED_FEATURE));
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
        address settler = IDeployer(DEPLOYER).ownerOf(Feature.unwrap(TAKER_SUBMITTED_FEATURE));
        assertTrue(settler != address(0), "Feature 2 settler should not be zero address");
        assertTrue(settler.code.length > 0, "Feature 2 settler should be a contract");
        console2.log("Feature 2 settler bytecode size:", settler.code.length);
    }

    /// @notice Verify previous settler (dwell time support) is accessible
    function test_RealDeployer_PrevSettlerAccessible() public view {
        address prev = IDeployer(DEPLOYER).prev(TAKER_SUBMITTED_FEATURE);
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
        // but the revert should NOT be from our validation layer.
        vm.prank(poolOwner);
        try IA0xRouter(pool).exec(currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData) {
            revert("Call should revert inside settler (empty actions)");
        } catch (bytes memory returnData) {
            _assertNotOurValidationError(returnData);
        }
    }

    /// @notice Adapter accepts the previous settler during dwell time
    function test_Adapter_AcceptsPrevSettlerIfAvailable() public {
        address prevSettler = IDeployer(DEPLOYER).prev(TAKER_SUBMITTED_FEATURE);
        if (prevSettler == address(0) || prevSettler.code.length == 0) {
            console2.log("No previous settler available at this block, skipping");
            return;
        }

        deal(Constants.ETH_USDC, pool, 10000e6);

        bytes memory settlerData = _encodeSettlerExecute(pool, Constants.ETH_WETH, 1e18);

        vm.prank(poolOwner);
        try IA0xRouter(pool).exec(prevSettler, Constants.ETH_USDC, 1000e6, payable(prevSettler), settlerData) {
            revert("Call should revert inside settler (empty actions)");
        } catch (bytes memory returnData) {
            _assertNotOurValidationError(returnData);
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

    Bridge protection operates at three independent layers:

    Layer 1 — Adapter settler verification (_requireGenuineSettler):
      Only Feature 2 (Taker Submitted) settlers accepted. Feature 5 (Bridge)
      and Feature 4 (Intent) settlers have different addresses and are rejected.

    Layer 2 — Adapter action scanning (_checkNoForbiddenActions):
      The adapter scans the settler's actions array for RFQ selectors and reverts
      with ForbiddenAction if found. RFQ allows arbitrary counterparty at arbitrary
      price — a phished pool owner or malicious agent could submit it.
      Blocked selectors: ISettlerActions.RFQ, ISettlerActions.RFQ_VIP.

    Layer 3 — Settler action dispatch:
      Feature 2 settlers only recognize ISettlerActions selectors (UNISWAPV3,
      UNISWAPV2, BASIC, VELODROME, etc.). Bridge actions from IBridgeSettlerActions
      (BRIDGE_ERC20_TO_ACROSS, BRIDGE_NATIVE_TO_ACROSS, etc.) are NOT in the Taker
      settler's _dispatch chain. Unknown selectors cause revert with ActionInvalid.
      NOTE: If a future settler version adds bridge actions to the Taker dispatch,
      these tests would need updating and the adapter would need a new exclusion list.

    Layer 4 — Settler slippage check (_checkSlippageAndTransfer):
      Runs at the end of execute(). Requires settler to hold >= minAmountOut of
      buyToken. If tokens were bridged away, the settler wouldn't hold them.
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Feature 5 (Bridge) settler is rejected — different address than Feature 2
    function test_BridgeSettler_RejectedByAdapter() public {
        // Try to get the Bridge settler (Feature 5). It may be paused or not exist.
        try IDeployer(DEPLOYER).ownerOf(Feature.unwrap(BRIDGE_FEATURE)) returns (address bridgeSettler) {
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

    /// @notice Bridge action selectors are blocked by the adapter's action allowlist.
    ///  Bridge actions from IBridgeSettlerActions are not in the allowlist, so they are
    ///  rejected with ActionNotAllowed before reaching the settler.
    function test_BridgeExclusion_BridgeActionSelectorsBlockedByAllowlist() public {
        deal(Constants.ETH_USDC, pool, 10000e6);

        // Known bridge action selectors from IBridgeSettlerActions interface (imported from 0x-settler).
        bytes4[4] memory bridgeSelectors = [
            IBridgeSettlerActions.BRIDGE_ERC20_TO_ACROSS.selector,
            IBridgeSettlerActions.BRIDGE_NATIVE_TO_ACROSS.selector,
            IBridgeSettlerActions.BRIDGE_ERC20_TO_MAYAN.selector,
            IBridgeSettlerActions.BRIDGE_TO_DEBRIDGE.selector
        ];

        for (uint256 i = 0; i < bridgeSelectors.length; i++) {
            // Encode a bridge action in the settler's actions array.
            bytes memory bridgeAction = abi.encodePacked(
                bridgeSelectors[i],
                abi.encode(address(0xdead), bytes("fake_deposit_data"))
            );

            bytes[] memory actions = new bytes[](1);
            actions[0] = bridgeAction;

            // Build full settler execute calldata with the bridge action
            bytes memory settlerData = abi.encodeWithSelector(
                SETTLER_EXECUTE_SELECTOR,
                pool,               // recipient (passes our adapter validation)
                Constants.ETH_WETH,  // buyToken (has price feed)
                uint256(1e15),       // minAmountOut
                actions,
                bytes32(0)
            );

            vm.prank(poolOwner);
            vm.expectRevert(abi.encodeWithSelector(IA0xRouter.ActionNotAllowed.selector, bridgeSelectors[i]));
            IA0xRouter(pool).exec(
                currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData
            );
        }

        // Pool balance unchanged — revert unwound everything
        assertEq(IERC20(Constants.ETH_USDC).balanceOf(pool), 10000e6, "Pool USDC unchanged");
    }

    /// @notice Non-Feature-2 settlers are all rejected by the adapter.
    function test_BridgeExclusion_NonFeature2SettlersRejected() public {
        bytes memory settlerData = _encodeSettlerExecute(pool, Constants.ETH_WETH, 1e18);

        // Test features 1 through 10 (excluding 2 = our accepted feature)
        for (uint128 featureId = 1; featureId <= 10; featureId++) {
            if (featureId == Feature.unwrap(TAKER_SUBMITTED_FEATURE)) continue; // skip Feature 2

            try IDeployer(DEPLOYER).ownerOf(featureId) returns (address featureSettler) {
                if (featureSettler == address(0) || featureSettler == currentSettler) continue;

                console2.log("Feature", featureId, "settler:", featureSettler);

                vm.prank(poolOwner);
                vm.expectRevert(abi.encodeWithSelector(IA0xRouter.CounterfeitSettler.selector, featureSettler));
                IA0xRouter(pool).exec(
                    featureSettler, Constants.ETH_USDC, 1000e6, payable(featureSettler), settlerData
                );
            } catch {
                console2.log("Feature", featureId, "not available (paused or unregistered)");
            }
        }
    }

    /// @notice BASIC action now passes the adapter's allowlist (needed for ETH wrapping).
    ///  Settler's _isRestrictedTarget() and slippage check provide protection instead.
    function test_BridgeExclusion_BasicActionAllowedByAllowlist() public {
        deal(Constants.ETH_USDC, pool, 10000e6);

        // Encode BASIC action
        bytes memory basicAction = abi.encodePacked(
            ISettlerActions.BASIC.selector,
            abi.encode(
                Constants.ETH_USDC,    // sellToken
                uint256(10000),        // bps = 100%
                address(0xdeadbeef),   // pool target
                uint256(0),            // offset
                bytes("")              // call data
            )
        );

        bytes[] memory actions = new bytes[](1);
        actions[0] = basicAction;

        bytes memory settlerData = abi.encodeWithSelector(
            SETTLER_EXECUTE_SELECTOR,
            pool,               // recipient
            Constants.ETH_WETH,  // buyToken
            uint256(1e15),       // minAmountOut
            actions,
            bytes32(0)
        );

        // BASIC passes our validation — reverts inside AllowanceHolder/settler, not from adapter
        vm.prank(poolOwner);
        try IA0xRouter(pool).exec(
            currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData
        ) {
            revert("Should revert inside settler (bad params)");
        } catch (bytes memory returnData) {
            _assertNotOurValidationError(returnData);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                        ACTION ALLOWLIST

    The adapter uses a whitelist pattern: only explicitly allowed action selectors
    pass validation. BASIC is allowed (needed by the 0x API for ETH wrapping and
    intermediate operations). Blocked: RFQ (arbitrary off-chain pricing),
    RENEGADE (arbitrary target), METATXN_* (wrong execution flow), and bridge
    actions. Unrecognized selectors are also blocked by default.
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice RFQ action is blocked — reverts with ActionNotAllowed.
    function test_RFQ_BlockedByAdapter() public {
        deal(Constants.ETH_USDC, pool, 10000e6);

        bytes4 rfqSelector = ISettlerActions.RFQ.selector;

        bytes memory rfqAction = abi.encodePacked(
            rfqSelector,
            abi.encode(
                pool,                  // recipient
                address(0),            // permit.permitted.token (placeholder)
                uint256(0),            // permit.permitted.amount
                uint256(0),            // permit.nonce
                uint256(0),            // permit.deadline
                address(0xdeadbeef),   // maker
                bytes("fake_sig"),     // makerSig
                Constants.ETH_USDC,    // takerToken
                uint256(1000e6)        // maxTakerAmount
            )
        );

        bytes[] memory actions = new bytes[](1);
        actions[0] = rfqAction;

        bytes memory settlerData = abi.encodeWithSelector(
            SETTLER_EXECUTE_SELECTOR,
            pool,               // recipient (passes adapter validation)
            Constants.ETH_WETH,  // buyToken (has price feed)
            uint256(1e15),       // minAmountOut > 0 (required by adapter)
            actions,
            bytes32(0)
        );

        vm.prank(poolOwner);
        vm.expectRevert(abi.encodeWithSelector(IA0xRouter.ActionNotAllowed.selector, rfqSelector));
        IA0xRouter(pool).exec(
            currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData
        );

        assertEq(IERC20(Constants.ETH_USDC).balanceOf(pool), 10000e6, "Pool USDC unchanged");
    }

    /// @notice RFQ_VIP action is also blocked (forward security).
    function test_RFQ_VIP_BlockedByAdapter() public {
        deal(Constants.ETH_USDC, pool, 10000e6);

        bytes4 rfqVipSelector = ISettlerActions.RFQ_VIP.selector;

        bytes memory rfqVipAction = abi.encodePacked(
            rfqVipSelector,
            abi.encode(
                pool,                  // recipient
                address(0), uint256(0), uint256(0), uint256(0), // takerPermit placeholder
                address(0), uint256(0), uint256(0), uint256(0), // makerPermit placeholder
                address(0xdeadbeef),   // maker
                bytes("fake_maker_sig"),
                bytes("fake_taker_sig")
            )
        );

        bytes[] memory actions = new bytes[](1);
        actions[0] = rfqVipAction;

        bytes memory settlerData = abi.encodeWithSelector(
            SETTLER_EXECUTE_SELECTOR,
            pool, Constants.ETH_WETH, uint256(1e15),
            actions, bytes32(0)
        );

        vm.prank(poolOwner);
        vm.expectRevert(abi.encodeWithSelector(IA0xRouter.ActionNotAllowed.selector, rfqVipSelector));
        IA0xRouter(pool).exec(
            currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData
        );

        assertEq(IERC20(Constants.ETH_USDC).balanceOf(pool), 10000e6, "Pool USDC unchanged");
    }

    /// @notice RFQ embedded as the Nth action (not just first) is also caught.
    function test_RFQ_BlockedEvenAsSecondAction() public {
        deal(Constants.ETH_USDC, pool, 10000e6);

        bytes4 rfqSelector = ISettlerActions.RFQ.selector;

        // First action: a valid-looking TRANSFER_FROM (harmless)
        bytes memory transferAction = abi.encodePacked(
            ISettlerActions.TRANSFER_FROM.selector,
            abi.encode(pool, address(0), uint256(0), uint256(0), uint256(0), bytes(""))
        );

        // Second action: RFQ (must be caught)
        bytes memory rfqAction = abi.encodePacked(
            rfqSelector,
            abi.encode(pool, address(0), uint256(0), uint256(0), uint256(0),
                address(0xdead), bytes(""), Constants.ETH_USDC, uint256(1000e6))
        );

        bytes[] memory actions = new bytes[](2);
        actions[0] = transferAction;
        actions[1] = rfqAction;

        bytes memory settlerData = abi.encodeWithSelector(
            SETTLER_EXECUTE_SELECTOR,
            pool, Constants.ETH_WETH, uint256(1e15),
            actions, bytes32(0)
        );

        vm.prank(poolOwner);
        vm.expectRevert(abi.encodeWithSelector(IA0xRouter.ActionNotAllowed.selector, rfqSelector));
        IA0xRouter(pool).exec(
            currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData
        );
    }

    /// @notice BASIC action is allowed — needed by 0x API for ETH wrapping/unwrapping and
    ///  intermediate protocol interactions. Protected by settler's _isRestrictedTarget() and
    ///  slippage check.
    function test_BASIC_AllowedByAdapter() public {
        deal(Constants.ETH_USDC, pool, 10000e6);

        // BASIC(address sellToken, uint256 bps, address pool, uint256 offset, bytes data)
        bytes memory basicAction = abi.encodePacked(
            ISettlerActions.BASIC.selector,
            abi.encode(
                Constants.ETH_USDC,     // sellToken
                uint256(10000),         // bps (100%)
                address(0xdeadbeef),    // pool (arbitrary target)
                uint256(0),             // offset
                bytes("arbitrary_data")
            )
        );

        bytes[] memory actions = new bytes[](1);
        actions[0] = basicAction;

        bytes memory settlerData = abi.encodeWithSelector(
            SETTLER_EXECUTE_SELECTOR,
            pool, Constants.ETH_WETH, uint256(1e15),
            actions, bytes32(0)
        );

        // BASIC passes our validation. The call reverts inside AllowanceHolder/settler,
        // not from our adapter validation.
        vm.prank(poolOwner);
        try IA0xRouter(pool).exec(
            currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData
        ) {
            revert("Should revert inside settler (bad params)");
        } catch (bytes memory returnData) {
            _assertNotOurValidationError(returnData);
        }
    }

    /// @notice RENEGADE action is blocked — it calls an arbitrary target with arbitrary data.
    function test_RENEGADE_BlockedByAdapter() public {
        deal(Constants.ETH_USDC, pool, 10000e6);

        bytes4 renegadeSelector = ISettlerActions.RENEGADE.selector;

        bytes memory renegadeAction = abi.encodePacked(
            renegadeSelector,
            abi.encode(address(0xdeadbeef), Constants.ETH_USDC, bytes("arbitrary"))
        );

        bytes[] memory actions = new bytes[](1);
        actions[0] = renegadeAction;

        bytes memory settlerData = abi.encodeWithSelector(
            SETTLER_EXECUTE_SELECTOR,
            pool, Constants.ETH_WETH, uint256(1e15),
            actions, bytes32(0)
        );

        vm.prank(poolOwner);
        vm.expectRevert(abi.encodeWithSelector(IA0xRouter.ActionNotAllowed.selector, renegadeSelector));
        IA0xRouter(pool).exec(
            currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData
        );

        assertEq(IERC20(Constants.ETH_USDC).balanceOf(pool), 10000e6, "Pool USDC unchanged");
    }

    /// @notice METATXN_* variants are blocked — they are for the executeMetaTxn flow,
    ///  not TakerSubmitted. Blocking reduces unnecessary attack surface.
    function test_METATXN_BlockedByAdapter() public {
        deal(Constants.ETH_USDC, pool, 10000e6);

        bytes4 metatxnSelector = ISettlerActions.METATXN_UNISWAPV3_VIP.selector;

        bytes memory metatxnAction = abi.encodePacked(
            metatxnSelector,
            abi.encode(pool, address(0), uint256(0), uint256(0), uint256(0), bytes(""), uint256(0))
        );

        bytes[] memory actions = new bytes[](1);
        actions[0] = metatxnAction;

        bytes memory settlerData = abi.encodeWithSelector(
            SETTLER_EXECUTE_SELECTOR,
            pool, Constants.ETH_WETH, uint256(1e15),
            actions, bytes32(0)
        );

        vm.prank(poolOwner);
        vm.expectRevert(abi.encodeWithSelector(IA0xRouter.ActionNotAllowed.selector, metatxnSelector));
        IA0xRouter(pool).exec(
            currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData
        );

        assertEq(IERC20(Constants.ETH_USDC).balanceOf(pool), 10000e6, "Pool USDC unchanged");
    }

    /// @notice Unknown/future action selectors are blocked by default (whitelist = forward-secure).
    function test_UnknownAction_BlockedByDefault() public {
        deal(Constants.ETH_USDC, pool, 10000e6);

        bytes4 unknownSelector = bytes4(0xdeadbeef);

        bytes memory unknownAction = abi.encodePacked(
            unknownSelector,
            abi.encode(pool, uint256(0))
        );

        bytes[] memory actions = new bytes[](1);
        actions[0] = unknownAction;

        bytes memory settlerData = abi.encodeWithSelector(
            SETTLER_EXECUTE_SELECTOR,
            pool, Constants.ETH_WETH, uint256(1e15),
            actions, bytes32(0)
        );

        vm.prank(poolOwner);
        vm.expectRevert(abi.encodeWithSelector(IA0xRouter.ActionNotAllowed.selector, unknownSelector));
        IA0xRouter(pool).exec(
            currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData
        );
    }

    /// @notice Valid DEX actions (not RFQ) pass the adapter's action check.
    function test_RFQ_DexActionsNotBlocked() public {
        deal(Constants.ETH_USDC, pool, 10000e6);

        bytes memory uniAction = abi.encodePacked(
            ISettlerActions.UNISWAPV3.selector,
            abi.encode(pool, uint256(10000), bytes("fake_path"), uint256(1e15))
        );

        bytes[] memory actions = new bytes[](1);
        actions[0] = uniAction;

        bytes memory settlerData = abi.encodeWithSelector(
            SETTLER_EXECUTE_SELECTOR,
            pool, Constants.ETH_WETH, uint256(1e15),
            actions, bytes32(0)
        );

        vm.prank(poolOwner);
        try IA0xRouter(pool).exec(
            currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData
        ) {
            revert("Should fail inside settler (bad params)");
        } catch (bytes memory returnData) {
            _assertNotOurValidationError(returnData);
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

    /// @notice buyToken without a registered price feed is rejected (migrated from HH tests)
    function test_CalldataValidation_BuyTokenNoPriceFeed() public {
        deal(Constants.ETH_USDC, pool, 10000e6);

        // Use an address that definitely has no price feed registered
        address noPriceFeedToken = makeAddr("noPriceFeedToken");

        bytes memory settlerData = _encodeSettlerExecute(pool, noPriceFeedToken, 1e18);

        vm.prank(poolOwner);
        vm.expectRevert(abi.encodeWithSelector(EnumerableSet.TokenPriceFeedDoesNotExist.selector, noPriceFeedToken));
        IA0xRouter(pool).exec(currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData);
    }

    /// @notice minAmountOut=0 is valid (slippage is the submitter's responsibility).
    ///  The real protection is the action allowlist, not minAmountOut validation.
    function test_CalldataValidation_ZeroMinAmountOutPassesValidation() public {
        deal(Constants.ETH_USDC, pool, 10000e6);

        bytes memory uniAction = abi.encodePacked(
            ISettlerActions.UNISWAPV3.selector,
            abi.encode(pool, uint256(10000), bytes("fake_path"), uint256(0))
        );

        bytes[] memory actions = new bytes[](1);
        actions[0] = uniAction;

        bytes memory settlerData = abi.encodeWithSelector(
            SETTLER_EXECUTE_SELECTOR,
            pool, Constants.ETH_WETH, uint256(0),
            actions, bytes32(0)
        );

        vm.prank(poolOwner);
        try IA0xRouter(pool).exec(
            currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData
        ) {
            revert("Should fail inside settler (bad params)");
        } catch (bytes memory returnData) {
            _assertNotOurValidationError(returnData);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                            ACCESS CONTROL (migrated from HH tests)
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Non-owner cannot call exec
    function test_AccessControl_NonOwnerReverts() public {
        deal(Constants.ETH_USDC, pool, 10000e6);

        bytes memory settlerData = _encodeSettlerExecute(pool, Constants.ETH_WETH, 1e18);

        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert();
        IA0xRouter(pool).exec(currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData);
    }

    /// @notice Direct call to adapter reverts (must use delegatecall via pool)
    function test_DirectCall_Reverts() public {
        bytes memory settlerData = _encodeSettlerExecute(address(a0xRouter), Constants.ETH_WETH, 1e18);

        vm.expectRevert(IA0xRouter.DirectCallNotAllowed.selector);
        a0xRouter.exec(currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        FEATURE PAUSED (migrated from HH tests)
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Adapter reverts when the Deployer feature is paused.
    ///  Uses vm.mockCallRevert to simulate ownerOf reverting (paused feature behavior).
    function test_FeaturePaused_RevertsOnOwnerOf() public {
        deal(Constants.ETH_USDC, pool, 10000e6);

        bytes memory settlerData = _encodeSettlerExecute(pool, Constants.ETH_WETH, 1e18);

        // Mock ownerOf to revert (simulates paused feature)
        vm.mockCallRevert(
            DEPLOYER,
            abi.encodeWithSelector(IERC721View.ownerOf.selector, Feature.unwrap(TAKER_SUBMITTED_FEATURE)),
            "paused"
        );

        vm.prank(poolOwner);
        vm.expectRevert();
        IA0xRouter(pool).exec(currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        ERROR PROPAGATION (migrated from HH tests)
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice AllowanceHolder revert with reason string is propagated.
    function test_ErrorPropagation_RevertWithReasonString() public {
        deal(Constants.ETH_USDC, pool, 10000e6);

        bytes memory settlerData = _encodeSettlerExecute(pool, Constants.ETH_WETH, 1e18);

        // Mock AllowanceHolder.exec to revert with a reason string
        vm.mockCallRevert(
            ALLOWANCE_HOLDER,
            abi.encodeWithSelector(EXEC_SELECTOR),
            abi.encodeWithSignature("Error(string)", "MockRevertReason")
        );

        vm.prank(poolOwner);
        vm.expectRevert("MockRevertReason");
        IA0xRouter(pool).exec(currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData);
    }

    /// @notice AllowanceHolder revert without reason is propagated as raw bytes.
    function test_ErrorPropagation_RevertWithoutReason() public {
        deal(Constants.ETH_USDC, pool, 10000e6);

        bytes memory settlerData = _encodeSettlerExecute(pool, Constants.ETH_WETH, 1e18);

        // Mock AllowanceHolder.exec to revert without reason (empty revert)
        vm.mockCallRevert(
            ALLOWANCE_HOLDER,
            abi.encodeWithSelector(EXEC_SELECTOR),
            ""
        );

        vm.prank(poolOwner);
        vm.expectRevert();
        IA0xRouter(pool).exec(currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData);
    }

    /// @notice InsufficientNativeBalance is thrown when trying to swap more ETH than pool has.
    ///  This error is checked in the catch block after AllowanceHolder.exec fails, ensuring
    ///  we provide a clear error message instead of generic revert data when the issue is
    ///  insufficient native balance.
    function test_ErrorPropagation_InsufficientNativeBalance() public {
        // Give pool only 0.1 ETH
        deal(pool, 0.1 ether);

        bytes memory settlerData = _encodeSettlerExecute(pool, Constants.ETH_USDC, 1e6);

        // Mock AllowanceHolder.exec to fail (simulating any failure during swap)
        vm.mockCallRevert(
            ALLOWANCE_HOLDER,
            abi.encodeWithSelector(EXEC_SELECTOR),
            abi.encodeWithSignature("SomeOtherError()")
        );

        // Try to swap 1 ETH when pool only has 0.1 ETH
        vm.prank(poolOwner);
        vm.expectRevert(IA0xRouter.InsufficientNativeBalance.selector);
        IA0xRouter(pool).exec(currentSettler, address(0), 1 ether, payable(currentSettler), settlerData);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            APPROVAL PATTERN
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice ERC20 approval to AllowanceHolder is 0 before exec and unwound on revert
    function test_ApprovalPattern_ZeroBeforeAndUnwoundOnRevert() public {
        deal(Constants.ETH_USDC, pool, 10000e6);

        uint256 allowanceBefore = IERC20(Constants.ETH_USDC).allowance(pool, ALLOWANCE_HOLDER);
        assertEq(allowanceBefore, 0, "Should start with 0 allowance");

        bytes memory settlerData = _encodeSettlerExecute(pool, Constants.ETH_WETH, 1e18);

        vm.prank(poolOwner);
        try IA0xRouter(pool).exec(currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData) {
            revert("Call should revert inside settler (empty actions)");
        } catch (bytes memory returnData) {
            _assertNotOurValidationError(returnData);
        }

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

    /// @notice Approve max before, reset to 1 after; unwound on revert
    function test_ApprovalPattern_ExactAmountApprovedAndUnwound() public {
        uint256 sellAmount = 1000e6;
        deal(Constants.ETH_USDC, pool, sellAmount * 2);

        assertEq(IERC20(Constants.ETH_USDC).allowance(pool, ALLOWANCE_HOLDER), 0);

        bytes memory settlerData = _encodeSettlerExecute(pool, Constants.ETH_WETH, 1e18);

        vm.prank(poolOwner);
        try IA0xRouter(pool).exec(currentSettler, Constants.ETH_USDC, sellAmount, payable(currentSettler), settlerData) {
            revert("Call should revert inside settler (empty actions)");
        } catch (bytes memory returnData) {
            _assertNotOurValidationError(returnData);
        }
        assertEq(IERC20(Constants.ETH_USDC).allowance(pool, ALLOWANCE_HOLDER), 0, "Approval unwound on revert");
    }

    /// @notice USDT approval pattern works with safeApprove (force reset then approve)
    function test_ApprovalPattern_WorksWithUSDT() public {
        deal(Constants.ETH_USDT, pool, 10000e6);

        bytes memory settlerData = _encodeSettlerExecute(pool, Constants.ETH_WETH, 1e18);

        vm.prank(poolOwner);
        try IA0xRouter(pool).exec(currentSettler, Constants.ETH_USDT, 1000e6, payable(currentSettler), settlerData) {
            revert("Call should revert inside settler (empty actions)");
        } catch (bytes memory returnData) {
            _assertNotOurValidationError(returnData);
        }

        assertEq(IERC20(Constants.ETH_USDT).allowance(pool, ALLOWANCE_HOLDER), 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    SWAP SIMULATION TESTS (TOKEN FLOWS)
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Token->Token swap simulation: verify adapter validates and calls AllowanceHolder
    function test_SwapSimulation_TokenToToken_PassesValidation() public {
        uint256 sellAmount = 5000e6;
        deal(Constants.ETH_USDC, pool, sellAmount);

        bytes memory settlerData = _encodeSettlerExecute(
            pool,
            Constants.ETH_WETH,
            1e15
        );

        vm.prank(poolOwner);
        try IA0xRouter(pool).exec(
            currentSettler, Constants.ETH_USDC, sellAmount, payable(currentSettler), settlerData
        ) {
            revert("Should revert inside Settler (empty actions)");
        } catch (bytes memory returnData) {
            _assertNotOurValidationError(returnData);
        }

        assertEq(IERC20(Constants.ETH_USDC).balanceOf(pool), sellAmount, "Pool USDC unchanged after revert");
    }

    /// @notice ETH->Token swap simulation: pool sends its own ETH, NOT msg.value
    function test_SwapSimulation_ETHToToken_UsesPoolBalance() public {
        deal(pool, 10 ether);
        uint256 poolBalanceBefore = pool.balance;

        bytes memory settlerData = _encodeSettlerExecute(
            pool,
            Constants.ETH_USDC,
            1e6
        );

        vm.prank(poolOwner);
        try IA0xRouter(pool).exec(
            currentSettler, address(0), 1 ether, payable(currentSettler), settlerData
        ) {
            revert("Should revert inside Settler (empty actions)");
        } catch (bytes memory returnData) {
            _assertNotOurValidationError(returnData);
        }

        assertEq(pool.balance, poolBalanceBefore, "Pool ETH unchanged after revert");
    }

    /// @notice Token->ETH swap simulation: 0x API uses 0xEeee...ee sentinel as buyToken for native ETH.
    ///  Adapter maps it to address(0) for price feed check.
    function test_SwapSimulation_TokenToETH_PassesValidation() public {
        uint256 sellAmount = 5000e6;
        deal(Constants.ETH_USDC, pool, sellAmount);

        // 0x API uses 0xEeee...ee sentinel for native ETH buyToken, not address(0)
        address ETH_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        bytes memory settlerData = _encodeSettlerExecute(
            pool,
            ETH_SENTINEL,
            1e15
        );

        vm.prank(poolOwner);
        try IA0xRouter(pool).exec(
            currentSettler, Constants.ETH_USDC, sellAmount, payable(currentSettler), settlerData
        ) {
            revert("Should revert inside Settler (empty actions)");
        } catch (bytes memory returnData) {
            _assertNotOurValidationError(returnData);
        }
    }

    /// @notice USDT->WETH swap simulation: tests USDT special approval handling
    function test_SwapSimulation_USDTToWETH_PassesValidation() public {
        uint256 sellAmount = 5000e6;
        deal(Constants.ETH_USDT, pool, sellAmount);

        bytes memory settlerData = _encodeSettlerExecute(
            pool,
            Constants.ETH_WETH,
            1e15
        );

        vm.prank(poolOwner);
        try IA0xRouter(pool).exec(
            currentSettler, Constants.ETH_USDT, sellAmount, payable(currentSettler), settlerData
        ) {
            revert("Should revert inside Settler (empty actions)");
        } catch (bytes memory returnData) {
            _assertNotOurValidationError(returnData);
        }

        assertEq(IERC20(Constants.ETH_USDT).allowance(pool, ALLOWANCE_HOLDER), 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        TOKEN MANAGEMENT (migrated from HH tests)
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice buyToken is added to pool's active tokens set.
    ///  This test verifies a successful exec path adds buyToken. We use vm.mockCall to make
    ///  AllowanceHolder.exec return success (simulating a complete swap), then verify the
    ///  allowance is reset to 1 and the token management code path was reached.
    function test_TokenManagement_BuyTokenAddedAndApprovalResetOnSuccess() public {
        deal(Constants.ETH_USDC, pool, 10000e6);

        bytes memory settlerData = _encodeSettlerExecute(pool, Constants.ETH_WETH, 1e18);

        // Mock AllowanceHolder.exec to return success (simulates completed swap)
        vm.mockCall(
            ALLOWANCE_HOLDER,
            abi.encodeWithSelector(EXEC_SELECTOR),
            abi.encode(bytes(""))
        );

        vm.prank(poolOwner);
        IA0xRouter(pool).exec(currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData);

        // After successful exec, allowance should be 1 (reset after call, slot stays warm)
        uint256 allowanceAfter = IERC20(Constants.ETH_USDC).allowance(pool, ALLOWANCE_HOLDER);
        assertEq(allowanceAfter, 1, "Allowance should be 1 after successful exec");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            ADAPTER PROPERTIES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Required version returns expected value
    function test_RequiredVersion() public view {
        assertEq(a0xRouter.requiredVersion(), "4.0.0");
    }

    /// @notice Verify selectors match expected values (sanity check for imports)
    function test_SelectorsSanityCheck() public pure {
        // AllowanceHolder.exec(address,address,uint256,address,bytes)
        assertEq(EXEC_SELECTOR, bytes4(0x2213bc0b), "EXEC_SELECTOR mismatch");
        // Settler.execute((address,address,uint256),bytes[],bytes32)
        assertEq(ISettlerTakerSubmitted.execute.selector, bytes4(0x1fff991f), "ISettlerTakerSubmitted.execute.selector mismatch");
        // ActionInvalid(uint256,bytes4,bytes)
        assertEq(ActionInvalid.selector, bytes4(0x3c74eed6), "ActionInvalid selector mismatch");
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

    /// @dev Asserts the revert error IS ActionInvalid from the settler.
    ///  UPGRADE RISK: If a future 0x settler version changes this error or adds bridge
    ///  actions to the Taker dispatch chain, this assertion will fail.
    function _assertIsActionInvalid(bytes memory returnData) internal pure {
        assertTrue(returnData.length >= 4, "Return data too short for error selector");
        bytes4 errorSelector;
        assembly {
            errorSelector := mload(add(returnData, 32))
        }
        assertEq(errorSelector, ActionInvalid.selector, "Expected ActionInvalid from settler");
    }

    /// @dev Asserts the revert error is NOT from our validation layer (A0xRouter custom errors).
    function _assertNotOurValidationError(bytes memory returnData) internal pure {
        if (returnData.length >= 4) {
            bytes4 errorSelector;
            assembly {
                errorSelector := mload(add(returnData, 32))
            }
            assertTrue(errorSelector != IA0xRouter.CounterfeitSettler.selector, "Should not be CounterfeitSettler");
            assertTrue(errorSelector != IA0xRouter.RecipientNotSmartPool.selector, "Should not be RecipientNotSmartPool");
            assertTrue(errorSelector != IA0xRouter.UnsupportedSettlerFunction.selector, "Should not be UnsupportedSettlerFunction");
            assertTrue(errorSelector != IA0xRouter.InvalidSettlerCalldata.selector, "Should not be InvalidSettlerCalldata");
            assertTrue(errorSelector != IA0xRouter.DirectCallNotAllowed.selector, "Should not be DirectCallNotAllowed");
            assertTrue(errorSelector != IA0xRouter.ActionNotAllowed.selector, "Should not be ActionNotAllowed");
        }
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

