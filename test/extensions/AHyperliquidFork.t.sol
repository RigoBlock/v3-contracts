// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {HyperliquidDeploymentFixture} from "../fixtures/HyperliquidDeploymentFixture.sol";
import {IAHyperliquid} from "../../contracts/protocol/extensions/adapters/interfaces/IAHyperliquid.sol";
import {HLConstants} from "hyper-evm-lib/common/HLConstants.sol";
import {PrecompileLib} from "hyper-evm-lib/PrecompileLib.sol";
import {IEApps} from "../../contracts/protocol/extensions/adapters/interfaces/IEApps.sol";
import {ExternalApp, AppTokenBalance} from "../../contracts/protocol/types/ExternalApp.sol";
import {Applications} from "../../contracts/protocol/types/Applications.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {NetAssetsValue} from "../../contracts/protocol/types/NavComponents.sol";

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
    ///  the HyperCore precompiles, even when forking a HyperEVM RPC. The mocks represent the
    ///  on-chain HyperCore state that the pool would read back after the action settlement delay.
    /// @dev CoreWriter itself is not mocked; it emits the action log. What is mocked is the
    ///  read-only precompile state that lags behind the write by at least one block.

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
    /// @dev Because the HyperCore account value lags by a block, the in-flight amount keeps the
    ///  Hyperliquid application from being purged immediately and prevents a stale NAV.
    function testFork_NavAfterDeposit() public {
        uint256 depositAmount = 10_000e6;

        vm.prank(poolOwner);
        IAHyperliquid(pool).deposit(depositAmount, HLConstants.DEFAULT_PERP_DEX);

        // Mock the precompile to simulate the deposit having landed in HyperCore perp margin.
        _mockAccountMarginSummary(int64(uint64(depositAmount * 1e2)));
        _mockSpotBalance(pool, 0, 0);
        _mockUsdcTokenInfo();

        // Same-block NAV read: should succeed because of the Hyperliquid base-token carve-out.
        NetAssetsValue memory nav = ISmartPoolActions(pool).updateUnitaryValue();
        assertGt(nav.unitaryValue, 0, "Unitary value should be positive");

        // Next block: the HyperCore precompile should reflect the deposit (or the in-flight dust
        // keeps the app alive until it does). Either way, NAV read succeeds.
        vm.roll(block.number + 1);
        NetAssetsValue memory nextNav = ISmartPoolActions(pool).updateUnitaryValue();
        assertGt(nextNav.unitaryValue, 0, "Unitary value should remain positive next block");
    }

    /// @notice Verifies the Hyperliquid perps application reports a balance during the one-block gap.
    /// @dev The account margin summary precompile may not yet include the deposit. The in-flight
    ///  tracking adds the deposited amount for the same block only, so the app is not purged and
    ///  there is no double-count once the precompile catches up next block.
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

        // Next block: precompile reflects the deposit; in-flight amount is no longer added.
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

    /// @notice Hyperliquid spot precompile addresses (from hyper-evm-lib).
    address private constant _SPOT_BALANCE = HLConstants.SPOT_BALANCE_PRECOMPILE_ADDRESS;
    address private constant _TOKEN_INFO = HLConstants.TOKEN_INFO_PRECOMPILE_ADDRESS;
    address private constant _ACCOUNT_MARGIN_SUMMARY = HLConstants.ACCOUNT_MARGIN_SUMMARY_PRECOMPILE_ADDRESS;

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
}
