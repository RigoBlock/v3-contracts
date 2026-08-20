// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {HyperliquidDeploymentFixture} from "../fixtures/HyperliquidDeploymentFixture.sol";
import {IAHyperliquid} from "../../contracts/protocol/extensions/adapters/interfaces/IAHyperliquid.sol";
import {HLConstants} from "hyper-evm-lib/common/HLConstants.sol";
import {PrecompileLib} from "hyper-evm-lib/PrecompileLib.sol";
import {IEApps} from "../../contracts/protocol/extensions/adapters/interfaces/IEApps.sol";
import {IEOracle} from "../../contracts/protocol/extensions/adapters/interfaces/IEOracle.sol";
import {IECrosschain} from "../../contracts/protocol/extensions/adapters/interfaces/IECrosschain.sol";
import {DestinationMessageParams, OpType} from "../../contracts/protocol/types/Crosschain.sol";
import {CrosschainLib} from "../../contracts/protocol/libraries/CrosschainLib.sol";
import {ExternalApp} from "../../contracts/protocol/types/ExternalApp.sol";
import {Applications} from "../../contracts/protocol/types/Applications.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {ISmartPoolOwnerActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolOwnerActions.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {IERC20 as IForgeERC20} from "@forge-std/interfaces/IERC20.sol";
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

/// @dev Local copy of the error selector so we do not need to import the implementation.
error BaseTokenPriceFeedError();
error TokenPriceFeedDoesNotExist(address token);

/// @title AHyperliquidForkTest
/// @notice HyperEVM fork tests for the Hyperliquid adapter.
/// @dev Requires HYPERLIQUID_RPC_URL in .env / foundry.toml.
contract AHyperliquidForkTest is Test {
    HyperliquidDeploymentFixture public fixture;

    address public pool;
    address public poolOwner;
    address public aHyperliquid;
    address public usdc;

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

        // Mock the L1 block number precompile used for composite-block in-flight tracking.
        _mockL1BlockNumber();

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

    /// @notice NAV read does not revert after depositing to HyperCore.
    /// @dev The test mocks the HyperCore account-value precompile because Foundry's EVM does not
    ///  implement it. The mock represents a later state in which the deposit is observable, without
    ///  asserting anything about production settlement timing.
    function testFork_NavAfterDeposit() public {
        uint256 depositAmount = 10_000e6;

        vm.prank(poolOwner);
        IAHyperliquid(pool).deposit(depositAmount, HLConstants.DEFAULT_PERP_DEX);

        // Mock the precompile to simulate a state where the deposit is observable in HyperCore.
        _mockAccountMarginSummary(int64(uint64(depositAmount * 1e2)));
        _mockSpotBalance(pool, 0, 0);
        _mockUsdcTokenInfo();

        // Same-block NAV read: should succeed because of the Hyperliquid base-token carve-out.
        NetAssetsValue memory nav = ISmartPoolActions(pool).updateUnitaryValue();
        assertGt(nav.unitaryValue, 0, "Unitary value should be positive");

        // Roll forward and mock the precompile again to exercise a subsequent NAV read.
        vm.roll(block.number + 1);
        NetAssetsValue memory nextNav = ISmartPoolActions(pool).updateUnitaryValue();
        assertGt(nextNav.unitaryValue, 0, "Unitary value should remain positive next block");
    }

    /// @notice Verifies the Hyperliquid perps application reports a balance while the precompile
    ///  return value is mocked to lag behind the write.
    /// @dev Because Foundry does not implement HyperCore read precompiles, the test explicitly
    ///  supplies both a lagging value and a caught-up value. This proves the in-flight tracking
    ///  avoids a stale balance, not that production HyperCore updates in exactly one block.
    function testFork_InFlightBalanceDuringGap() public {
        uint256 depositAmount = 10_000e6;

        vm.prank(poolOwner);
        IAHyperliquid(pool).deposit(depositAmount, HLConstants.DEFAULT_PERP_DEX);

        // Same block: simulate the HyperCore precompile not yet reflecting the deposit.
        _mockAccountMarginSummary(0);
        _mockSpotBalance(pool, 0, 0);
        _mockUsdcTokenInfo();

        ExternalApp[] memory apps = IEApps(pool).getAppTokenBalances(1 << uint256(Applications.HYPERLIQUID));

        bool foundHyperliquid;
        for (uint256 i = 0; i < apps.length; i++) {
            if (apps[i].appType == uint256(Applications.HYPERLIQUID)) {
                foundHyperliquid = true;
                assertEq(apps[i].balances.length, 1, "Hyperliquid app should report one balance");
                assertEq(apps[i].balances[0].token, usdc, "Balance token should be USDC");
                assertEq(apps[i].balances[0].amount, int256(depositAmount), "Balance should equal in-flight deposit");
                break;
            }
        }
        assertTrue(foundHyperliquid, "Hyperliquid application should be returned");

        // Roll forward and mock the precompile with a caught-up value to exercise the non-in-flight path.
        vm.roll(block.number + 1);
        _mockAccountMarginSummary(int64(uint64(depositAmount * 1e2)));

        apps = IEApps(pool).getAppTokenBalances(1 << uint256(Applications.HYPERLIQUID));
        for (uint256 i = 0; i < apps.length; i++) {
            if (apps[i].appType == uint256(Applications.HYPERLIQUID)) {
                assertEq(apps[i].balances[0].amount, int256(depositAmount), "Balance should equal precompile value");
                break;
            }
        }
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

    /// @notice Mocks the L1 block number precompile used for composite-block in-flight tracking.
    function _mockL1BlockNumber() internal {
        vm.mockCall(_L1_BLOCK_NUMBER, abi.encode(), abi.encode(uint64(block.number)));
    }
}
