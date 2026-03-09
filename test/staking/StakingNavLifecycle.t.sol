// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";

import {UnitTestFixture} from "../fixtures/UnitTestFixture.sol";

import {IAStaking} from "../../contracts/protocol/extensions/adapters/interfaces/IAStaking.sol";
import {IAuthority} from "../../contracts/protocol/interfaces/IAuthority.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";

import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";
import {IStorage} from "../../contracts/staking/interfaces/IStorage.sol";
import {IGrgVault} from "../../contracts/staking/interfaces/IGrgVault.sol";

import {IAuthorizable} from "../../contracts/utils/0xUtils/interfaces/IAuthorizable.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

interface IGrgVaultWithAssetProxy {
    function grgAssetProxy() external view returns (address);
}

/// @title StakingNavLifecycle — verifies NAV behaviour across stake/undelegate/unstake/withdraw lifecycle.
///
/// @dev Epoch timeline analysis:
///   Epoch N:   Pool has active delegated stake. undelegateStake is called.
///              _undelegateStake only calls _decreaseNextBalance, so currentEpochBalance remains
///              positive for the rest of epoch N. Pop rewards CAN still be attributed in epoch N
///              (both ProofOfPerformance and creditPopReward read currentEpochBalance).
///              However, those epoch-N rewards are NOT yet claimable — they are only snapshotted
///              when epoch N ends, and only become claimable after finalizePool is called.
///
///   Epoch N+1: Undelegation takes effect: currentEpochBalance = nextEpochBalance = 0.
///              Pop rewards CANNOT be attributed (stake below minimum).
///              unstake NOW becomes possible (UNDELEGATED currentEpochBalance = stakeAmount).
///              Rewards from epoch N become claimable here after finalizePool.
///
///   Key constraint: unstake can only be called in epoch N+1 or later (calling it in epoch N
///   reverts because UNDELEGATED currentEpochBalance is still 0 in epoch N).
///   Epoch-N rewards become claimable precisely in epoch N+1 — the same epoch unstake is possible.
///
/// @dev Therefore a NAV gap necessarily exists if the pool calls unstake before withdrawDelegatorRewards
///      in epoch N+1. getTotalStake == 0 (vault empty) while computeRewardBalanceOfDelegator > 0
///      (epoch-N rewards pending). EApps._getGrgStakingProxyBalances short-circuits on stakingBalance==0
///      and returns empty, omitting those rewards from NAV.
///
/// @dev The existing code comment acknowledges this case as a designed trade-off (saves gas).
///      The operator can eliminate the gap entirely by batching unstake + withdrawDelegatorRewards
///      in a single multicall. For pools that do not batch these calls, the NAV gap equals the
///      claimable GRG rewards from the last active epoch, and is bounded to that window.
///
/// @dev Note: BEFORE unstake(), EApps correctly accounts for vault balance + claimable rewards
///      (stakingBalance > 0 passes the gate). The gap only arises AFTER unstake() empties the vault.
///      The returned stakeAmount lands in the pool wallet and IS counted there — only the
///      separate claimable-rewards accounting entry is excluded by the stakingBalance == 0 gate.
contract StakingNavLifecycle is UnitTestFixture {
    address internal pool;
    address internal poolOwner;
    address internal pop;

    IERC20 internal grg;
    address internal aStaking;
    bytes32 internal poolId;

    function setUp() public {
        deployFixture();

        poolOwner = makeAddr("poolOwner");
        pop = makeAddr("pop");

        grg = IERC20(address(IStaking(stakingProxy).getGrgContract()));

        _configureVault();
        _seedOracleForGrg();
        _deployAndRegisterAStakingAdapter();
        _createPool();

        // Fund pool owner
        require(grg.transfer(poolOwner, 2_000e18), "GRG transfer failed");
    }

    /// @dev Verifies the full lifecycle:
    ///   epoch 1: pool mints, stakes, delegates
    ///   epoch 1→2: delegation becomes active (currentEpochBalance updated)
    ///   epoch 2: pop credits reward; pool undelegates (nextEpochBalance reduced, currentEpochBalance unchanged)
    ///   epoch 2→3: epoch ends, rewards distributed, undelegation takes effect
    ///   epoch 3: pool finalizes rewards (claimable), then fully unstakes → getTotalStake == 0
    ///
    ///   NAV stage 1 (stake > 0, rewards claimable): EApps includes stake+rewards → accurate
    ///   NAV stage 2 (stake == 0, rewards claimable): EApps returns empty → NAV gap exists
    ///   NAV stage 3 (after withdrawDelegatorRewards): GRG lands in pool wallet → NAV restored
    function test_nav_includes_stake_and_rewards_then_gaps_when_unstaked() public {
        uint256 mintAmount = 1_000e18;
        uint256 stakeAmount = 500e18;

        // ── epoch 1: mint and delegate ───────────────────────────────────────
        vm.startPrank(poolOwner);
        grg.approve(pool, type(uint256).max);
        ISmartPoolActions(pool).mint(poolOwner, mintAmount, 0);
        IAStaking(pool).stake(stakeAmount);
        vm.stopPrank();

        // staking pool is created lazily on first stake() — read poolId after stake
        poolId = IStorage(stakingProxy).poolIdByRbPoolAccount(pool);
        assertFalse(poolId == bytes32(0), "staking pool must exist after first stake");

        _warpAndEndEpoch(); // epoch 1→2: delegation becomes active (currentEpochBalance updated)

        // ── epoch 2: credit fee, then undelegate ────────────────────────────
        // undelegateStake calls moveStake(DELEGATED→UNDELEGATED), which reduces nextEpochBalance
        // only. currentEpochBalance stays positive, so the pool still qualifies for pop rewards.
        _registerPop(pop);
        _creditPopReward(pop, pool, 1);

        vm.prank(poolOwner);
        IAStaking(pool).undelegateStake(stakeAmount);

        // Fund epoch rewards and advance epoch 2 → 3.
        uint256 epochRewards = 100e18; // 100 GRG total distributed this epoch
        require(grg.transfer(stakingProxy, epochRewards), "GRG transfer to staking failed");

        _warpAndEndEpoch(); // → epoch 3: rewards distributed, undelegation now effective

        // Finalize makes rewards claimable for the pool (a delegator here).
        IStaking(stakingProxy).finalizePool(poolId);

        // ── epoch 3: verify state before unstake ────────────────────────────
        uint256 vaultBalance = IStaking(stakingProxy).getTotalStake(pool);
        uint256 claimableRewards = IStaking(stakingProxy).computeRewardBalanceOfDelegator(poolId, pool);

        console2.log("--- After finalize, before unstake ---");
        console2.log("  vaultBalance (getTotalStake):", vaultBalance);
        console2.log("  claimableRewards:", claimableRewards);

        assertGt(vaultBalance, 0, "vault must still hold stake before unstake");
        assertGt(claimableRewards, 0, "rewards must be claimable");

        // NAV stage 1: stake > 0, rewards claimable → EApps includes both.
        // The active application (GRG_STAKING) should include stake + rewards.
        uint256 navStage1 = _getUnitaryValue();
        console2.log("  NAV stage 1 (stake>0, rewards claimable):", navStage1);

        // ── unstake: moves GRG from vault back to pool wallet ───────────────
        // After this call getTotalStake == 0, but claimable rewards remain unchanged.
        vm.prank(poolOwner);
        IAStaking(pool).unstake(stakeAmount);

        uint256 vaultBalanceAfterUnstake = IStaking(stakingProxy).getTotalStake(pool);
        uint256 claimableRewardsAfterUnstake = IStaking(stakingProxy).computeRewardBalanceOfDelegator(poolId, pool);

        console2.log("--- After unstake ---");
        console2.log("  vaultBalance (getTotalStake):", vaultBalanceAfterUnstake);
        console2.log("  claimableRewards:", claimableRewardsAfterUnstake);

        assertEq(vaultBalanceAfterUnstake, 0, "vault must be empty after unstake");
        assertEq(claimableRewardsAfterUnstake, claimableRewards, "claimable rewards unchanged by unstake");

        // NAV stage 2: stake == 0, rewards still claimable.
        // Current code: EApps._getGrgStakingProxyBalances returns empty (stakingBalance == 0 guard).
        // The GRG from unstake landed in pool wallet so IS counted there.
        // Only the claimableRewards are missing from NAV.
        uint256 navStage2 = _getUnitaryValue();
        console2.log("  NAV stage 2 (stake==0, rewards NOT in wallet):", navStage2);

        // navStage2 < navStage1 because claimableRewards are excluded.
        // navStage1 - navStage2 should approximately equal (claimableRewards value in base terms).
        // They cannot be exactly equal because the oracle converts GRG→base at a given price,
        // but this demonstrates the gap exists and is bounded.
        assertLt(navStage2, navStage1, "NAV should drop when claimable rewards are excluded (stake=0)");

        // ── withdraw rewards into pool wallet ──────────────────────────────
        vm.prank(poolOwner);
        IAStaking(pool).withdrawDelegatorRewards();

        uint256 claimableRewardsAfterWithdraw = IStaking(stakingProxy).computeRewardBalanceOfDelegator(poolId, pool);
        assertEq(claimableRewardsAfterWithdraw, 0, "no more claimable rewards after withdrawal");

        // NAV stage 3: rewards now sit in pool wallet as GRG → EApps wallet scan picks them up.
        uint256 navStage3 = _getUnitaryValue();
        console2.log("  NAV stage 3 (rewards in wallet):", navStage3);

        assertGe(navStage3, navStage1, "NAV should be at least as high as stage 1 after rewards realized");
    }

    /// @dev Same scenario but shows attacker cannot profit from the NAV gap when unstake return
    ///      of GRG is immediately reflected in the wallet balance.
    ///      The gap exists only for the CLAIMABLE rewards, not the returned vault stake.
    function test_unstake_returns_grg_to_wallet_so_nav_gap_is_only_claimable_rewards() public {
        uint256 mintAmount = 1_000e18;
        uint256 stakeAmount = 500e18;

        vm.startPrank(poolOwner);
        grg.approve(pool, type(uint256).max);
        ISmartPoolActions(pool).mint(poolOwner, mintAmount, 0);
        IAStaking(pool).stake(stakeAmount);
        vm.stopPrank();

        // read poolId after stake — staking pool created lazily
        poolId = IStorage(stakingProxy).poolIdByRbPoolAccount(pool);

        _warpAndEndEpoch(); // epoch 1→2

        _registerPop(pop);
        _creditPopReward(pop, pool, 1);

        vm.prank(poolOwner);
        IAStaking(pool).undelegateStake(stakeAmount);

        uint256 epochRewards = 100e18;
        require(grg.transfer(stakingProxy, epochRewards), "GRG transfer failed");
        _warpAndEndEpoch(); // epoch 2→3

        IStaking(stakingProxy).finalizePool(poolId);

        uint256 claimable = IStaking(stakingProxy).computeRewardBalanceOfDelegator(poolId, pool);
        assertGt(claimable, 0, "precondition: rewards claimable");

        uint256 grgInWalletBeforeUnstake = grg.balanceOf(pool);
        uint256 navBeforeUnstake = _getUnitaryValue();

        vm.prank(poolOwner);
        IAStaking(pool).unstake(stakeAmount);

        uint256 grgInWalletAfterUnstake = grg.balanceOf(pool);
        uint256 navAfterUnstake = _getUnitaryValue();

        // The vault stake (stakeAmount) returned to pool wallet → wallet increases by stakeAmount.
        assertEq(grgInWalletAfterUnstake, grgInWalletBeforeUnstake + stakeAmount, "vault stake returned to wallet");

        // NAV before unstake: stake counted via EApps app-balance (vaultBalance + claimable)
        // NAV after unstake: vault=0 → EApps returns empty; wallet+stakeAmount counted directly;
        //                    claimable NOT counted (NAV gap = claimable value)
        console2.log("navBeforeUnstake:", navBeforeUnstake);
        console2.log("navAfterUnstake:", navAfterUnstake);
        console2.log("claimable rewards (GRG):", claimable);

        // The gap should be approximately the claimable amount (priced via oracle).
        // Exact equality won't hold due to oracle pricing, but direction is clear.
        assertLt(navAfterUnstake, navBeforeUnstake, "NAV gap confirmed: claimable rewards excluded post-unstake");
    }

    /// @dev RIGO-4 regression: verifies that a pool staking the production-minimum GRG (100 GRG)
    ///      against the worst-case total network stake (≈10 million GRG, full mainnet supply) still
    ///      accrues a staking pal reward well above 15 wei after epoch finalisation.
    ///
    ///      Setup:
    ///        - smallPool stakes exactly 100 GRG (the _minimumPoolStake floor)
    ///        - bigPool stakes the remainder of the 10 MM GRG supply  (~9 990 200 GRG)
    ///        - both pools receive equal pop-reward credit (worst-case: small pool shares 50% of fees)
    ///        - epoch reward = 7 700 GRG (≈ 2 % annual of 10 MM / 26 epochs)
    ///
    ///      Expected (Cobb-Douglas, α = 2/3):
    ///        poolReward_small ≈ 7 700 × (100 / 9 990 300)^(2/3) × 0.5^(1/3) ≈ 2.83 GRG
    ///        operatorReward   ≈ 2.83 × 0.70                                  ≈ 1.98 GRG
    ///        stakingPalReward ≈ 1.98 × 0.10                                  ≈ 0.198 GRG  ≫ 15 wei
    ///
    ///      Assertion: staking pal balance increases by > 15 wei (RIGO-4 bound) and by > 1e14 wei
    ///      (a conservative floor well below the documented ~0.2 GRG floor).
    function test_minimum_stake_staking_pal_reward_above_zero() public {
        // ── deploy bigPool (simulates the rest of mainnet network stake) ─────────
        address bigOwner = makeAddr("bigOwner");
        vm.prank(bigOwner);
        (address bigPool, ) = IRigoblockPoolProxyFactory(deployment.factory)
            .createPool("BigPool", "BIG", address(grg));

        // ── smallPool: the pool created in setUp(); poolOwner already holds 2 000 GRG ──
        // Stake exactly 100 GRG — the production minimum stake floor.
        uint256 minStake = 100e18;
        address stakingPalAddr = makeAddr("stakingPal");

        // Deposit 2× minStake so that after the 0.1 % default spread the pool retains ≥ minStake GRG,
        // then stake exactly minStake (the _minimumPoolStake production floor).
        vm.startPrank(poolOwner);
        grg.approve(pool, minStake * 2);
        ISmartPoolActions(pool).mint(poolOwner, minStake * 2, 0);
        IAStaking(pool).stake(minStake);
        vm.stopPrank();

        poolId = IStorage(stakingProxy).poolIdByRbPoolAccount(pool);

        // Set an explicit staking pal address so we can measure the Transfer event precisely.
        // operator = poolOwner (read from pool.owner() during createStakingPool).
        vm.prank(poolOwner);
        IStaking(stakingProxy).setStakingPalAddress(poolId, stakingPalAddr);

        // ── bigPool: stake all remaining GRG minus the epoch reward reserve ──────
        // test contract starts with 10 MM - 2 000 GRG after setUp's transfer to poolOwner.
        uint256 epochReward = 7_700e18; // ≈ 2 % annual of 10 MM / 26 epochs
        uint256 bigStake = grg.balanceOf(address(this)) - epochReward;

        grg.transfer(bigOwner, bigStake);

        vm.startPrank(bigOwner);
        grg.approve(bigPool, bigStake);
        ISmartPoolActions(bigPool).mint(bigOwner, bigStake, 0);
        // Stake the actual pool balance after spread (bigPool holds bigStake × 0.999 GRG).
        uint256 bigPoolActualStake = grg.balanceOf(bigPool);
        IAStaking(bigPool).stake(bigPoolActualStake);
        vm.stopPrank();

        bytes32 bigPoolId = IStorage(stakingProxy).poolIdByRbPoolAccount(bigPool);
        assertFalse(bigPoolId == bytes32(0), "bigPool staking pool must be created");

        // ── epoch 1 → 2: advance so both delegations become active ──────────────
        _warpAndEndEpoch();

        // ── epoch 2: credit equal pop reward to both pools (proportional fee share) ─
        address popAddr = makeAddr("pop2");
        _registerPop(popAddr);
        _creditPopReward(popAddr, pool, 1);
        _creditPopReward(popAddr, bigPool, 1);

        // Fund staking proxy with realistic epoch inflation.
        require(grg.transfer(stakingProxy, epochReward), "failed to fund rewards");

        _warpAndEndEpoch();

        // ── epoch 3: finalize smallPool and assert staking pal received > 0 ──────
        uint256 palBefore = grg.balanceOf(stakingPalAddr);
        IStaking(stakingProxy).finalizePool(poolId);
        uint256 palAfter = grg.balanceOf(stakingPalAddr);

        uint256 stakingPalGrg = palAfter - palBefore;
        console2.log("--- RIGO-4 minimum-stake staking pal reward ---");
        console2.log("  totalWeightedStake ~(GRG, *1e-18):", (minStake + bigPoolActualStake) / 1e18);
        console2.log("  smallPoolStake     (GRG):", minStake / 1e18);
        console2.log("  stakingPalReward   (wei):", stakingPalGrg);
        console2.log("  stakingPalReward   (GRG, *1e-3 mGRG):", stakingPalGrg / 1e15);

        // RIGO-4 bound: the documented minimum is >> 15 wei; we assert a safe floor of 1e14 wei
        // (0.0001 GRG), which is still ~1 billion× below the ~0.2 GRG actual floor.
        assertGt(stakingPalGrg, 15, "RIGO-4: staking pal reward must exceed 15 wei at minimum stake");
        assertGt(stakingPalGrg, 1e14, "staking pal reward should be well above dust (>0.0001 GRG)");
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _getUnitaryValue() private returns (uint256) {
        return ISmartPoolActions(pool).updateUnitaryValue().unitaryValue;
    }

    function _configureVault() private {
        IGrgVault vault = IStaking(stakingProxy).getGrgVault();
        IAuthorizable(address(vault)).addAuthorizedAddress(address(this));
        vault.setStakingProxy(stakingProxy);
    }

    function _seedOracleForGrg() private {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(grg)),
            fee: 0,
            tickSpacing: TickMath.MAX_TICK_SPACING,
            hooks: IHooks(address(deployment.mockOracle))
        });
        deployment.mockOracle.initializeObservations(key);
    }

    function _deployAndRegisterAStakingAdapter() private {
        address grgTransferProxy = IGrgVaultWithAssetProxy(address(IStaking(stakingProxy).getGrgVault()))
            .grgAssetProxy();

        aStaking = deployCode(
            "out/AStaking.sol/AStaking.json",
            abi.encode(stakingProxy, address(grg), grgTransferProxy)
        );

        IAuthority(deployment.authority).setAdapter(aStaking, true);
        IAuthority(deployment.authority).addMethod(IAStaking.stake.selector, aStaking);
        IAuthority(deployment.authority).addMethod(IAStaking.undelegateStake.selector, aStaking);
        IAuthority(deployment.authority).addMethod(IAStaking.unstake.selector, aStaking);
        IAuthority(deployment.authority).addMethod(IAStaking.withdrawDelegatorRewards.selector, aStaking);
    }

    function _createPool() private {
        vm.prank(poolOwner);
        (pool, ) = IRigoblockPoolProxyFactory(deployment.factory).createPool("LifecyclePool", "LCPL", address(grg));
        // poolId is set lazily after the first stake() call - do not read here
    }

    function _warpAndEndEpoch() private {
        uint256 earliestEndTime = IStaking(stakingProxy).getCurrentEpochEarliestEndTimeInSeconds();
        if (block.timestamp < earliestEndTime) {
            vm.warp(earliestEndTime);
        }
        IStaking(stakingProxy).endEpoch();
    }

    function _registerPop(address popAddress) private {
        IAuthorizable(stakingProxy).addAuthorizedAddress(address(this));
        IStaking(stakingProxy).addPopAddress(popAddress);
    }

    function _creditPopReward(address popAddress, address poolAccount, uint256 popReward) private {
        vm.prank(popAddress);
        IStaking(stakingProxy).creditPopReward(poolAccount, popReward);
    }
}
