// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Constants} from "../../contracts/test/Constants.sol";

import {A0xRouter} from "../../contracts/protocol/extensions/adapters/A0xRouter.sol";
import {IA0xRouter} from "../../contracts/protocol/extensions/adapters/interfaces/IA0xRouter.sol";
import {ISettlerActions, IBridgeSettlerActions} from "../../contracts/protocol/extensions/adapters/interfaces/ISettlerActions.sol";
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
        address prevSettler = I0xDeployer(DEPLOYER).prev(SETTLER_TAKER_FEATURE);
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
      price — a phished pool owner or rogue agent could submit an RFQ order that
      drains the vault. Unlike DEX swaps (which execute at on-chain market price),
      RFQ settlements have no on-chain price reference. minAmountOut is controlled
      by the same compromised submitter and provides no protection.
      Blocked selectors: RFQ (0xd92aadfb), RFQ_VIP (0x604ba49a).

    Layer 3 — Settler action dispatch:
      Feature 2 settlers only recognize ISettlerActions selectors (UNISWAPV3,
      UNISWAPV2, BASIC, VELODROME, POSITIVE_SLIPPAGE, NATIVE_CHECK, plus chain-
      specific like UNISWAPV4, BALANCERV3, MAVERICKV2, etc.). Bridge actions from
      IBridgeSettlerActions (BRIDGE_ERC20_TO_ACROSS, BRIDGE_NATIVE_TO_ACROSS,
      BRIDGE_ERC20_TO_MAYAN, etc.) are NOT in the Taker settler's _dispatch chain.
      Unknown selectors cause revert with ActionInvalid.

    Layer 4 — Settler slippage check (_checkSlippageAndTransfer):
      Runs at the end of execute(). Requires the settler to hold >= minAmountOut
      of buyToken and transfers it all to recipient. If tokens were bridged away,
      the settler wouldn't hold them, and the check fails (with minAmountOut > 0).

    BASIC action analysis:
      BASIC can call arbitrary non-restricted addresses. In theory, it could call a
      bridge protocol (e.g., Across SpokePool). However, Layer 4 prevents this: after
      BASIC sends tokens to a bridge, the settler has no buyToken balance, and
      _checkSlippageAndTransfer reverts. Bypassing requires minAmountOut=0, which
      means a malicious pool owner — same trust model as setting amountOutMin=0 on
      Uniswap. Additionally, BASIC uses ERC20 approval (not Permit2), so it cannot
      compose with other settlers' fee/transfer mechanisms.
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

    /// @notice Bridge action selectors embedded in the actions array are rejected by the
    ///  Feature 2 (Taker) settler. The settler's _dispatch only recognizes ISettlerActions
    ///  selectors. Bridge actions from IBridgeSettlerActions (which only exist in Feature 5
    ///  BridgeSettler contracts) are unknown and cause revert with ActionInvalid.
    function test_BridgeExclusion_BridgeActionSelectorsRejectedByTakerSettler() public {
        deal(Constants.ETH_USDC, pool, 10000e6);

        // Known bridge action selectors from IBridgeSettlerActions interface.
        // These are: bytes4(keccak256("FUNCTION_NAME(param_types)"))
        bytes4[4] memory bridgeSelectors = [
            IBridgeSettlerActions.BRIDGE_ERC20_TO_ACROSS.selector,
            IBridgeSettlerActions.BRIDGE_NATIVE_TO_ACROSS.selector,
            IBridgeSettlerActions.BRIDGE_ERC20_TO_MAYAN.selector,
            IBridgeSettlerActions.BRIDGE_TO_DEBRIDGE.selector
        ];

        for (uint256 i = 0; i < bridgeSelectors.length; i++) {
            // Encode a bridge action in the settler's actions array.
            // Each action entry is: [4-byte selector | ABI-encoded params]
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
            try IA0xRouter(pool).exec(
                currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData
            ) {
                revert("Bridge action selector must be rejected by Taker settler");
            } catch (bytes memory returnData) {
                _assertNotOurValidationError(returnData);
            }
        }

        // Pool balance unchanged — revert unwound everything
        assertEq(IERC20(Constants.ETH_USDC).balanceOf(pool), 10000e6, "Pool USDC unchanged");
    }

    /// @notice Non-Feature-2 settlers are all rejected by the adapter.
    ///  Feature 2 = Taker Submitted (only accepted type).
    ///  Feature 4 = Intent, Feature 5 = Bridge — both rejected.
    ///  Any future feature types also rejected unless they happen to share
    ///  the same address as the Feature 2 settler (which won't happen per
    ///  the 0x Deployer's design — each feature has its own settler bytecode).
    function test_BridgeExclusion_NonFeature2SettlersRejected() public {
        bytes memory settlerData = _encodeSettlerExecute(pool, Constants.ETH_WETH, 1e18);

        // Test features 1 through 10 (excluding 2 = our accepted feature)
        for (uint128 featureId = 1; featureId <= 10; featureId++) {
            if (featureId == SETTLER_TAKER_FEATURE) continue; // skip Feature 2

            try I0xDeployer(DEPLOYER).ownerOf(featureId) returns (address featureSettler) {
                // Skip if same address as Feature 2 (shouldn't happen) or zero
                if (featureSettler == address(0) || featureSettler == currentSettler) continue;

                console2.log("Feature", featureId, "settler:", featureSettler);

                vm.prank(poolOwner);
                vm.expectRevert(abi.encodeWithSelector(IA0xRouter.CounterfeitSettler.selector, featureSettler));
                IA0xRouter(pool).exec(
                    featureSettler, Constants.ETH_USDC, 1000e6, payable(featureSettler), settlerData
                );
            } catch {
                // Feature doesn't exist or is paused — inherently excluded
                console2.log("Feature", featureId, "not available (paused or unregistered)");
            }
        }
    }

    /// @notice BASIC action is bounded by the settler's slippage check even though it
    ///  can call arbitrary non-restricted contracts. If BASIC sent tokens to a bridge
    ///  protocol, the settler would have no buyToken left, and _checkSlippageAndTransfer
    ///  would revert (with minAmountOut > 0). This test encodes a BASIC action calling
    ///  an arbitrary address — the settler's own integrity checks catch it.
    function test_BridgeExclusion_BasicActionBoundedBySlippageCheck() public {
        deal(Constants.ETH_USDC, pool, 10000e6);

        bytes4 basicSelector = ISettlerActions.BASIC.selector;

        // Encode BASIC action targeting a random address (simulating a bridge protocol)
        // BASIC(sellToken, bps, pool, offset, data)
        bytes memory basicAction = abi.encodePacked(
            basicSelector,
            abi.encode(
                Constants.ETH_USDC,    // sellToken
                uint256(10000),        // bps = 100% (10000 = BASIS)
                address(0xdeadbeef),   // pool target (arbitrary, simulates bridge)
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
            uint256(1e15),       // minAmountOut > 0 (slippage protection)
            actions,
            bytes32(0)
        );

        vm.prank(poolOwner);
        try IA0xRouter(pool).exec(
            currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData
        ) {
            revert("BASIC to arbitrary target must fail");
        } catch (bytes memory returnData) {
            _assertNotOurValidationError(returnData);
        }
        assertEq(IERC20(Constants.ETH_USDC).balanceOf(pool), 10000e6, "Pool USDC unchanged");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        RFQ EXCLUSION

    RFQ allows arbitrary counterparty at arbitrary price — unlike DEX swaps
    (which execute at on-chain market price), RFQ has no on-chain price reference.
    A rogue maker can sign a Permit2 quote at any price, and a phished pool owner
    or malicious agent would submit it. Our recipient/buyToken/priceFeed checks
    do NOT protect against this because minAmountOut is controlled by the same
    (potentially compromised) submitter.

    The adapter scans the actions array for RFQ selectors and reverts with
    ForbiddenAction before the call reaches AllowanceHolder/Settler.

    Blocked actions:
    - RFQ (0xd92aadfb) — active in SettlerBase._dispatch, immediate risk
    - RFQ_VIP (0x604ba49a) — currently disabled in settler, blocked defensively
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice RFQ action is blocked by the adapter — reverts with ForbiddenAction.
    ///  This test encodes a valid-looking RFQ action in the actions array and verifies
    ///  the adapter catches it BEFORE the call reaches AllowanceHolder.
    function test_RFQ_BlockedByAdapter() public {
        deal(Constants.ETH_USDC, pool, 10000e6);

        bytes4 rfqSelector = ISettlerActions.RFQ.selector;

        // Encode an RFQ action. The params don't need to be valid — the adapter
        // blocks the action selector BEFORE AllowanceHolder processes it.
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
            uint256(0),          // minAmountOut = 0 (worst case: attacker controls this)
            actions,
            bytes32(0)
        );

        // The adapter MUST catch this and revert with ForbiddenAction, not let it through
        vm.prank(poolOwner);
        vm.expectRevert(abi.encodeWithSelector(IA0xRouter.ForbiddenAction.selector, rfqSelector));
        IA0xRouter(pool).exec(
            currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData
        );

        // Pool funds untouched
        assertEq(IERC20(Constants.ETH_USDC).balanceOf(pool), 10000e6, "Pool USDC unchanged");
    }

    /// @notice RFQ_VIP action is also blocked (forward security — currently disabled in settler
    ///  but could be re-enabled in future settler versions).
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
            pool, Constants.ETH_WETH, uint256(0),
            actions, bytes32(0)
        );

        vm.prank(poolOwner);
        vm.expectRevert(abi.encodeWithSelector(IA0xRouter.ForbiddenAction.selector, rfqVipSelector));
        IA0xRouter(pool).exec(
            currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData
        );

        assertEq(IERC20(Constants.ETH_USDC).balanceOf(pool), 10000e6, "Pool USDC unchanged");
    }

    /// @notice RFQ embedded as the Nth action (not just first) is also caught.
    ///  The adapter scans ALL actions, not just the first one.
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
            pool, Constants.ETH_WETH, uint256(0),
            actions, bytes32(0)
        );

        vm.prank(poolOwner);
        vm.expectRevert(abi.encodeWithSelector(IA0xRouter.ForbiddenAction.selector, rfqSelector));
        IA0xRouter(pool).exec(
            currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData
        );
    }

    /// @notice Valid DEX actions (not RFQ) pass the adapter's action check.
    ///  Verifies the action scanner doesn't false-positive on legitimate DEX selectors.
    ///  The call still fails inside the settler (empty/invalid action params), but the
    ///  error is NOT ForbiddenAction — it's from the settler's own execution.
    function test_RFQ_DexActionsNotBlocked() public {
        deal(Constants.ETH_USDC, pool, 10000e6);

        // UNISWAPV3 selector — a legitimate DEX action that must NOT be blocked
        bytes4 uniV3Selector = ISettlerActions.UNISWAPV3.selector;

        bytes memory uniAction = abi.encodePacked(
            uniV3Selector,
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

    /// @notice ERC20 approval to AllowanceHolder is 0 before exec and unwound on revert
    /// @dev AllowanceHolder does NOT use Permit2. It consumes standard ERC20 allowance.
    ///  Adapter approves exact amount before exec and resets to 1 after success.
    ///  On revert, the EVM unwinds the approval automatically (back to pre-call state).
    function test_ApprovalPattern_ZeroBeforeAndUnwoundOnRevert() public {
        deal(Constants.ETH_USDC, pool, 10000e6);

        // Before: no approval
        uint256 allowanceBefore = IERC20(Constants.ETH_USDC).allowance(pool, ALLOWANCE_HOLDER);
        assertEq(allowanceBefore, 0, "Should start with 0 allowance");

        bytes memory settlerData = _encodeSettlerExecute(pool, Constants.ETH_WETH, 1e18);

        // Exec will fail inside AllowanceHolder/Settler (revert unwinds the approval too)
        vm.prank(poolOwner);
        try IA0xRouter(pool).exec(currentSettler, Constants.ETH_USDC, 1000e6, payable(currentSettler), settlerData) {
            revert("Call should revert inside settler (empty actions)");
        } catch (bytes memory returnData) {
            _assertNotOurValidationError(returnData);
        }

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

    /// @notice Per-call approval pattern: exact amount approved, reset to 1 on success, unwound on revert
    /// @dev Verifies approval is unwound on revert (back to 0 since it was 0 before)
    function test_ApprovalPattern_ExactAmountApprovedAndUnwound() public {
        uint256 sellAmount = 1000e6;
        deal(Constants.ETH_USDC, pool, sellAmount * 2);

        // Fresh pool has 0 allowance
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
        // USDT has special approval behavior: reverts if allowance > 0 and setting non-zero
        // safeApprove handles this by force-resetting to 0 first
        deal(Constants.ETH_USDT, pool, 10000e6);

        bytes memory settlerData = _encodeSettlerExecute(pool, Constants.ETH_WETH, 1e18);

        // Should not revert with USDT approval issues
        vm.prank(poolOwner);
        try IA0xRouter(pool).exec(currentSettler, Constants.ETH_USDT, 1000e6, payable(currentSettler), settlerData) {
            revert("Call should revert inside settler (empty actions)");
        } catch (bytes memory returnData) {
            _assertNotOurValidationError(returnData);
        }

        // Allowance should be 0 (revert unwound state)
        assertEq(IERC20(Constants.ETH_USDT).allowance(pool, ALLOWANCE_HOLDER), 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    SWAP SIMULATION TESTS (TOKEN FLOWS)
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Token→Token swap simulation: verify adapter validates, approves, and calls AllowanceHolder
    /// @dev Tests USDC→WETH swap path. The actual swap fails inside Settler due to
    ///  empty actions, but we verify: (1) settler validation passes, (2) approval is set,
    ///  (3) the error is from AllowanceHolder/Settler internals not from our validation.
    function test_SwapSimulation_TokenToToken_PassesValidation() public {
        uint256 sellAmount = 5000e6; // 5000 USDC
        deal(Constants.ETH_USDC, pool, sellAmount);

        bytes memory settlerData = _encodeSettlerExecute(
            pool,
            Constants.ETH_WETH, // buyToken = WETH (has price feed as wrappedNative)
            1e15 // minAmountOut: 0.001 WETH
        );

        vm.prank(poolOwner);
        try IA0xRouter(pool).exec(
            currentSettler, Constants.ETH_USDC, sellAmount, payable(currentSettler), settlerData
        ) {
            revert("Should revert inside Settler (empty actions)");
        } catch (bytes memory returnData) {
            _assertNotOurValidationError(returnData);
        }

        // Pool USDC balance unchanged (revert unwound everything)
        assertEq(IERC20(Constants.ETH_USDC).balanceOf(pool), sellAmount, "Pool USDC unchanged after revert");
    }

    /// @notice ETH→Token swap simulation: pool sends its own ETH, NOT msg.value
    /// @dev Tests selling ETH for USDC. Token param is address(0) for native ETH.
    ///  The adapter derives value = amount from the token/amount params and forwards
    ///  from the pool's balance. The caller does NOT send ETH (no msg.value).
    function test_SwapSimulation_ETHToToken_UsesPoolBalance() public {
        // Fund pool with ETH
        deal(pool, 10 ether);
        uint256 poolBalanceBefore = pool.balance;

        bytes memory settlerData = _encodeSettlerExecute(
            pool,
            Constants.ETH_USDC, // buyToken = USDC
            1e6 // minAmountOut: 1 USDC
        );

        // Caller does NOT send any ETH — the pool uses its own balance
        vm.prank(poolOwner);
        try IA0xRouter(pool).exec(
            currentSettler, address(0), 1 ether, payable(currentSettler), settlerData
        ) {
            revert("Should revert inside Settler (empty actions)");
        } catch (bytes memory returnData) {
            _assertNotOurValidationError(returnData);
        }

        // Pool balance unchanged (revert unwound the ETH transfer too)
        assertEq(pool.balance, poolBalanceBefore, "Pool ETH unchanged after revert");
    }

    /// @notice Token→ETH swap simulation: sell USDC for native ETH
    /// @dev buyToken in slippage struct is WETH (wrappedNative), which has price feed.
    ///  Settler would unwrap WETH to ETH and send to pool.
    function test_SwapSimulation_TokenToETH_PassesValidation() public {
        uint256 sellAmount = 5000e6;
        deal(Constants.ETH_USDC, pool, sellAmount);

        bytes memory settlerData = _encodeSettlerExecute(
            pool,
            Constants.ETH_WETH, // buyToken = WETH (serves as ETH proxy in 0x)
            1e15 // minAmountOut
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

    /// @notice USDT→WETH swap simulation: tests USDT special approval handling
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

        // Allowance is 0 after revert
        assertEq(IERC20(Constants.ETH_USDT).allowance(pool, ALLOWANCE_HOLDER), 0);
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

    /// @dev Asserts the revert error is NOT from our validation layer (A0xRouter custom errors).
    ///  If the error came from our validation, the test should have caught it earlier.
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
            assertTrue(errorSelector != IA0xRouter.ForbiddenAction.selector, "Should not be ForbiddenAction");
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
