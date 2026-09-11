// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {HyperliquidDeploymentFixture} from "../fixtures/HyperliquidDeploymentFixture.sol";
import {IAHyperliquid} from "../../contracts/protocol/extensions/adapters/interfaces/IAHyperliquid.sol";
import {HLConstants} from "hyper-evm-lib/common/HLConstants.sol";
import {CoreWriterLib} from "hyper-evm-lib/CoreWriterLib.sol";
import {PrecompileLib} from "hyper-evm-lib/PrecompileLib.sol";
import {IEApps} from "../../contracts/protocol/extensions/adapters/interfaces/IEApps.sol";
import {IEOracle} from "../../contracts/protocol/extensions/adapters/interfaces/IEOracle.sol";
import {IECrosschain} from "../../contracts/protocol/extensions/adapters/interfaces/IECrosschain.sol";
import {IENavView} from "../../contracts/protocol/extensions/adapters/interfaces/IENavView.sol";
import {DestinationMessageParams, OpType} from "../../contracts/protocol/types/Crosschain.sol";
import {CrosschainLib} from "../../contracts/protocol/libraries/CrosschainLib.sol";
import {VirtualStorageLib} from "../../contracts/protocol/libraries/VirtualStorageLib.sol";
import {ExternalApp} from "../../contracts/protocol/types/ExternalApp.sol";
import {Applications} from "../../contracts/protocol/types/Applications.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {ISmartPoolOwnerActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolOwnerActions.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {IERC20 as IForgeERC20} from "@forge-std/interfaces/IERC20.sol";
import {NavView} from "../../contracts/protocol/libraries/NavView.sol";
import {NetAssetsValue} from "../../contracts/protocol/types/NavComponents.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {AUniswap} from "../../contracts/protocol/extensions/adapters/AUniswap.sol";
import {AUniswapRouter} from "../../contracts/protocol/extensions/adapters/AUniswapRouter.sol";
import {A0xRouter} from "../../contracts/protocol/extensions/adapters/A0xRouter.sol";
import {AGmxV2} from "../../contracts/protocol/extensions/adapters/AGmxV2.sol";
import {IAGmxV2} from "../../contracts/protocol/extensions/adapters/interfaces/IAGmxV2.sol";
import {IAUniswap} from "../../contracts/protocol/extensions/adapters/interfaces/IAUniswap.sol";
import {IA0xRouter} from "../../contracts/protocol/extensions/adapters/interfaces/IA0xRouter.sol";
import {IAStaking} from "../../contracts/protocol/extensions/adapters/interfaces/IAStaking.sol";
import {IAGovernance} from "../../contracts/protocol/extensions/adapters/interfaces/IAGovernance.sol";
import {IAuthority} from "../../contracts/protocol/interfaces/IAuthority.sol";
import {IOwnedUninitialized} from "../../contracts/utils/owned/IOwnedUninitialized.sol";
import {IRigoblockGovernance} from "../../contracts/governance/IRigoblockGovernance.sol";

import {ISettlerBase} from "0x-settler/src/interfaces/ISettlerBase.sol";
import {ISettlerTakerSubmitted} from "0x-settler/src/interfaces/ISettlerTakerSubmitted.sol";
import {ISettlerActions} from "0x-settler/src/ISettlerActions.sol";
import {IAllowanceHolder} from "0x-settler/src/allowanceholder/IAllowanceHolder.sol";
import {IDeployer} from "0x-settler/src/deployer/IDeployer.sol";
import {Feature} from "0x-settler/src/deployer/Feature.sol";

/// @dev Local copies of error selectors so we do not need to import the implementation.
error BaseTokenPriceFeedError();
error TokenPriceFeedDoesNotExist(address token);
error NavLocked();

