// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Position} from "gmx-synthetics/position/Position.sol";
import {
    IGmxReader,
    GmxOrderInfo
} from "../../contracts/utils/exchanges/gmx/IGmxSynthetics.sol";
import {AppTokenBalance} from "../../contracts/protocol/types/ExternalApp.sol";
import {NavView} from "../../contracts/protocol/libraries/NavView.sol";
import {StorageLib} from "../../contracts/protocol/libraries/StorageLib.sol";
import {VirtualStorageLib} from "../../contracts/protocol/libraries/VirtualStorageLib.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {IEOracle} from "../../contracts/protocol/extensions/adapters/interfaces/IEOracle.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";
import {IStorage} from "../../contracts/staking/interfaces/IStorage.sol";

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------
// NavView is an internal library.  When a test calls harness.getNavData(...),
// the library runs in the HARNESS's execution context:
//   - StorageLib.pool().baseToken / .decimals    → read from harness storage
//   - VirtualStorageLib.getVirtualSupply()        → read from harness storage
//   - ISmartPoolState(pool).getActiveApplications() → external call to POOL
//   - ISmartPoolState(pool).getActiveTokens()       → external call to POOL
//   - ISmartPoolState(pool).getPoolTokens()          → external call to POOL
//   - IEOracle(pool).convertBatchTokenAmounts()      → external call to POOL
//   - IERC20(token).balanceOf(pool)                  → external call to TOKEN
//   - IStaking(grgProxy).getTotalStake(pool)         → external call to GRG_PROXY
//   - GmxLib.getGmxPositionBalances(pool)            → external calls to GMX_READER
//
// Pool storage (baseToken, decimals) is initialised in the constructor using
// real StorageLib accessors — no manual vm.store bit manipulation needed.
// Virtual supply is set via the dedicated setter.
contract NavViewHarness {
    constructor(address baseToken, uint8 decimals) {
        StorageLib.pool().baseToken = baseToken;
        StorageLib.pool().decimals = decimals;
    }

    function getAppTokenBalances(
        address pool,
        address grgStakingProxy,
        address uniV4Posm
    ) external view returns (AppTokenBalance[] memory) {
        return NavView.getAppTokenBalances(pool, grgStakingProxy, uniV4Posm);
    }

    function getNavData(
        address pool,
        address grgStakingProxy,
        address uniV4Posm
    ) external view returns (NavView.NavData memory) {
        return NavView.getNavData(pool, grgStakingProxy, uniV4Posm);
    }

    function setVirtualSupplyForTest(int256 vs) external {
        bytes32 slot = VirtualStorageLib.VIRTUAL_SUPPLY_SLOT;
        assembly {
            sstore(slot, vs)
        }
    }
}

