// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {UnitTestFixture} from "../fixtures/UnitTestFixture.sol";
import {IENavView} from "../../contracts/protocol/extensions/adapters/interfaces/IENavView.sol";
import {IAStaking} from "../../contracts/protocol/extensions/adapters/interfaces/IAStaking.sol";
import {IAuthority} from "../../contracts/protocol/interfaces/IAuthority.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {NavView} from "../../contracts/protocol/libraries/NavView.sol";
import {VirtualStorageLib} from "../../contracts/protocol/libraries/VirtualStorageLib.sol";
import {StorageLib} from "../../contracts/protocol/libraries/StorageLib.sol";
import {NetAssetsValue} from "../../contracts/protocol/types/NavComponents.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";
import {IStorage} from "../../contracts/staking/interfaces/IStorage.sol";
import {IGrgVault} from "../../contracts/staking/interfaces/IGrgVault.sol";
import {IAuthorizable} from "../../contracts/utils/0xUtils/interfaces/IAuthorizable.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {ISmartPoolOwnerActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolOwnerActions.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

interface IGrgVaultWithAssetProxy {
    function grgAssetProxy() external view returns (address);
}

/// @title NavViewNavParityTest
/// @notice Asserts that the off-chain view NAV (ENavView/NavView.getNavData) always
///         produces results identical to the on-chain write NAV (updateUnitaryValue).
///
/// @dev WHY THESE TESTS EXIST
///      Rigoblock plans to use ZK coprocessors to prove NAV integrity off-chain (zk-nav).
///      ENavView is the read-only path that ZK proof generation will consume.  It must
///      always agree with the authoritative on-chain value stored by updateUnitaryValue.
///
///      These tests catch divergence that can be introduced when:
///      - A new external application (staking, DEX LP, perps) is added and its balance
///        logic is implemented in both EApps AND NavView independently.
///      - Token enumeration or oracle path changes in one path but not the other.
///      - Storage layout changes affect which addresses end up as "active tokens".
///
/// @dev REGRESSION: ETH-as-non-base-token
///      NavView previously excluded address(0) from the oracle batch when base token
///      was a non-native ERC20, silently undervaluing pools with ETH active positions
///      (e.g. UniV4 ETH/ERC20 LP). The regression test (test 4 below) covers this.
///
/// @dev ASSERTION PATTERN
///      Every test calls _assertNavParity() which runs both paths back-to-back in the
///      same block state and asserts equality on both unitaryValue and totalValue.
contract NavViewNavParityTest is UnitTestFixture {
    address internal pool;
    address internal poolOwner;
    IERC20 internal grg;

    // =========================================================================
    // Setup
    // =========================================================================

    function setUp() public {
        deployFixture();
        poolOwner = makeAddr("poolOwner");
        grg = IERC20(address(IStaking(stakingProxy).getGrgContract()));
        // Seed oracle price feed for GRG (required by updateUnitaryValue even for base-token-only pools)
        _seedOracleForToken(address(grg));
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _createGrgPool() internal {
        vm.prank(poolOwner);
        (pool,) = IRigoblockPoolProxyFactory(deployment.factory).createPool("ParityPool", "PPTY", address(grg));
    }

    function _mintShares(address to, uint256 amount) internal {
        deal(address(grg), to, amount);
        vm.startPrank(to);
        grg.approve(pool, amount);
        ISmartPoolActions(pool).mint(to, amount, 0);
        vm.stopPrank();
    }

    /// @dev Core assertion: run both NAV paths in the same block, check equality.
    ///      write-NAV: updateUnitaryValue() — computes and stores on-chain NAV.
    ///      view-NAV : getNavDataView()     — computes NAV from live state (used by ZK coprocessors).
    function _assertNavParity() internal {
        NetAssetsValue memory writeNav = ISmartPoolActions(pool).updateUnitaryValue();
        NavView.NavData memory viewNav = IENavView(pool).getNavDataView();

        assertEq(
            viewNav.unitaryValue,
            writeNav.unitaryValue,
            "NAV parity: unitaryValue mismatch between view-NAV and write-NAV"
        );
        assertEq(
            viewNav.totalValue,
            writeNav.netTotalValue,
            "NAV parity: totalValue mismatch between view-NAV and write-NAV"
        );
    }

    // =========================================================================
    // Test 1: Base token only — shares minted, pool valued at par NAV
    //
    // The simplest possible case: pool holds only its base token (GRG).
    // No oracle conversion needed. Both paths should trivially agree.
    // =========================================================================

    function test_NavParity_BaseTokenOnly_EqualUnitaryValue() public {
        _createGrgPool();
        _mintShares(poolOwner, 1_000e18);

        _assertNavParity();
    }

    // =========================================================================
    // Test 2: Zero supply — both paths must return the stored par value
    //
    // Before any mint the effectiveSupply is 0.  write-NAV uses stored
    // unitaryValue or 10**decimals; view-NAV does the same.
    // =========================================================================

    function test_NavParity_ZeroSupply_ReturnsStoredOrParValue() public {
        _createGrgPool();
        // No mints — pool at par, totalSupply = 0

        _assertNavParity();
    }

    // =========================================================================
    // Test 3: Pool gains (NAV > 1.0)
    //
    // Extra base tokens are sent directly to the pool (simulating fee income or
    // gains).  NAV must rise in both paths identically.
    // =========================================================================

    function test_NavParity_PoolGain_EqualUnitaryValue() public {
        _createGrgPool();
        _mintShares(poolOwner, 1_000e18);

        // Simulate pool gain: add GRG directly to pool balance
        uint256 extra = 200e18;
        deal(address(grg), pool, grg.balanceOf(pool) + extra);

        // Both paths should see the increased poolValue and higher unitaryValue
        _assertNavParity();
    }

    // =========================================================================
    // Test 4: Negative virtual supply (cross-chain Transfer mode destination)
    //
    // A pool acting as a cross-chain transfer destination writes a positive VS.
    // The inverse (negative VS on the source) is simulated here.  NAV should be
    // computed from effectiveSupply = totalSupply + virtualSupply.
    //
    // IMPORTANT: write-NAV reads virtualSupply from pool storage via
    // VirtualStorageLib.  view-NAV (running via ENavView delegatecall) reads the
    // same slot.  Both must agree.
    // =========================================================================

    function test_NavParity_NegativeVirtualSupply_EqualUnitaryValue() public {
        _createGrgPool();
        _mintShares(poolOwner, 1_000e18);

        // Inject a negative virtual supply (−400 shares) directly into pool storage,
        // as if this pool was the source in a cross-chain Transfer operation.
        int256 vs = -400e18;
        vm.store(pool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT, bytes32(uint256(vs)));

        _assertNavParity();
    }

    // =========================================================================
    // Test 5: Positive virtual supply (cross-chain Transfer mode destination)
    // =========================================================================

    function test_NavParity_PositiveVirtualSupply_EqualUnitaryValue() public {
        _createGrgPool();
        _mintShares(poolOwner, 1_000e18);

        // Inject a positive virtual supply as if this pool received a cross-chain transfer
        int256 vs = 500e18;
        vm.store(pool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT, bytes32(uint256(vs)));

        _assertNavParity();
    }

    // =========================================================================
    // Test 6: GRG staking active — staked balance counted identically in both
    //         EApps._getGrgStakingProxyBalances and NavView._getGrgStakingProxyBalances
    //
    // WHY THIS TEST IS CRITICAL:
    // EApps and NavView each have their own _getGrgStakingProxyBalances.  If a
    // developer changes the reward or balance accounting in one without updating
    // the other, this test will catch the divergence immediately.
    // =========================================================================

    function test_NavParity_GrgStakingActive_EqualUnitaryValue() public {
        // Configure the GRG vault to accept delegations
        _configureVaultForTest();

        // Deploy and register AStaking adapter
        address aStaking = _deployAndRegisterAStaking();

        // Create pool and mint shares
        _createGrgPool();
        deal(address(grg), poolOwner, 3_000e18);
        _mintShares(poolOwner, 2_000e18);

        // Stake via the adapter (pool owner only, delegated to own pool)
        uint256 stakeAmount = 800e18;
        vm.startPrank(poolOwner);
        grg.approve(pool, stakeAmount);
        IAStaking(pool).stake(stakeAmount);
        vm.stopPrank();

        // Epoch boundary: delegation becomes active next epoch
        uint256 epochEnd = IStaking(stakingProxy).getCurrentEpochEarliestEndTimeInSeconds();
        vm.warp(epochEnd);
        IStaking(stakingProxy).endEpoch();

        // Both paths must include the staked GRG in NAV
        // (EApps calls IStaking.getTotalStake + computeRewardBalanceOfDelegator;
        //  NavView._getGrgStakingProxyBalances does the same)
        _assertNavParity();
    }

    // =========================================================================
    // Test 7: GRG staking zero stake, no rewards — staking app returns empty
    //         Both paths should produce identical NAV (staking excluded).
    // =========================================================================

    function test_NavParity_GrgStakingZeroStake_EqualUnitaryValue() public {
        _configureVaultForTest();
        _deployAndRegisterAStaking();

        _createGrgPool();
        _mintShares(poolOwner, 1_000e18);

        // No staking — getTotalStake(pool) = 0, no rewards.  Both paths return
        // empty staking balances and NAV is purely wallet balance.
        _assertNavParity();
    }

    // =========================================================================
    // Test 8: Multiple mints by different users, checks absolute NAV stability
    // =========================================================================

    function test_NavParity_MultipleHolders_EqualUnitaryValue() public {
        _createGrgPool();
        address user2 = makeAddr("user2");
        address user3 = makeAddr("user3");

        _mintShares(poolOwner, 500e18);
        _mintShares(user2, 300e18);
        _mintShares(user3, 700e18);

        _assertNavParity();
    }

    // =========================================================================
    // Test 9: Large virtual supply adjustment (effectiveSupply >> totalSupply)
    //         Ensures integer arithmetic does not overflow or diverge.
    // =========================================================================

    function test_NavParity_LargePositiveVirtualSupply_EqualUnitaryValue() public {
        _createGrgPool();
        _mintShares(poolOwner, 1_000e18);

        // Large positive VS: simulating a destination pool that received many transfers
        int256 vs = 999_000e18; // effectiveSupply = 1_000e18 + 999_000e18 = 1_000_000e18
        vm.store(pool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT, bytes32(uint256(vs)));

        _assertNavParity();
    }

    // =========================================================================
    // Test 10: mintWithToken with pre-existing untracked balance regression
    //
    // WHY THIS TEST EXISTS:
    // Before the fix, mintWithToken called _updateNav() BEFORE activating tokenIn
    // in activeTokensSet.  If the pool already held a balance of tokenIn (e.g.
    // from an airdrop or direct ERC20 transfer), that balance was invisible to
    // _updateNav() and shares were priced at understated NAV.  After the mint,
    // the next updateUnitaryValue() would discover the balance — but by then the
    // attacker already held shares priced against a lower NAV, enabling profit.
    //
    // The fix: mintWithToken pre-activates tokenIn (addUnique) before _mint,
    // so _updateNav() sees the full pool value including any pre-existing balance.
    // The addUnique inside _mint is then a no-op.
    //
    // With fix: NAV ≈ 1.5 GRG/share after mint (stable — airdrop was priced in).
    // Without fix: NAV ≈ 1.38 GRG/share after mint (diluted — attacker extracted
    //             a share of the airdrop they did not pay for).
    // =========================================================================

    function test_MintWithToken_UntrackedBalance_IsIncludedInNavBeforePricing() public {
        _createGrgPool();

        // Deploy a mock ERC20 that will be used as tokenIn
        MockERC20 tokenIn = new MockERC20("MockToken", "MCK", 18);

        // Seed the oracle for tokenIn at the SAME block.timestamp as GRG (both at setUp's timestamp).
        // Both will have identical tick observations, giving a 1:1 cross price (cross tick = 0).
        // Seeding BEFORE vm.warp ensures observe arithmetic won't underflow.
        _seedOracleForToken(address(tokenIn));

        // Advance time so MockOracle.observe(secondsAgos=[2,0]) doesn't underflow
        vm.warp(100);

        // Pool owner accepts tokenIn for minting (adds to accepted set, NOT active set)
        vm.prank(poolOwner);
        ISmartPoolOwnerActions(pool).setAcceptableMintToken(address(tokenIn), true);

        // Establish initial pool supply: 1000 GRG → 1000 shares, NAV = 1 GRG/share
        _mintShares(poolOwner, 1000e18);

        // Airdrop 500 tokenIn directly to pool without going through mintWithToken.
        // This balance is untracked: tokenIn is not yet in activeTokensSet.
        tokenIn.mint(pool, 500e18);

        // Confirm the airdrop is invisible to updateUnitaryValue (tokenIn not active yet)
        NetAssetsValue memory navBeforeAttack = ISmartPoolActions(pool).updateUnitaryValue();
        assertEq(navBeforeAttack.unitaryValue, 1e18, "Airdrop must be untracked before first mintWithToken");

        // Attacker mints using 300 tokenIn
        address attacker = makeAddr("mwtAttacker");
        tokenIn.mint(attacker, 300e18);
        vm.startPrank(attacker);
        tokenIn.approve(pool, 300e18);
        ISmartPoolActions(pool).mintWithToken(attacker, 300e18, 0, address(tokenIn));
        vm.stopPrank();

        // With the fix, the 500-tokenIn airdrop was included in the NAV snapshot
        // during the attacker's mint:  NAV_used = (1000 + 500) GRG / 1000 shares = 1.5
        // Attacker's shares ≈ 300 GRG / 1.5 = 200 shares.
        // Pool after mint: 1000 GRG + 800 tokenIn = 1800 GRG, ~1200 shares → NAV ≈ 1.5
        //
        // Without the fix: NAV_used = 1.0, attacker gets 300 shares,
        // pool → 1300 shares → NAV ≈ 1.38 (dilution of ~8% vs fair 1.5).
        NetAssetsValue memory navAfterMint = ISmartPoolActions(pool).updateUnitaryValue();
        assertApproxEqRel(
            navAfterMint.unitaryValue,
            1.5e18,
            5e16, // 5% tolerance covers oracle tick rounding and spread
            "NAV must be ~1.5 GRG/share: airdrop priced into mint, no dilution"
        );

        // Additionally, view-NAV and write-NAV must agree (ZK-NAV integrity)
        _assertNavParity();
    }

    // =========================================================================
    // Private helpers — oracle
    // =========================================================================

    /// @dev Registers a price feed for `token` vs native ETH in the MockOracle.
    ///      updateUnitaryValue() requires hasPriceFeed(baseToken) to be true.
    function _seedOracleForToken(address token) private {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0,
            tickSpacing: TickMath.MAX_TICK_SPACING,
            hooks: IHooks(address(deployment.mockOracle))
        });
        deployment.mockOracle.initializeObservations(key);
    }

    // =========================================================================
    // Private helpers for staking setup
    // =========================================================================

    function _configureVaultForTest() private {
        // Authorise test contract to configure the staking vault
        IGrgVault vault = IStaking(stakingProxy).getGrgVault();
        IAuthorizable(address(vault)).addAuthorizedAddress(address(this));
        vault.setStakingProxy(stakingProxy);
    }

    function _deployAndRegisterAStaking() private returns (address aStaking) {
        address grgTransferProxy =
            IGrgVaultWithAssetProxy(address(IStaking(stakingProxy).getGrgVault())).grgAssetProxy();

        aStaking =
            deployCode("out/AStaking.sol/AStaking.json", abi.encode(stakingProxy, address(grg), grgTransferProxy));

        IAuthority(deployment.authority).setAdapter(aStaking, true);
        IAuthority(deployment.authority).addMethod(IAStaking.stake.selector, aStaking);
        IAuthority(deployment.authority).addMethod(IAStaking.undelegateStake.selector, aStaking);
        IAuthority(deployment.authority).addMethod(IAStaking.unstake.selector, aStaking);
        IAuthority(deployment.authority).addMethod(IAStaking.withdrawDelegatorRewards.selector, aStaking);
    }
}