/// @title AHyperliquidForkTest
/// @notice HyperEVM fork tests for the Hyperliquid adapter.
/// @dev Requires HYPERLIQUID_RPC_URL in .env / foundry.toml.
contract AHyperliquidForkTest is Test {
    HyperliquidDeploymentFixture public fixture;

    address public pool;
    address public poolOwner;
    address public aHyperliquid;
    address public usdc;

    // Current value mocked for the HyperCore L1 block number precompile. In-flight tracking and the
    // settlement lock are keyed to the L1 block: HyperEVM only learns about HyperCore state changes
    // when the L1 block advances, so tests advance this value to simulate a new HyperCore block.
    uint64 internal _l1Block;

    /// @notice Hyperliquid read precompiles are mocked because Foundry's EVM does not implement
    ///  the HyperCore precompiles, even when forking a HyperEVM RPC. The mocks simulate whatever
    ///  state the test needs to exercise a code path; they are a test limitation, not a claim
    ///  about how quickly HyperCore state becomes observable in production.
    /// @dev CoreWriter itself is not mocked; it emits the action log. Only the read-only precompile
    ///  return data is mocked so that pool queries can return plausible values on the fork.

    function setUp() public {
        fixture = new HyperliquidDeploymentFixture();
        fixture.deployFixture();

        pool = fixture.pool();
        poolOwner = fixture.poolOwner();
        aHyperliquid = fixture.aHyperliquid();
        usdc = fixture.HYPER_USDC();

        // Foundry does not implement HyperCore read precompiles, so mock the USDC tokenInfo
        // precompile that CoreWriterLib queries while converting deposit amounts.
        _mockUsdcTokenInfo();

        // Mock the L1 block number precompile used for L1-keyed in-flight tracking.
        _l1Block = uint64(block.number);
        _mockL1BlockNumber(_l1Block);

        console2.log("Pool:", pool);
        console2.log("Pool owner:", poolOwner);
        console2.log("Pool USDC balance:", IERC20(usdc).balanceOf(pool));
    }

    /// @notice Smoke test: the adapter is deployed, authorized, and the pool is funded.
    function testFork_AdapterAndPoolDeployed() public view {
        assertEq(block.chainid, fixture.HYPEREVM_CHAIN_ID(), "Should be on HyperEVM fork");
        assertTrue(aHyperliquid.code.length > 0, "AHyperliquid should be deployed");
        assertTrue(pool.code.length > 0, "Pool should be deployed");
        assertGt(IERC20(usdc).balanceOf(pool), 0, "Pool should hold USDC");
    }

    /// @notice Deposit USDC to HyperCore via the real CoreDepositWallet.
    function testFork_DepositToCore() public {
        uint256 depositAmount = 10_000e6;
        uint256 poolUsdcBefore = IERC20(usdc).balanceOf(pool);

        vm.prank(poolOwner);
        IAHyperliquid(pool).deposit(depositAmount, HLConstants.DEFAULT_PERP_DEX);

        uint256 poolUsdcAfter = IERC20(usdc).balanceOf(pool);
        assertEq(poolUsdcBefore - poolUsdcAfter, depositAmount, "Pool USDC should decrease by deposit");

        // The Hyperliquid application bit must have been activated by the deposit.
        uint256 activeApps = ISmartPoolState(pool).getActiveApplications();
        assertTrue((activeApps & (1 << uint256(Applications.HYPERLIQUID))) != 0, "HYPERLIQUID should be active");
    }

    /// @notice Mocks the Hyperliquid account margin summary precompile to return `accountValue` for dex 0.
    function _mockAccountMarginSummary(int64 accountValue) internal {
        vm.mockCall(
            _ACCOUNT_MARGIN_SUMMARY,
            abi.encode(uint32(0), pool),
            abi.encode(
                PrecompileLib.AccountMarginSummary({accountValue: accountValue, marginUsed: 0, ntlPos: 0, rawUsd: 0})
            )
        );
    }

    /// @notice NAV read does not revert after the Hyperliquid settlement window elapses.
    /// @dev The test mocks the HyperCore account-value precompile because Foundry's EVM does not
    ///  implement it. The mock represents a later state in which the deposit is observable, without
    ///  asserting anything about production settlement timing.
    function testFork_NavAfterDeposit() public {
        // Establish a baseline NAV before any Hyperliquid action.
        NetAssetsValue memory navBefore = ISmartPoolActions(pool).updateUnitaryValue();
        assertGt(navBefore.unitaryValue, 0, "Baseline unitary value should be positive");

        uint256 depositAmount = 10_000e6;
        vm.prank(poolOwner);
        IAHyperliquid(pool).deposit(depositAmount, HLConstants.DEFAULT_PERP_DEX);

        // Mock the precompile to simulate a state where the deposit is observable in HyperCore.
        _mockAccountMarginSummary(int64(uint64(depositAmount)));
        _mockSpotBalance(pool, 0, 0);
        _mockUsdcTokenInfo();

        // Warp past the settlement window and advance the L1 block so the in-flight amount is dropped.
        vm.warp(block.timestamp + 17 seconds);
        _advanceL1Block();

        NetAssetsValue memory nav = ISmartPoolActions(pool).updateUnitaryValue();
        assertEq(nav.unitaryValue, navBefore.unitaryValue, "Unitary value should be unchanged after deposit settles");

        // Advance the L1 block again and mock the precompile to exercise a subsequent NAV read.
        _advanceL1Block();
        _mockAccountMarginSummary(int64(uint64(depositAmount)));
        NetAssetsValue memory nextNav = ISmartPoolActions(pool).updateUnitaryValue();
        assertEq(nextNav.unitaryValue, nav.unitaryValue, "Subsequent NAV read should match settled value");
    }

    /// @notice Within the same EVM block as the deposit, the in-flight amount is added to the lagging
    ///  HyperCore balance, so balance reads stay self-consistent without waiting. From the next EVM
    ///  block on, the in-flight amount is dropped (HyperCore processes the transfer right after each
    ///  EVM block is built, so the precompile is expected to reflect the deposit by then): the EApps
    ///  balance view is settlement-locked, while the unguarded NavView reader reports the raw
    ///  precompile value.
    /// @dev Because Foundry does not implement HyperCore read precompiles, the test explicitly supplies
    ///  both a lagging value and a caught-up value. This proves the in-flight adjustment covers the
    ///  gap within the deposit block and is dropped afterwards.
    function testFork_InFlightBalanceDuringGap() public {
        uint256 depositAmount = 10_000e6;

        NavView.NavData memory navBefore = IENavView(pool).getNavDataView();

        vm.prank(poolOwner);
        IAHyperliquid(pool).deposit(depositAmount, HLConstants.DEFAULT_PERP_DEX);

        // Same block: simulate the HyperCore precompile not yet reflecting the deposit.
        _mockAccountMarginSummary(0);
        _mockSpotBalance(pool, 0, 0);
        _mockCoreUserExists(pool, true);
        _mockUsdcTokenInfo();

        // The balance query succeeds and the in-flight amount covers the lagging Core state.
        // GRG_STAKING is always queried, so find the Hyperliquid entry by app type.
        ExternalApp[] memory apps = IEApps(pool).getAppTokenBalances(1 << uint256(Applications.HYPERLIQUID));
        ExternalApp memory hyperliquidApp = _findHyperliquidApp(apps);
        assertEq(hyperliquidApp.balances.length, 1, "Hyperliquid app should report one balance");
        assertEq(hyperliquidApp.balances[0].token, usdc, "Balance token should be USDC");
        assertEq(hyperliquidApp.balances[0].amount, int256(depositAmount), "In-flight amount should cover the deposit");

        // The next EVM block (same L1 block): the EApps balance view is settlement-locked, while the
        // unguarded NavView reader no longer adds the in-flight amount.
        vm.roll(block.number + 1);
        vm.expectRevert(NavLocked.selector);
        IEApps(pool).getAppTokenBalances(1 << uint256(Applications.HYPERLIQUID));

        // The precompile has caught up by the next EVM block: the NavView read reports the same
        // total value as before the deposit (no double-counted in-flight amount).
        _mockAccountMarginSummary(int64(uint64(depositAmount)));
        NavView.NavData memory navData = IENavView(pool).getNavDataView();
        assertEq(navData.totalValue, navBefore.totalValue, "Total value must not change once Core has caught up");

        // Warp past the settlement window and advance the L1 block: the EApps view works again.
        vm.warp(block.timestamp + 17 seconds);
        _advanceL1Block();

        apps = IEApps(pool).getAppTokenBalances(1 << uint256(Applications.HYPERLIQUID));
        hyperliquidApp = _findHyperliquidApp(apps);
        assertEq(hyperliquidApp.balances[0].amount, int256(depositAmount), "Balance should equal precompile value");
    }

    /// @dev GRG_STAKING is always queried alongside the requested applications, so the Hyperliquid
    ///  entry is located by app type rather than by array index.
    function _findHyperliquidApp(ExternalApp[] memory apps) private pure returns (ExternalApp memory hyperliquidApp) {
        for (uint256 i = 0; i < apps.length; i++) {
            if (apps[i].appType == uint256(Applications.HYPERLIQUID)) {
                return apps[i];
            }
        }
        revert("Hyperliquid application should be returned");
    }

    /// @notice EOracle on HyperEVM must only recognize USDC as having a price feed.
    function testFork_EOracle_OnlyUsdcHasPriceFeed() public view {
        assertTrue(IEOracle(pool).hasPriceFeed(usdc), "USDC must have a price feed");
        assertFalse(IEOracle(pool).hasPriceFeed(fixture.HYPER_WHYPE()), "WHYPE must not have a price feed");
        assertFalse(IEOracle(pool).hasPriceFeed(address(0)), "Native currency must not have a price feed");
    }

    /// @notice A pool created with a non-USDC base token must revert on NAV update.
    function testFork_NonUsdcBasePool_RevertsOnNavUpdate() public {
        vm.prank(poolOwner);
        (address whypePool, ) = IRigoblockPoolProxyFactory(fixture.factory()).createPool(
            "WHYPE Pool",
            "WHYPE",
            fixture.HYPER_WHYPE()
        );

        vm.expectRevert(BaseTokenPriceFeedError.selector);
        ISmartPoolActions(whypePool).updateUnitaryValue();
    }

    /// @notice Non-USDC tokens cannot be accepted as mint tokens.
    function testFork_NonUsdcToken_CannotBeAcceptedAsMintToken() public {
        address whype = fixture.HYPER_WHYPE();

        vm.prank(poolOwner);
        vm.expectRevert(abi.encodeWithSelector(TokenPriceFeedDoesNotExist.selector, whype));
        ISmartPoolOwnerActions(pool).setAcceptableMintToken(whype, true);
    }

    /// @notice ECrosschain.donate rejects non-USDC tokens on HyperEVM in the two-phase finalize call.
    /// @dev A cross-chain message delivering WHYPE to the pool would fail at the
    ///  `isAllowedCrosschainToken` gate; no application or active-token storage is mutated.
    function testFork_ECrosschain_Donate_NonUsdcToken_Reverts() public {
        address whype = fixture.HYPER_WHYPE();
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });

        // Phase 1: lock the (zero) WHYPE balance. This call is chain-agnostic.
        IECrosschain(pool).donate(whype, 1, params);

        // Simulate the bridge delivering WHYPE to the pool.
        uint256 bridgeAmount = 1 ether;
        deal(whype, pool, bridgeAmount);

        // Phase 2: attempt to finalize the donation. Only USDC is allowed on HyperEVM.
        vm.expectRevert(CrosschainLib.UnsupportedCrossChainToken.selector);
        IECrosschain(pool).donate(whype, bridgeAmount, params);
    }

    /// @notice Regression: the production cross-chain path on HyperEVM (a USDC donation) finalizes.
    /// @dev EOracle.convertTokenAmount used to fetch the target TWAP before the identity
    ///  short-circuit, so USDC->USDC on HyperEVM (oracle hook = address(0)) reverted and bricked
    ///  every cross-chain transfer into USDC-denominated pools on HyperEVM.
    /// @dev Uses a fresh pool so the NAV stored at lock equals the default 10^decimals: a USDC
    ///  donation must then mint exactly `amount` of virtual supply.
    function testFork_ECrosschain_DonateUsdc_Transfer_Succeeds() public {
        vm.prank(poolOwner);
        (address freshPool, ) = IRigoblockPoolProxyFactory(fixture.factory()).createPool("USDC Fresh", "FUSDC", usdc);

        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        uint256 amount = 100_000e6;

        // The NAV stored by the lock phase determines the share calculation in _updateVirtualSupply:
        // mintedAmount = amountValueInBase * 10^decimals / storedNav. Read it upfront to assert the
        // exact expected virtual supply increase.
        uint256 storedNav = ISmartPoolActions(freshPool).updateUnitaryValue().unitaryValue;
        uint8 decimals = ISmartPoolState(freshPool).getPool().decimals;
        uint256 expectedDelta = (amount * 10 ** decimals) / storedNav;
        assertEq(expectedDelta, amount, "At default NAV the virtual supply delta must equal the USDC amount");

        // Phase 1: lock the current USDC balance.
        IECrosschain(freshPool).donate(usdc, 1, params);

        // Simulate the bridge delivering USDC to the pool.
        deal(usdc, freshPool, amount);

        int256 vsBefore = int256(uint256(vm.load(freshPool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));
        assertEq(vsBefore, 0, "Virtual supply should start at 0");

        // Phase 2: finalize. Identity USDC->USDC conversion must not consult the absent oracle.
        IECrosschain(freshPool).donate(usdc, amount, params);

        int256 vsAfter = int256(uint256(vm.load(freshPool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));
        assertGt(vsAfter, vsBefore, "Virtual supply must increase after an inbound transfer");
        assertEq(
            uint256(vsAfter - vsBefore),
            expectedDelta,
            "Virtual supply must increase by exactly amount * 10^decimals / NAV"
        );
    }

    /// @notice Same regression for Sync mode donations (rebalancing/donation path).
    function testFork_ECrosschain_DonateUsdc_Sync_Succeeds() public {
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Sync,
            shouldUnwrapNative: false
        });
        uint256 amount = 100_000e6;
        uint256 navBefore = ISmartPoolActions(pool).updateUnitaryValue().netTotalValue;

        IECrosschain(pool).donate(usdc, 1, params);
        deal(usdc, pool, IERC20(usdc).balanceOf(pool) + amount);

        // Sync mode: no virtual supply update, but NAV validation runs identity conversion.
        IECrosschain(pool).donate(usdc, amount, params);

        int256 vs = int256(uint256(vm.load(pool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));
        assertEq(vs, 0, "Sync mode must not modify virtual supply");
        uint256 navAfter = ISmartPoolActions(pool).updateUnitaryValue().netTotalValue;
        assertEq(navAfter - navBefore, amount, "Sync donation must increase net total assets");
    }

    /// @notice Only the Hyperliquid application bit can be activated on HyperEVM.
    /// @dev Other Rigoblock apps (Staking, UniV4, GMX, 0x, Uniswap WETH wrapper, Governance) either
    ///  do not set an application bit or cannot operate on HyperEVM because their dependencies are
    ///  not deployed / authorized. This test verifies that a deposit only flips the HYPERLIQUID bit.
    function testFork_OnlyHyperliquidAppBitActivated() public {
        uint256 hyperliquidBit = 1 << uint256(Applications.HYPERLIQUID);

        assertEq(
            ISmartPoolState(pool).getActiveApplications(),
            0,
            "No application should be active before a Hyperliquid deposit"
        );

        uint256 depositAmount = 10_000e6;
        vm.prank(poolOwner);
        IAHyperliquid(pool).deposit(depositAmount, HLConstants.DEFAULT_PERP_DEX);

        uint256 activeApps = ISmartPoolState(pool).getActiveApplications();
        assertEq(activeApps, hyperliquidBit, "Only the HYPERLIQUID bit should be active after a deposit");

        // Defensive: assert all other known application bits are off.
        assertEq(activeApps & ~hyperliquidBit, 0, "No application other than HYPERLIQUID should be active");
    }

    /// @notice A spot-send withdrawal request must not change the pool's unitary value once the
    ///  settlement window elapses. Deflating NAV before the EVM-side USDC credit arrives would
    ///  understate the pool's value.
    function testFork_SpotSendWithdrawalDoesNotChangeNavAfterSettlementWindow() public {
        uint256 depositAmount = 10_000e6;

        // Activate the Hyperliquid application and record an in-flight deposit.
        vm.prank(poolOwner);
        IAHyperliquid(pool).deposit(depositAmount, HLConstants.DEFAULT_PERP_DEX);

        // Warp past the deposit window so the pre-request NAV read is allowed.
        vm.warp(block.timestamp + 17 seconds);

        // Simulate a Core state where the pool already holds 20k USDC in the spot account.
        uint64 spotAmountWei = 20_000e6 * 1e2;
        _mockAccountMarginSummary(0);
        _mockSpotBalance(pool, HLConstants.USDC_TOKEN_INDEX, spotAmountWei);

        NetAssetsValue memory navBefore = ISmartPoolActions(pool).updateUnitaryValue();

        uint64 withdrawAmountWei = 5_000e6 * 1e2;
        address systemAddress = CoreWriterLib.getSystemAddress(HLConstants.USDC_TOKEN_INDEX);
        bytes memory data = abi.encodePacked(
            uint8(1),
            uint24(HLConstants.SPOT_SEND_ACTION),
            abi.encode(systemAddress, HLConstants.USDC_TOKEN_INDEX, withdrawAmountWei)
        );

        _mockCoreUserExists(pool, true);
        vm.prank(poolOwner);
        IAHyperliquid(pool).sendRawAction(data);

        // Warp past the spot-send window before reading NAV again.
        vm.warp(block.timestamp + 17 seconds);

        NetAssetsValue memory navAfter = ISmartPoolActions(pool).updateUnitaryValue();
        assertEq(navAfter.unitaryValue, navBefore.unitaryValue, "Spot-send request must not change unitaryValue");
    }

    /// @notice A spot-send is NAV-neutral at every stage (its destination is forced to the pool's own
    ///  address, and within the same EVM block nothing has moved yet), so burning in the same EVM block
    ///  as a spot-send request must succeed. Regression test pinning the lock semantics: only the
    ///  time lock, keyed from the next L1 block, defers share redemption.
    function testFork_SameBlockBurnAfterSpotSendSucceeds() public {
        // Satisfy the default minimum lockup period (30 days) for the tokens minted in the fixture.
        vm.warp(block.timestamp + 30 days + 1);

        uint256 depositAmount = 10_000e6;
        vm.prank(poolOwner);
        IAHyperliquid(pool).deposit(depositAmount, HLConstants.DEFAULT_PERP_DEX);

        // Warp past the deposit window so the pre-request NAV read is allowed.
        vm.warp(block.timestamp + 17 seconds);
        _advanceL1Block();

        // Simulate a Core state where the pool already holds 20k USDC in the spot account.
        _mockAccountMarginSummary(0);
        _mockSpotBalance(pool, HLConstants.USDC_TOKEN_INDEX, 20_000e6 * 1e2);
        _mockCoreUserExists(pool, true);

        uint64 withdrawAmountWei = 5_000e6 * 1e2;
        address systemAddress = CoreWriterLib.getSystemAddress(HLConstants.USDC_TOKEN_INDEX);
        bytes memory data = abi.encodePacked(
            uint8(1),
            uint24(HLConstants.SPOT_SEND_ACTION),
            abi.encode(systemAddress, HLConstants.USDC_TOKEN_INDEX, withdrawAmountWei)
        );
        vm.prank(poolOwner);
        IAHyperliquid(pool).sendRawAction(data);

        // Same L1 block: the burn succeeds because NAV is exact (the withdrawal is queued but has
        // not executed, and it can only ever move funds between the pool's own accounts).
        address user = fixture.user();
        uint256 userBalance = IERC20(pool).balanceOf(user);
        vm.startPrank(user);
        ISmartPoolActions(pool).burn(userBalance / 10, 0);
        vm.stopPrank();

        assertLt(IERC20(pool).balanceOf(user), userBalance, "Burn should decrease user balance");
    }

    /// @notice Minting is deferred during the 16-second Hyperliquid settlement window. Same-L1-block
    ///  mints are allowed (the in-flight amount keeps the NAV correct); from the next L1 block on,
    ///  until the window elapses, minting reverts.
    function testFork_MintRevertsDuringSettlementWindow() public {
        uint256 depositAmount = 10_000e6;
        vm.prank(poolOwner);
        IAHyperliquid(pool).deposit(depositAmount, HLConstants.DEFAULT_PERP_DEX);

        // Move to the next L1 block, still inside the 16-second window.
        _advanceL1Block();

        address user = fixture.user();
        vm.startPrank(user);
        vm.expectRevert(NavLocked.selector);
        ISmartPoolActions(pool).mint(user, 1_000e6, 0);
        vm.stopPrank();
    }

    /// @notice Minting in the same block as a Hyperliquid deposit succeeds: the in-flight amount
    ///  keeps the in-block NAV correct, so no lock is enforced until the L1 block advances.
    function testFork_MintSucceedsSameBlockAfterDeposit() public {
        uint256 depositAmount = 10_000e6;
        vm.prank(poolOwner);
        IAHyperliquid(pool).deposit(depositAmount, HLConstants.DEFAULT_PERP_DEX);

        // Mock lagging Core state: the precompile does not reflect the deposit yet.
        _mockAccountMarginSummary(0);
        _mockSpotBalance(pool, HLConstants.USDC_TOKEN_INDEX, 0);
        _mockCoreUserExists(pool, true);

        address user = fixture.user();
        uint256 userBalanceBefore = IERC20(pool).balanceOf(user);
        vm.startPrank(user);
        ISmartPoolActions(pool).mint(user, 1_000e6, 0);
        vm.stopPrank();

        assertGt(IERC20(pool).balanceOf(user), userBalanceBefore, "Same-block mint should succeed");
    }

    /// @notice Minting in the next EVM block — even within the same L1 block — reverts during the
    ///  settlement window: HyperCore processes EVM->Core transfers right after each EVM block is
    ///  built, so the in-flight amount expires at the next EVM block and the precompile is expected
    ///  to have caught up; the time lock covers the residual latency. Regression test pinning the
    ///  full-composite expiry semantics.
    function testFork_MintRevertsInNextEvmBlockWithinSameL1Block() public {
        uint256 depositAmount = 10_000e6;
        vm.prank(poolOwner);
        IAHyperliquid(pool).deposit(depositAmount, HLConstants.DEFAULT_PERP_DEX);

        // Advance the EVM block only; the mocked L1 block stays put.
        vm.roll(block.number + 1);

        address user = fixture.user();
        vm.startPrank(user);
        vm.expectRevert(NavLocked.selector);
        ISmartPoolActions(pool).mint(user, 1_000e6, 0);
        vm.stopPrank();
    }

    /// @notice Minting succeeds once the Hyperliquid settlement window has elapsed.
    function testFork_MintSucceedsAfterSettlementWindow() public {
        uint256 depositAmount = 10_000e6;
        vm.prank(poolOwner);
        IAHyperliquid(pool).deposit(depositAmount, HLConstants.DEFAULT_PERP_DEX);

        vm.warp(block.timestamp + 17 seconds);

        // Mock Core state so the post-window NAV update succeeds.
        _mockAccountMarginSummary(0);
        _mockSpotBalance(pool, HLConstants.USDC_TOKEN_INDEX, 0);

        address user = fixture.user();
        uint256 userBalanceBefore = IERC20(pool).balanceOf(user);
        vm.startPrank(user);
        ISmartPoolActions(pool).mint(user, 1_000e6, 0);
        vm.stopPrank();

        assertGt(IERC20(pool).balanceOf(user), userBalanceBefore, "Mint should increase user balance");
    }

    /// @notice Burning is deferred during the 16-second Hyperliquid settlement window. Same-L1-block
    ///  burns are allowed (the in-flight amount keeps the NAV correct); from the next L1 block on,
    ///  until the window elapses, burning reverts.
    function testFork_BurnRevertsDuringSettlementWindow() public {
        // Satisfy the default minimum lockup period (30 days) for the tokens minted in the fixture.
        vm.warp(block.timestamp + 30 days + 1);

        uint256 depositAmount = 10_000e6;
        vm.prank(poolOwner);
        IAHyperliquid(pool).deposit(depositAmount, HLConstants.DEFAULT_PERP_DEX);

        // Move to the next L1 block, still inside the 16-second window.
        _advanceL1Block();

        address user = fixture.user();
        uint256 userBalance = IERC20(pool).balanceOf(user);
        vm.startPrank(user);
        vm.expectRevert(NavLocked.selector);
        ISmartPoolActions(pool).burn(userBalance / 10, 0);
        vm.stopPrank();
    }

    /// @notice Burning succeeds once the Hyperliquid settlement window has elapsed.
    function testFork_BurnSucceedsAfterSettlementWindow() public {
        // Satisfy the default minimum lockup period (30 days) for the tokens minted in the fixture.
        vm.warp(block.timestamp + 30 days + 1);

        uint256 depositAmount = 10_000e6;
        vm.prank(poolOwner);
        IAHyperliquid(pool).deposit(depositAmount, HLConstants.DEFAULT_PERP_DEX);

        vm.warp(block.timestamp + 17 seconds);

        // Mock Core state so the post-window NAV update succeeds.
        _mockAccountMarginSummary(0);
        _mockSpotBalance(pool, HLConstants.USDC_TOKEN_INDEX, 0);

        address user = fixture.user();
        uint256 userBalance = IERC20(pool).balanceOf(user);
        vm.startPrank(user);
        ISmartPoolActions(pool).burn(userBalance / 10, 0);
        vm.stopPrank();

        assertLt(IERC20(pool).balanceOf(user), userBalance, "Burn should decrease user balance");
    }

    /// @notice Owner-only purge of inactive tokens/apps is a NAV-writing operation and stays locked
    ///  during the settlement window: only updateUnitaryValue is explicitly exempt from the lock.
    function testFork_PurgeRevertsDuringSettlementWindow() public {
        uint256 depositAmount = 10_000e6;
        vm.prank(poolOwner);
        IAHyperliquid(pool).deposit(depositAmount, HLConstants.DEFAULT_PERP_DEX);

        // Move to the next L1 block, still inside the 16-second window.
        _advanceL1Block();

        vm.startPrank(poolOwner);
        vm.expectRevert(NavLocked.selector);
        ISmartPoolOwnerActions(pool).purgeInactiveTokensAndApps();
        vm.stopPrank();
    }

    /// @notice updateUnitaryValue is the single method explicitly exempt from the settlement lock
    ///  (it is NAV-neutral and crosschain donate routes through it), while share issuance stays
    ///  locked. Regression test for issue #959.
    function testFork_UpdateUnitaryValueSucceedsWhileMintLockedDuringSettlementWindow() public {
        uint256 depositAmount = 10_000e6;
        vm.prank(poolOwner);
        IAHyperliquid(pool).deposit(depositAmount, HLConstants.DEFAULT_PERP_DEX);

        // Mock lagging Core state: the precompile does not reflect the deposit yet.
        _mockAccountMarginSummary(0);
        _mockSpotBalance(pool, HLConstants.USDC_TOKEN_INDEX, 0);
        _mockCoreUserExists(pool, true);

        // updateUnitaryValue must succeed even though the window is open.
        NetAssetsValue memory nav = ISmartPoolActions(pool).updateUnitaryValue();
        assertGt(nav.unitaryValue, 0, "updateUnitaryValue should succeed during the window");

        // Share issuance is still locked from the next L1 block until the window elapses.
        _advanceL1Block();
        address user = fixture.user();
        vm.startPrank(user);
        vm.expectRevert(NavLocked.selector);
        ISmartPoolActions(pool).mint(user, 1_000e6, 0);
        vm.stopPrank();
    }

    /// @notice Off-chain NAV view methods remain readable during the settlement window, but they
    ///  report a stale NAV because HyperCore has not yet caught up. On-chain NAV writes still revert.
    function testFork_NavViewReadsStaleNavDuringSettlementWindow() public {
        // Capture the pre-deposit NAV.
        NavView.NavData memory navBefore = IENavView(pool).getNavDataView();
        uint256 unitaryBefore = navBefore.unitaryValue;
        assertGt(unitaryBefore, 0, "Pre-deposit NAV should be positive");

        uint256 depositAmount = 10_000e6;
        vm.prank(poolOwner);
        IAHyperliquid(pool).deposit(depositAmount, HLConstants.DEFAULT_PERP_DEX);

        // Move one L1 block forward so the in-flight amount is dropped, but stay well inside the
        // time-based settlement window. HyperCore is still mocked as lagging (zero).
        _advanceL1Block();
        _mockAccountMarginSummary(0);
        _mockSpotBalance(pool, 0, 0);
        _mockCoreUserExists(pool, true);

        // The on-chain NAV write (updateUnitaryValue) is exempt from the lock and succeeds, but it
        // stores the same stale NAV the view reports.
        NetAssetsValue memory navStored = ISmartPoolActions(pool).updateUnitaryValue();
        assertLt(navStored.unitaryValue, unitaryBefore, "Stored NAV should be stale during window");

        // Off-chain view succeeds but reads the lagging Core balance (zero), so it reports a stale NAV
        // that is lower than the pre-deposit value because the pool's USDC has already left the wallet
        // but has not yet been credited by the HyperCore precompile.
        NavView.NavData memory navDuring = IENavView(pool).getNavDataView();
        assertLt(navDuring.unitaryValue, unitaryBefore, "Off-chain NAV should be stale during window");

        // After the settlement window elapses and HyperCore reflects the deposit, the settled NAV
        // matches the pre-deposit value: USDC has moved from the pool wallet to HyperCore, total value
        // is unchanged.
        vm.warp(block.timestamp + 17 seconds);
        _advanceL1Block();
        _mockAccountMarginSummary(int64(uint64(depositAmount)));

        NavView.NavData memory navAfter = IENavView(pool).getNavDataView();
        assertEq(navAfter.unitaryValue, unitaryBefore, "Settled NAV should match pre-deposit value");
    }

    /// @notice Off-chain NAV view methods succeed once the settlement window has elapsed.
    function testFork_NavViewSucceedsAfterSettlementWindow() public {
        uint256 depositAmount = 10_000e6;
        vm.prank(poolOwner);
        IAHyperliquid(pool).deposit(depositAmount, HLConstants.DEFAULT_PERP_DEX);

        vm.warp(block.timestamp + 17 seconds);
        _advanceL1Block();

        // Mock a caught-up Core state so the view returns the settled NAV.
        _mockAccountMarginSummary(int64(uint64(depositAmount)));
        _mockSpotBalance(pool, 0, 0);

        NavView.NavData memory navData = IENavView(pool).getNavDataView();
        assertGt(navData.unitaryValue, 0, "NavView should report a positive unitary value after the window");
    }

    /// @notice A spot-send withdrawal re-arms the settlement lock: share issuance reverts from the
    ///  next L1 block until the window elapses, while updateUnitaryValue remains exempt.
    function testFork_SendRawActionReArmsSettlementLock() public {
        uint256 depositAmount = 10_000e6;
        vm.prank(poolOwner);
        IAHyperliquid(pool).deposit(depositAmount, HLConstants.DEFAULT_PERP_DEX);

        // Warp past the deposit window so the pre-request NAV read is allowed.
        vm.warp(block.timestamp + 17 seconds);
        _advanceL1Block();

        _mockCoreUserExists(pool, true);
        _mockSpotBalance(pool, HLConstants.USDC_TOKEN_INDEX, 20_000e6 * 1e2);

        uint64 withdrawAmountWei = 5_000e6 * 1e2;
        address systemAddress = CoreWriterLib.getSystemAddress(HLConstants.USDC_TOKEN_INDEX);
        bytes memory data = abi.encodePacked(
            uint8(1),
            uint24(HLConstants.SPOT_SEND_ACTION),
            abi.encode(systemAddress, HLConstants.USDC_TOKEN_INDEX, withdrawAmountWei)
        );

        vm.prank(poolOwner);
        IAHyperliquid(pool).sendRawAction(data);

        // The spot send re-armed the settlement window: updateUnitaryValue is exempt and succeeds.
        _mockAccountMarginSummary(0);
        NetAssetsValue memory nav = ISmartPoolActions(pool).updateUnitaryValue();
        assertGt(nav.unitaryValue, 0, "updateUnitaryValue should succeed during the window");

        // ...but share issuance is locked again from the next L1 block.
        _advanceL1Block();
        address user = fixture.user();
        vm.startPrank(user);
        vm.expectRevert(NavLocked.selector);
        ISmartPoolActions(pool).mint(user, 1_000e6, 0);
        vm.stopPrank();
    }

    /// @notice Perp trading actions do NOT trigger the settlement lock, so NAV reads stay available.
    function testFork_LimitOrderDoesNotLockUpdateUnitaryValue() public {
        _mockCoreUserExists(pool, true);

        uint32 asset = 0; // core perp asset
        bytes memory data = abi.encodePacked(
            uint8(1),
            uint24(HLConstants.LIMIT_ORDER_ACTION),
            abi.encode(asset, true, uint64(1), uint64(1), false, uint8(0), uint128(1))
        );

        vm.prank(poolOwner);
        IAHyperliquid(pool).sendRawAction(data);

        // updateUnitaryValue must succeed because only deposits and spot sends lock NAV.
        NetAssetsValue memory nav = ISmartPoolActions(pool).updateUnitaryValue();
        assertGt(nav.unitaryValue, 0, "Unitary value should be readable after a limit order");
    }

    /// @notice Cross-chain donation is NAV-neutral and routes through updateUnitaryValue, so it is
    ///  explicitly exempt from the settlement lock: a fill landing while the window is open succeeds.
    ///  Regression test for issue #959.
    function testFork_DonateSucceedsDuringSettlementWindow() public {
        uint256 depositAmount = 10_000e6;
        vm.prank(poolOwner);
        IAHyperliquid(pool).deposit(depositAmount, HLConstants.DEFAULT_PERP_DEX);

        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Sync,
            shouldUnwrapNative: false
        });

        // Mock lagging Core state: the precompile does not reflect the deposit yet.
        _mockAccountMarginSummary(0);
        _mockSpotBalance(pool, HLConstants.USDC_TOKEN_INDEX, 0);
        _mockCoreUserExists(pool, true);

        // Phase 1 (init) calls updateUnitaryValue: it must not revert on the lock.
        IECrosschain(pool).donate(usdc, 1, params);

        // Simulate the bridge delivering USDC to the pool.
        uint256 amount = 100_000e6;
        deal(usdc, pool, IERC20(usdc).balanceOf(pool) + amount);

        // Phase 2 (finalize) calls updateUnitaryValue twice more: still exempt, donation succeeds.
        IECrosschain(pool).donate(usdc, amount, params);
    }

    /// @notice A Hyperliquid action between donation init and finalize is still blocked: no longer by
    ///  the settlement lock (updateUnitaryValue is exempt) but by the strict NAV-integrity check,
    ///  which accounts for the token-balance delta and flags the pending Core credit as a NAV change.
    function testFork_DonateFinalizeRevertsOnInterleavedHyperliquidAction() public {
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Sync,
            shouldUnwrapNative: false
        });

        // Initialize the donation while no Hyperliquid action is pending.
        IECrosschain(pool).donate(usdc, 1, params);

        // Increase the pool USDC balance so the finalize-phase balance check passes even after the
        // Hyperliquid deposit pull. We use the fixture user as the sender.
        address user = fixture.user();
        vm.prank(user);
        IERC20(usdc).transfer(pool, 800_000e6);

        // A Hyperliquid action is recorded between init and finalize. Overall it is NAV-neutral
        // (wallet -10k, Core +10k pending), but the donation integrity check only accounts for the
        // token-balance delta, so the pending Core credit is flagged as a NAV manipulation.
        uint256 depositAmount = 10_000e6;
        vm.prank(poolOwner);
        IAHyperliquid(pool).deposit(depositAmount, HLConstants.DEFAULT_PERP_DEX);

        _mockAccountMarginSummary(0);
        _mockSpotBalance(pool, HLConstants.USDC_TOKEN_INDEX, 0);
        _mockCoreUserExists(pool, true);

        // The pending Core credit is not accounted for by the token-balance delta, so the strict
        // NAV-integrity check flags it. (This forge version's expectRevert(bytes4) requires the exact
        // payload, so the arg-bearing error is asserted via try/catch.)
        try IECrosschain(pool).donate(usdc, 500_000e6, params) {
            revert("donate should revert with NavManipulationDetected");
        } catch (bytes memory err) {
            assertEq(
                bytes4(err),
                IECrosschain.NavManipulationDetected.selector,
                "interleaved Core movement must be flagged"
            );
        }
    }

    /// @notice A `shouldUnwrapNative: true` flag on a non-wrapped-native token is ignored: the
    ///  unwrap only applies when the donated token IS the wrapped native currency. Rogue flag on
    ///  USDC must not attempt an unwrap and the donation must finalize normally.
    function testFork_DonateIgnoresUnwrapFlagForNonWrappedNative() public {
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: true // rogue: usdc is not the wrapped native token
        });
        uint256 amount = 100_000e6;

        // Phase 1: lock the current USDC balance.
        IECrosschain(pool).donate(usdc, 1, params);

        // Simulate the bridge delivering USDC to the pool.
        deal(usdc, pool, IERC20(usdc).balanceOf(pool) + amount);

        // Phase 2: finalize. The unwrap flag must be ignored for USDC.
        IECrosschain(pool).donate(usdc, amount, params);

        int256 vs = int256(uint256(vm.load(pool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));
        assertGt(vs, 0, "Transfer mode donation must mint virtual supply");
    }

    /// @notice A donation finalized with an unsupported op type reverts, even with valid amounts.
    function testFork_DonateUnknownOpTypeReverts() public {
        DestinationMessageParams memory initParams = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });

        // Phase 1: lock the current USDC balance with a valid op type.
        IECrosschain(pool).donate(usdc, 1, initParams);

        // Simulate the bridge delivering USDC to the pool.
        uint256 amount = 100_000e6;
        deal(usdc, pool, IERC20(usdc).balanceOf(pool) + amount);

        // Phase 2: finalize with OpType.Unknown.
        DestinationMessageParams memory rogueParams = DestinationMessageParams({
            opType: OpType.Unknown,
            shouldUnwrapNative: false
        });
        vm.expectRevert(IECrosschain.InvalidOpType.selector);
        IECrosschain(pool).donate(usdc, amount, rogueParams);
    }

    /// @notice updateUnitaryValue succeeds once the Hyperliquid settlement window has elapsed.
    function testFork_UpdateUnitaryValueSucceedsAfterSettlementWindow() public {
        uint256 depositAmount = 10_000e6;
        vm.prank(poolOwner);
        IAHyperliquid(pool).deposit(depositAmount, HLConstants.DEFAULT_PERP_DEX);

        vm.warp(block.timestamp + 17 seconds);

        // Mock Core state so the post-window NAV update succeeds.
        _mockAccountMarginSummary(0);
        _mockSpotBalance(pool, HLConstants.USDC_TOKEN_INDEX, 0);

        NetAssetsValue memory nav = ISmartPoolActions(pool).updateUnitaryValue();
        assertGt(nav.unitaryValue, 0, "Unitary value should be positive after window");
    }

    /// @notice AUniswap.wrapETH(0) is a no-op and does not mutate pool state on HyperEVM.
    function testFork_AUniswap_WrapZeroIsNoOp() public {
        _deployAndAuthorizeAUniswap();

        uint256 appsBefore = ISmartPoolState(pool).getActiveApplications();
        uint256 usdcBefore = IERC20(usdc).balanceOf(pool);

        vm.prank(poolOwner);
        IAUniswap(pool).wrapETH(0);

        assertEq(ISmartPoolState(pool).getActiveApplications(), appsBefore, "Applications bitmap unchanged");
        assertEq(IERC20(usdc).balanceOf(pool), usdcBefore, "Pool USDC balance unchanged");
    }

    /// @notice AUniswap.wrapETH with a positive amount reverts because the wrapped-native token is not USDC.
    /// @dev On HyperEVM only USDC has a price feed, so attempting to wrap the native currency (which
    ///  produces the wrapped-native token as the tracked output) always reverts in our adapter.
    function testFork_AUniswap_WrapPositiveRevertsForWrappedNative() public {
        _deployAndAuthorizeAUniswap();

        address whype = fixture.HYPER_WHYPE();
        vm.startPrank(poolOwner);
        vm.expectRevert(abi.encodeWithSelector(TokenPriceFeedDoesNotExist.selector, whype));
        IAUniswap(pool).wrapETH(1 ether);
        vm.stopPrank();
    }

    /// @notice AUniswapRouter cannot be deployed on HyperEVM because the v4 PositionManager is not
    ///  deployed there. The fixture asserts HYPER_UNISWAP_V4_POSM and HYPER_UNIVERSAL_ROUTER are zero;
    ///  if a future upgrade adds Uniswap V4 on HyperEVM, this assertion (and these tests) must be
    ///  reviewed before the constants are changed.
    function testFork_AUniswapRouter_DeploymentRevertsWithZeroPosm() public {
        address whype = fixture.HYPER_WHYPE();
        vm.expectRevert();
        new AUniswapRouter(address(0), address(0), whype);
    }

    /// @notice A0xRouter rejects a non-USDC buy token in our adapter before reaching the Settler.
    /// @dev 0x Settler is deployed on HyperEVM, but the adapter's price-feed check is the guard that
    ///  keeps only USDC-receiving swaps activatable. This test exercises that guard with the real
    ///  deployer and AllowanceHolder addresses.
    function testFork_A0xRouter_NonUsdcBuyTokenRevertsInAdapter() public {
        (, address settler) = _deployAndAuthorizeA0xRouter();

        address whype = fixture.HYPER_WHYPE();
        bytes memory data = _build0xExecuteCalldata(whype);

        vm.startPrank(poolOwner);
        vm.expectRevert(abi.encodeWithSelector(TokenPriceFeedDoesNotExist.selector, whype));
        IA0xRouter(pool).exec(settler, usdc, 0, payable(settler), data);
        vm.stopPrank();
    }

    /// @notice A0xRouter with a USDC buy token passes our adapter validation and the mocked
    ///  AllowanceHolder succeeds, leaving pool/application storage unchanged.
    /// @dev The real AllowanceHolder and Deployer addresses are used. The external `exec` is mocked
    ///  so the test isolates adapter behavior (validation + approval reset) from the actual settler
    ///  execution path.
    function testFork_A0xRouter_UsdcBuyToken_DoesNotMutateStorage() public {
        (address allowanceHolder, address settler) = _deployAndAuthorizeA0xRouter();

        uint256 appsBefore = ISmartPoolState(pool).getActiveApplications();
        uint256 usdcBefore = IERC20(usdc).balanceOf(pool);

        bytes memory data = _build0xExecuteCalldata(usdc);

        // Mock the AllowanceHolder execution to succeed without touching pool balances.
        vm.mockCall(allowanceHolder, abi.encodeWithSelector(IAllowanceHolder.exec.selector), abi.encode(bytes("")));

        vm.startPrank(poolOwner);
        IA0xRouter(pool).exec(settler, usdc, 0, payable(settler), data);
        vm.stopPrank();

        assertEq(ISmartPoolState(pool).getActiveApplications(), appsBefore, "Applications bitmap unchanged");
        assertEq(IERC20(usdc).balanceOf(pool), usdcBefore, "Pool USDC balance unchanged");
    }

    /// @notice AStaking with zero dependencies reverts and does not mutate pool state.
    function testFork_AStaking_ZeroDependenciesReverts() public {
        address aStaking = deployCode("out/AStaking.sol/AStaking.json", abi.encode(address(0), address(0), address(0)));

        address authorityOwner = IOwnedUninitialized(fixture.authority()).owner();
        vm.startPrank(authorityOwner);
        IAuthority authority = IAuthority(fixture.authority());
        authority.setAdapter(aStaking, true);
        _addOrReplaceMethod(authority, IAStaking.stake.selector, aStaking);
        _addOrReplaceMethod(authority, IAStaking.undelegateStake.selector, aStaking);
        vm.stopPrank();

        uint256 appsBefore = ISmartPoolState(pool).getActiveApplications();
        uint256 usdcBefore = IERC20(usdc).balanceOf(pool);

        vm.startPrank(poolOwner);
        vm.expectRevert("STAKE_AMOUNT_NULL_ERROR");
        IAStaking(pool).stake(0);

        vm.expectRevert();
        IAStaking(pool).undelegateStake(0);
        vm.stopPrank();

        assertEq(ISmartPoolState(pool).getActiveApplications(), appsBefore, "No application bit changed");
        assertEq(IERC20(usdc).balanceOf(pool), usdcBefore, "Pool USDC balance unchanged");
    }

    /// @notice AGovernance with a zero governance address reverts and does not mutate pool state.
    function testFork_AGovernance_ZeroDependenciesReverts() public {
        address aGovernance = deployCode("out/AGovernance.sol/AGovernance.json", abi.encode(address(0)));

        address authorityOwner = IOwnedUninitialized(fixture.authority()).owner();
        vm.startPrank(authorityOwner);
        IAuthority authority = IAuthority(fixture.authority());
        authority.setAdapter(aGovernance, true);
        _addOrReplaceMethod(authority, IAGovernance.propose.selector, aGovernance);
        vm.stopPrank();

        uint256 appsBefore = ISmartPoolState(pool).getActiveApplications();
        uint256 usdcBefore = IERC20(usdc).balanceOf(pool);

        vm.startPrank(poolOwner);
        vm.expectRevert();
        IAGovernance(pool).propose(new IRigoblockGovernance.ProposedAction[](0), "");
        vm.stopPrank();

        assertEq(ISmartPoolState(pool).getActiveApplications(), appsBefore, "No application bit changed");
        assertEq(IERC20(usdc).balanceOf(pool), usdcBefore, "Pool USDC balance unchanged");
    }

    /// @notice EApps returns an empty balance array for GRG_STAKING on HyperEVM, so the staking
    ///  application bit cannot be activated by a NAV read.
    function testFork_EApps_StakingAppReturnsEmptyOnHyperEVM() public {
        ExternalApp[] memory apps = IEApps(pool).getAppTokenBalances(1 << uint256(Applications.GRG_STAKING));
        assertEq(apps.length, 1, "One app entry returned for the queried bit");
        assertEq(apps[0].appType, uint256(Applications.GRG_STAKING), "App type is GRG_STAKING");
        assertEq(apps[0].balances.length, 0, "No staking balance on HyperEVM");
    }

    /// @notice AGmxV2 cannot even be deployed on HyperEVM because its constructor is Arbitrum-only.
    function testFork_AGmxV2_DeploymentRevertsOnHyperEVM() public {
        vm.expectRevert(IAGmxV2.NotArbitrum.selector);
        new AGmxV2();
    }

    /// @dev Deploys AUniswap with WHYPE as the wrapped-native address and authorizes its selectors.
    function _deployAndAuthorizeAUniswap() private returns (AUniswap aUniswap) {
        aUniswap = new AUniswap(fixture.HYPER_WHYPE());

        address authorityOwner = IOwnedUninitialized(fixture.authority()).owner();
        vm.startPrank(authorityOwner);
        IAuthority authority = IAuthority(fixture.authority());
        authority.setAdapter(address(aUniswap), true);
        _addOrReplaceMethod(authority, IAUniswap.wrapETH.selector, address(aUniswap));
        vm.stopPrank();
    }

    /// @dev Deploys A0xRouter with the canonical HyperEVM 0x AllowanceHolder / Deployer addresses
    ///  and authorizes the exec selector. Returns the AllowanceHolder and the current Feature-2
    ///  (Taker Submitted) settler reported by the real 0x Deployer registry.
    function _deployAndAuthorizeA0xRouter() private returns (address allowanceHolder, address settler) {
        allowanceHolder = Constants.ZERO_EX_ALLOWANCE_HOLDER;
        address deployer = Constants.ZERO_EX_DEPLOYER;

        A0xRouter a0xRouter = new A0xRouter(allowanceHolder, deployer);

        address authorityOwner = IOwnedUninitialized(fixture.authority()).owner();
        vm.startPrank(authorityOwner);
        IAuthority authority = IAuthority(fixture.authority());
        authority.setAdapter(address(a0xRouter), true);
        _addOrReplaceMethod(authority, IA0xRouter.exec.selector, address(a0xRouter));
        vm.stopPrank();

        // Query the real Feature-2 settler from the 0x Deployer registry. Fall back to the previous
        // settler if the current one is paused or not yet registered at the fork block.
        try IDeployer(deployer).ownerOf(2) returns (address current) {
            settler = current;
        } catch {
            settler = IDeployer(deployer).prev(Feature.wrap(2));
        }
    }

    /// @notice Builds a minimal valid 0x TakerSubmitted `execute` payload.
    /// @param buyToken The token the Settler is expected to deliver to the pool. On HyperEVM this
    ///  must be USDC for the adapter validation to pass.
    function _build0xExecuteCalldata(address buyToken) private view returns (bytes memory data) {
        address recipient = pool;
        uint256 minAmountOut = 0;
        bytes32 zid = bytes32(0);

        ISettlerBase.AllowedSlippage memory slippage = ISettlerBase.AllowedSlippage({
            recipient: payable(recipient),
            buyToken: IForgeERC20(buyToken),
            minAmountOut: minAmountOut
        });

        bytes[] memory actions = new bytes[](1);
        actions[0] = abi.encodeCall(ISettlerActions.CHECK_SLIPPAGE, (false));

        data = abi.encodeCall(ISettlerTakerSubmitted.execute, (slippage, actions, zid));
    }

    /// @notice Replaces an Authority selector mapping if it differs from the desired adapter.
    function _addOrReplaceMethod(IAuthority authority, bytes4 selector, address adapter) private {
        address current = authority.getApplicationAdapter(selector);
        if (current == adapter) return;
        if (current != address(0)) {
            authority.removeMethod(selector, current);
        }
        authority.addMethod(selector, adapter);
    }

    /// @notice Hyperliquid read precompile addresses (from hyper-evm-lib).
    address private constant _SPOT_BALANCE = HLConstants.SPOT_BALANCE_PRECOMPILE_ADDRESS;
    address private constant _TOKEN_INFO = HLConstants.TOKEN_INFO_PRECOMPILE_ADDRESS;
    address private constant _ACCOUNT_MARGIN_SUMMARY = HLConstants.ACCOUNT_MARGIN_SUMMARY_PRECOMPILE_ADDRESS;
    address private constant _CORE_USER_EXISTS = HLConstants.CORE_USER_EXISTS_PRECOMPILE_ADDRESS;
    address private constant _L1_BLOCK_NUMBER = HLConstants.L1_BLOCK_NUMBER_PRECOMPILE_ADDRESS;

    /// @notice Mocks the tokenInfo precompile for USDC (token index 0).
    function _mockUsdcTokenInfo() internal {
        vm.mockCall(
            _TOKEN_INFO,
            abi.encode(uint64(0)),
            abi.encode(
                PrecompileLib.TokenInfo({
                    name: "USDC",
                    spots: new uint64[](0),
                    deployerTradingFeeShare: 0,
                    deployer: address(0),
                    evmContract: usdc,
                    szDecimals: 0,
                    weiDecimals: 8,
                    evmExtraWeiDecimals: -2
                })
            )
        );
    }

    function _mockSpotBalance(address account, uint64 tokenIndex, uint64 total) internal {
        vm.mockCall(
            _SPOT_BALANCE,
            abi.encode(account, tokenIndex),
            abi.encode(PrecompileLib.SpotBalance({total: total, hold: 0, entryNtl: 0}))
        );
    }

    /// @notice Mocks the L1 block number precompile used for L1-keyed in-flight tracking.
    function _mockL1BlockNumber(uint64 l1Block) internal {
        vm.mockCall(_L1_BLOCK_NUMBER, abi.encode(), abi.encode(l1Block));
    }

    /// @dev Simulates a new HyperCore block: the L1 block number precompile advances and the EVM
    ///  block rolls forward. State precompiles only reflect HyperCore state from this point on.
    function _advanceL1Block() internal {
        unchecked {
            _l1Block += 1;
        }
        vm.roll(block.number + 1);
        _mockL1BlockNumber(_l1Block);
    }

    /// @notice Mocks the Core user-existence precompile.
    function _mockCoreUserExists(address account, bool exists) internal {
        vm.mockCall(_CORE_USER_EXISTS, abi.encode(account), abi.encode(exists));
    }
}
