// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {HyperliquidDeploymentFixture} from "../fixtures/HyperliquidDeploymentFixture.sol";
import {AHyperliquid} from "../../contracts/protocol/extensions/adapters/AHyperliquid.sol";
import {IAHyperliquid} from "../../contracts/protocol/extensions/adapters/interfaces/IAHyperliquid.sol";
import {HyperliquidLib} from "../../contracts/protocol/libraries/HyperliquidLib.sol";
import {IEApps} from "../../contracts/protocol/extensions/adapters/interfaces/IEApps.sol";
import {ExternalApp, AppTokenBalance} from "../../contracts/protocol/types/ExternalApp.sol";
import {Applications} from "../../contracts/protocol/types/Applications.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {NetAssetsValue} from "../../contracts/protocol/types/NavComponents.sol";

/// @title AHyperliquidForkTest
/// @notice HyperEVM fork tests for the Hyperliquid adapter.
/// @dev Requires HYPERLIQUID_PRC_URL in .env / foundry.toml.
contract AHyperliquidForkTest is Test {
    HyperliquidDeploymentFixture public fixture;

    address public pool;
    address public poolOwner;
    address public aHyperliquid;
    address public usdc;

    /// @notice Hyperliquid account margin summary precompile address.
    address private constant _ACCOUNT_MARGIN_SUMMARY = 0x000000000000000000000000000000000000080F;

    function setUp() public {
        fixture = new HyperliquidDeploymentFixture();
        fixture.deployFixture();

        pool = fixture.pool();
        poolOwner = fixture.poolOwner();
        aHyperliquid = fixture.aHyperliquid();
        usdc = fixture.HYPER_USDC();

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
        IAHyperliquid(pool).depositToCore(usdc, 0, depositAmount);

        uint256 poolUsdcAfter = IERC20(usdc).balanceOf(pool);
        assertEq(poolUsdcBefore - poolUsdcAfter, depositAmount, "Pool USDC should decrease by deposit");

        // The Hyperliquid application bit must have been activated by the deposit.
        uint256 activeApps = ISmartPoolState(pool).getActiveApplications();
        assertTrue(
            (activeApps & (1 << uint256(Applications.HYPERLIQUID_PERPS))) != 0,
            "HYPERLIQUID_PERPS should be active"
        );
    }

    /// @notice Mocks the Hyperliquid account margin summary precompile to return `accountValue` for dex 0.
    /// @dev Foundry does not implement Hyperliquid precompiles, so we must mock them in fork tests.
    function _mockAccountMarginSummary(int64 accountValue) internal {
        vm.mockCall(
            _ACCOUNT_MARGIN_SUMMARY,
            abi.encode(uint32(0), pool),
            abi.encode(
                HyperliquidLib.AccountMarginSummary({accountValue: accountValue, marginUsed: 0, ntlPos: 0, rawUsd: 0})
            )
        );
    }

    /// @notice NAV read does not revert after depositing to HyperCore.
    /// @dev Because the HyperCore account value lags by a block, the in-flight amount keeps the
    ///  Hyperliquid application from being purged immediately and prevents a stale NAV.
    function testFork_NavAfterDeposit() public {
        uint256 depositAmount = 10_000e6;

        vm.prank(poolOwner);
        IAHyperliquid(pool).depositToCore(usdc, 0, depositAmount);

        // Mock the precompile to simulate the deposit having landed in HyperCore perp margin.
        _mockAccountMarginSummary(int64(uint64(depositAmount)));

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
        IAHyperliquid(pool).depositToCore(usdc, 0, depositAmount);

        // Same block: simulate the HyperCore precompile not yet reflecting the deposit.
        _mockAccountMarginSummary(0);

        ExternalApp[] memory apps = IEApps(pool).getAppTokenBalances(1 << uint256(Applications.HYPERLIQUID_PERPS));

        bool foundHyperliquid;
        for (uint256 i = 0; i < apps.length; i++) {
            if (apps[i].appType == uint256(Applications.HYPERLIQUID_PERPS)) {
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
        _mockAccountMarginSummary(int64(uint64(depositAmount)));

        apps = IEApps(pool).getAppTokenBalances(1 << uint256(Applications.HYPERLIQUID_PERPS));
        for (uint256 i = 0; i < apps.length; i++) {
            if (apps[i].appType == uint256(Applications.HYPERLIQUID_PERPS)) {
                assertEq(apps[i].balances[0].amount, int256(depositAmount), "Balance should equal precompile value");
                break;
            }
        }
    }

    /// @notice Hyperliquid spot precompile addresses.
    address private constant _SPOT_BALANCE = 0x0000000000000000000000000000000000000801;
    address private constant _SPOT_PX = 0x0000000000000000000000000000000000000808;
    address private constant _SPOT_INFO = 0x000000000000000000000000000000000000080b;
    address private constant _TOKEN_INFO = 0x000000000000000000000000000000000000080C;

    uint64 private constant _HIP4_ASSET_ID = 100_000_010;
    uint64 private constant _HIP4_SPOT_INDEX = 1000;
    uint64 private constant _HIP4_TOKEN_INDEX = 42;

    function _mockSpotInfo() internal {
        vm.mockCall(
            _SPOT_INFO,
            abi.encode(_HIP4_SPOT_INDEX),
            abi.encode(HyperliquidLib.SpotInfo({name: "BTC-OUTCOME-1", tokens: [uint64(0), _HIP4_TOKEN_INDEX]}))
        );
    }

    function _mockTokenInfo(uint64 tokenIndex, string memory name, address evmContract) internal {
        vm.mockCall(
            _TOKEN_INFO,
            abi.encode(tokenIndex),
            abi.encode(
                HyperliquidLib.TokenInfo({
                    name: name,
                    spots: new uint64[](0),
                    deployerTradingFeeShare: 0,
                    deployer: address(0),
                    evmContract: evmContract,
                    szDecimals: 0,
                    weiDecimals: 8,
                    evmExtraWeiDecimals: evmContract == address(0) ? int8(0) : int8(2)
                })
            )
        );
    }

    function _mockSpotBalance(address account, uint64 tokenIndex, uint64 total) internal {
        vm.mockCall(
            _SPOT_BALANCE,
            abi.encode(account, tokenIndex),
            abi.encode(HyperliquidLib.SpotBalance({total: total, hold: 0, entryNtl: 0}))
        );
    }

    function _mockSpotPx(uint64 spotIndex, uint64 price) internal {
        vm.mockCall(_SPOT_PX, abi.encode(spotIndex), abi.encode(price));
    }

    function _setupPredictionMocks() internal {
        _mockSpotInfo();
        _mockTokenInfo(0, "USDC", usdc);
        _mockTokenInfo(_HIP4_TOKEN_INDEX, "+10", address(0));
        _mockSpotPx(_HIP4_SPOT_INDEX, 47_000_000);
    }

    /// @notice Deposit USDC to HyperCore spot dex and register a prediction token.
    function testFork_DepositToSpotAndRegisterToken() public {
        uint256 depositAmount = 10_000e6;
        _setupPredictionMocks();

        vm.prank(poolOwner);
        IAHyperliquid(pool).depositToSpot(usdc, depositAmount);

        uint256 activeApps = ISmartPoolState(pool).getActiveApplications();
        assertTrue(
            (activeApps & (1 << uint256(Applications.HYPERLIQUID_PREDICTIONS))) != 0,
            "HYPERLIQUID_PREDICTIONS should be active"
        );

        vm.prank(poolOwner);
        IAHyperliquid(pool).registerPredictionToken(_HIP4_ASSET_ID, _HIP4_SPOT_INDEX, _HIP4_TOKEN_INDEX);

        // Advance one block so the in-flight deposit amount is no longer double-counted.
        vm.roll(block.number + 1);

        // Simulate the deposit having landed in HyperCore spot plus some outcome tokens held.
        _mockSpotBalance(pool, 0, uint64(depositAmount) * 1e2); // USDC in 8-decimal spot balance
        _mockSpotBalance(pool, _HIP4_TOKEN_INDEX, 27e8); // 27 outcome tokens

        ExternalApp[] memory apps = IEApps(pool).getAppTokenBalances(
            1 << uint256(Applications.HYPERLIQUID_PREDICTIONS)
        );

        bool foundPredictions;
        for (uint256 i = 0; i < apps.length; i++) {
            if (apps[i].appType == uint256(Applications.HYPERLIQUID_PREDICTIONS)) {
                foundPredictions = true;
                assertEq(apps[i].balances.length, 1, "Predictions app should report one USDC balance");
                assertEq(apps[i].balances[0].token, usdc, "Balance token should be USDC");
                // 10_000 USDC spot + 27 * 0.47 USDC = 10_012.69 USDC in 6 decimals.
                assertEq(apps[i].balances[0].amount, 10_012_690_000, "Balance should equal spot + outcome value");
                break;
            }
        }
        assertTrue(foundPredictions, "HYPERLIQUID_PREDICTIONS application should be returned");
    }

    /// @notice Submit a prediction order after registering the token and depositing to spot.
    function testFork_SubmitPredictionOrder() public {
        _setupPredictionMocks();

        vm.prank(poolOwner);
        IAHyperliquid(pool).depositToSpot(usdc, 10_000e6);

        vm.prank(poolOwner);
        IAHyperliquid(pool).registerPredictionToken(_HIP4_ASSET_ID, _HIP4_SPOT_INDEX, _HIP4_TOKEN_INDEX);

        HyperliquidLib.LimitOrderParams memory params = HyperliquidLib.LimitOrderParams({
            asset: uint32(_HIP4_ASSET_ID),
            isBuy: true,
            limitPx: 47_400_000,
            sz: 22,
            reduceOnly: false,
            encodedTif: 3,
            cloid: 0
        });

        vm.prank(poolOwner);
        IAHyperliquid(pool).submitPredictionOrder(params);

        // Same-block NAV read succeeds because the USDC spot deposit is still in-flight.
        _mockSpotBalance(pool, 0, uint64(10_000e6) * 1e2);
        _mockSpotBalance(pool, _HIP4_TOKEN_INDEX, 22e8); // outcome tokens bought
        NetAssetsValue memory nav = ISmartPoolActions(pool).updateUnitaryValue();
        assertGt(nav.unitaryValue, 0, "Unitary value should be positive after prediction order");
    }
}