/// @title NavViewTest
/// @notice Non-fork unit tests for the NavView library.
contract NavViewTest is Test {
    // GMX hardcoded Reader address (same as in GmxLib)
    address internal constant GMX_READER = 0x470fbC46bcC0f16532691Df360A07d8Bf5ee0789;

    // Applications enum: GRG_STAKING=0, UNIV4_LIQUIDITY=1, GMX_V2_POSITIONS=2
    uint256 constant GMX_V2_BIT = 1 << 2; // 4

    address internal constant POOL = address(0x1000);
    address internal constant GRG_STAKING_PROXY = address(0x2000);
    address internal constant UNI_V4_POSM = address(0x3000);
    address internal constant BASE_TOKEN = address(0x4000);
    address internal constant OTHER_TOKEN = address(0x5000);
    address internal constant GRG_TOKEN = address(0x6000);

    NavViewHarness internal harness;

    function setUp() public {
        harness = new NavViewHarness(BASE_TOKEN, 18);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _setVirtualSupply(int256 vs) internal {
        harness.setVirtualSupplyForTest(vs);
    }

    function _mockGrgZeroStake() internal {
        vm.mockCall(
            GRG_STAKING_PROXY,
            abi.encodeWithSelector(IStaking.getTotalStake.selector, POOL),
            abi.encode(uint256(0))
        );
    }

    function _mockActiveApplications(uint256 packedApps) internal {
        vm.mockCall(
            POOL,
            abi.encodeWithSelector(ISmartPoolState.getActiveApplications.selector),
            abi.encode(packedApps)
        );
    }

    function _mockActiveTokens() internal {
        address[] memory activeTokens = new address[](0);
        ISmartPoolState.ActiveTokens memory at =
            ISmartPoolState.ActiveTokens({activeTokens: activeTokens, baseToken: BASE_TOKEN});
        vm.mockCall(
            POOL,
            abi.encodeWithSelector(ISmartPoolState.getActiveTokens.selector),
            abi.encode(at)
        );
    }

    function _mockBaseTokenBalance(uint256 amount) internal {
        vm.mockCall(
            BASE_TOKEN,
            abi.encodeWithSelector(bytes4(keccak256("balanceOf(address)")), POOL),
            abi.encode(amount)
        );
    }

    function _mockPoolTokens(uint256 unitaryValue, uint256 totalSupply) internal {
        ISmartPoolState.PoolTokens memory pt =
            ISmartPoolState.PoolTokens({unitaryValue: unitaryValue, totalSupply: totalSupply});
        vm.mockCall(
            POOL,
            abi.encodeWithSelector(ISmartPoolState.getPoolTokens.selector),
            abi.encode(pt)
        );
    }

    function _mockGmxEmpty() internal {
        Position.Props[] memory emptyPos = new Position.Props[](0);
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountPositions.selector),
            abi.encode(emptyPos)
        );
        GmxOrderInfo[] memory emptyOrders = new GmxOrderInfo[](0);
        vm.mockCall(
            GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountOrders.selector),
            abi.encode(emptyOrders)
        );
    }

    // =========================================================================
    // getAppTokenBalances — GRG staking
    // =========================================================================

    function test_GetAppTokenBalances_GrgZeroStake_EmptyResult() public {
        _mockActiveApplications(0);
        _mockGrgZeroStake();

        AppTokenBalance[] memory balances =
            harness.getAppTokenBalances(POOL, GRG_STAKING_PROXY, UNI_V4_POSM);
        assertEq(balances.length, 0);
    }

    function test_GetAppTokenBalances_GrgPositiveStake() public {
        _mockActiveApplications(0);

        uint256 stakingBalance = 100e18;
        uint256 rewardBalance = 50e18;
        bytes32 poolId = bytes32(uint256(1));

        vm.mockCall(
            GRG_STAKING_PROXY,
            abi.encodeWithSelector(IStaking.getTotalStake.selector, POOL),
            abi.encode(stakingBalance)
        );
        vm.mockCall(
            GRG_STAKING_PROXY,
            abi.encodeWithSelector(IStaking.getGrgContract.selector),
            abi.encode(GRG_TOKEN)
        );
        vm.mockCall(
            GRG_STAKING_PROXY,
            abi.encodeWithSelector(IStorage.poolIdByRbPoolAccount.selector, POOL),
            abi.encode(poolId)
        );
        vm.mockCall(
            GRG_STAKING_PROXY,
            abi.encodeWithSelector(IStaking.computeRewardBalanceOfDelegator.selector, poolId, POOL),
            abi.encode(rewardBalance)
        );

        AppTokenBalance[] memory balances =
            harness.getAppTokenBalances(POOL, GRG_STAKING_PROXY, UNI_V4_POSM);

        assertEq(balances.length, 1);
        assertEq(balances[0].token, GRG_TOKEN);
        assertEq(balances[0].amount, int256(stakingBalance + rewardBalance));
    }

    // =========================================================================
    // getAppTokenBalances — GMX_V2_POSITIONS branch
    // =========================================================================

    function test_GetAppTokenBalances_GmxBitSet_EmptyPositions() public {
        _mockActiveApplications(GMX_V2_BIT);
        _mockGrgZeroStake();
        _mockGmxEmpty();

        AppTokenBalance[] memory balances =
            harness.getAppTokenBalances(POOL, GRG_STAKING_PROXY, UNI_V4_POSM);
        assertEq(balances.length, 0);
    }

    // =========================================================================
    // getNavData — base token only
    // =========================================================================

    function test_GetNavData_BaseTokenOnly() public {
        _mockActiveApplications(0);
        _mockGrgZeroStake();
        _mockActiveTokens();
        _mockBaseTokenBalance(1000e18);
        _mockPoolTokens(1e18, 1000e18);

        NavView.NavData memory data = harness.getNavData(POOL, GRG_STAKING_PROXY, UNI_V4_POSM);

        assertEq(data.totalValue, 1000e18);
        assertEq(data.unitaryValue, 1e18); // 1000e18 * 1e18 / 1000e18 = 1e18
        assertEq(data.timestamp, block.timestamp);
    }

    // =========================================================================
    // getNavData — non-base token with batch conversion
    // =========================================================================

    function test_GetNavData_WithNonBaseToken_BatchConversion() public {
        _mockActiveApplications(0);
        _mockGrgZeroStake();

        address[] memory activeTokens = new address[](1);
        activeTokens[0] = OTHER_TOKEN;
        ISmartPoolState.ActiveTokens memory at =
            ISmartPoolState.ActiveTokens({activeTokens: activeTokens, baseToken: BASE_TOKEN});
        vm.mockCall(POOL, abi.encodeWithSelector(ISmartPoolState.getActiveTokens.selector), abi.encode(at));

        _mockBaseTokenBalance(500e18);
        vm.mockCall(
            OTHER_TOKEN,
            abi.encodeWithSelector(bytes4(keccak256("balanceOf(address)")), POOL),
            abi.encode(uint256(50e18))
        );

        // 50 OTHER_TOKEN → 50 BASE_TOKEN
        vm.mockCall(
            POOL,
            abi.encodeWithSelector(IEOracle.convertBatchTokenAmounts.selector),
            abi.encode(int256(50e18))
        );

        _mockPoolTokens(1e18, 550e18);

        NavView.NavData memory data = harness.getNavData(POOL, GRG_STAKING_PROXY, UNI_V4_POSM);

        assertEq(data.totalValue, 550e18);
        assertEq(data.unitaryValue, 1e18);
    }

    // =========================================================================
    // getNavData — batch conversion fails → zero NavData
    // =========================================================================

    function test_GetNavData_ConversionFails_ReturnsZeroNavData() public {
        _mockActiveApplications(0);
        _mockGrgZeroStake();

        address[] memory activeTokens = new address[](1);
        activeTokens[0] = OTHER_TOKEN;
        ISmartPoolState.ActiveTokens memory at =
            ISmartPoolState.ActiveTokens({activeTokens: activeTokens, baseToken: BASE_TOKEN});
        vm.mockCall(POOL, abi.encodeWithSelector(ISmartPoolState.getActiveTokens.selector), abi.encode(at));

        _mockBaseTokenBalance(500e18);
        vm.mockCall(
            OTHER_TOKEN,
            abi.encodeWithSelector(bytes4(keccak256("balanceOf(address)")), POOL),
            abi.encode(uint256(50e18))
        );

        vm.mockCallRevert(
            POOL,
            abi.encodeWithSelector(IEOracle.convertBatchTokenAmounts.selector),
            abi.encode("oracle error")
        );

        _mockPoolTokens(1e18, 550e18);

        NavView.NavData memory data = harness.getNavData(POOL, GRG_STAKING_PROXY, UNI_V4_POSM);

        assertEq(data.totalValue, 0);
        assertEq(data.unitaryValue, 0);
        assertEq(data.timestamp, 0);
    }

    // =========================================================================
    // getNavData — effectiveSupply <= 0 → use stored unitaryValue
    // =========================================================================

    function test_GetNavData_ZeroEffectiveSupply_UsesStoredUnitaryValue() public {
        _setVirtualSupply(-int256(1000e18));

        _mockActiveApplications(0);
        _mockGrgZeroStake();
        _mockActiveTokens();
        _mockBaseTokenBalance(0);
        _mockPoolTokens(2e18, 0); // stored unitaryValue = 2e18, totalSupply = 0

        NavView.NavData memory data = harness.getNavData(POOL, GRG_STAKING_PROXY, UNI_V4_POSM);

        // effectiveSupply = 0 + (-1000e18) < 0 → use stored unitaryValue = 2e18
        assertEq(data.unitaryValue, 2e18);
    }

    // =========================================================================
    // getNavData — supply exists but value is 0 → unitaryValue = 0
    // =========================================================================

    function test_GetNavData_PositiveSupply_ZeroTotalValue_ReturnsZeroUnitaryValue() public {
        _mockActiveApplications(0);
        _mockGrgZeroStake();
        _mockActiveTokens();
        _mockBaseTokenBalance(0); // pool has no assets
        _mockPoolTokens(1e18, 100e18);

        NavView.NavData memory data = harness.getNavData(POOL, GRG_STAKING_PROXY, UNI_V4_POSM);

        // totalValue = 0, effectiveSupply > 0 → unitaryValue = 0
        assertEq(data.totalValue, 0);
        assertEq(data.unitaryValue, 0);
    }

    // =========================================================================
    // getNavData — with GMX active and no positions
    // =========================================================================

    function test_GetNavData_GmxBitActive_EmptyGmxPositions() public {
        _mockActiveApplications(GMX_V2_BIT);
        _mockGrgZeroStake();
        _mockGmxEmpty();
        _mockActiveTokens();
        _mockBaseTokenBalance(500e18);
        _mockPoolTokens(1e18, 500e18);

        NavView.NavData memory data = harness.getNavData(POOL, GRG_STAKING_PROXY, UNI_V4_POSM);

        assertEq(data.totalValue, 500e18);
        assertEq(data.unitaryValue, 1e18);
    }

    // =========================================================================
    // getNavData — positive virtual supply adjusts effectiveSupply
    // =========================================================================

    function test_GetNavData_PositiveVirtualSupply_AdjustsEffectiveSupply() public {
        _setVirtualSupply(int256(500e18));

        _mockActiveApplications(0);
        _mockGrgZeroStake();
        _mockActiveTokens();
        _mockBaseTokenBalance(1500e18);
        _mockPoolTokens(1e18, 1000e18); // totalSupply = 1000, VS = +500 → effective = 1500

        NavView.NavData memory data = harness.getNavData(POOL, GRG_STAKING_PROXY, UNI_V4_POSM);

        // unitaryValue = 1500e18 * 1e18 / 1500e18 = 1e18
        assertEq(data.totalValue, 1500e18);
        assertEq(data.unitaryValue, 1e18);
    }
}
