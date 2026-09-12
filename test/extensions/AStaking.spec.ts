import { expect } from "chai";
import { network } from "hardhat";
import { parseEther, ZeroAddress } from "ethers";
import { timeTravel } from "../utils/utils";
import { getFixedGasSigners } from "../shared/helper";
import { createFixture } from "../utils/fixtures";

describe("AStaking", async () => {
  const setupTests = createFixture(["tests-setup"], async ({ get }) => {
    const { ethers } = await network.getOrCreate();
    const [user1] = await getFixedGasSigners();
    const authority = await ethers.getContractAt(
      "Authority",
      (await get("Authority")).address,
    );
    const factory = await ethers.getContractAt(
      "RigoblockPoolProxyFactory",
      (await get("RigoblockPoolProxyFactory")).address,
    );
    const grgToken = await ethers.getContractAt(
      "RigoToken",
      (await get("RigoToken")).address,
    );
    const grgVault = await ethers.getContractAt(
      "GrgVault",
      (await get("GrgVault")).address,
    );
    const pop = await ethers.getContractAt(
      "ProofOfPerformance",
      (await get("ProofOfPerformance")).address,
    );
    const stakingProxy = await ethers.getContractAt(
      "Staking",
      (await get("StakingProxy")).address,
    );
    const hook = await ethers.getContractAt(
      "MockOracle",
      (await get("MockOracle")).address,
    );
    // "a694fc3a": "stake(uint256)"
    // "4aace835": "undelegateStake(uint256)",
    // "2e17de78": "unstake(uint256)",
    // "b880660b": "withdrawDelegatorRewards()"
    const aStakingAddress = (await get("AStaking")).address;
    await authority.addMethod("0xa694fc3a", aStakingAddress);
    await authority.addMethod("0x4aace835", aStakingAddress);
    await authority.addMethod("0x2e17de78", aStakingAddress);
    await authority.addMethod("0xb880660b", aStakingAddress);
    const { newPoolAddress, poolId } = await factory.createPool.staticCall(
      "testpool",
      "TEST",
      ZeroAddress,
    );
    await factory.createPool("testpool", "TEST", ZeroAddress);
    // GRG being ownable is a pre-condition, otherwise won't be able to use staking proxy
    const MAX_TICK_SPACING = 32767;
    const poolKey = {
      currency0: ZeroAddress,
      currency1: await grgToken.getAddress(),
      fee: 0,
      tickSpacing: MAX_TICK_SPACING,
      hooks: await hook.getAddress(),
    };
    await hook.initializeObservations(poolKey);
    return {
      grgToken,
      grgVault,
      pop,
      stakingProxy,
      grgTransferProxyAddress: (await get("ERC20Proxy")).address,
      newPoolAddress,
      poolId,
      oraclePool: await ethers.getContractAt("EOracle", newPoolAddress),
      user1,
    };
  });

  describe("unstake", async () => {
    it("should revert if null stake", async () => {
      const { newPoolAddress } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const pool = await ethers.getContractAt("AStaking", newPoolAddress);
      const amount = 100;
      await expect(pool.unstake(amount)).to.be.revertedWith(
        "MOVE_STAKE_AMOUNT_HIGHER_THAN_WITHDRAWABLE_ERROR",
      );
    });

    it("should revert if null withdrawable stake", async () => {
      const { stakingProxy, grgToken, newPoolAddress } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const pool = await ethers.getContractAt("AStaking", newPoolAddress);
      const amount = parseEther("100");
      await grgToken.transfer(newPoolAddress, amount);
      await pool.stake(amount);
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      await expect(pool.unstake(amount)).to.be.revertedWith(
        "MOVE_STAKE_AMOUNT_HIGHER_THAN_WITHDRAWABLE_ERROR",
      );
    });

    it("should unstake withdrawable amount", async () => {
      const { stakingProxy, grgToken, newPoolAddress } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const pool = await ethers.getContractAt("AStaking", newPoolAddress);
      const amount = parseEther("100");
      await grgToken.transfer(newPoolAddress, amount);
      await pool.stake(amount);
      await pool.undelegateStake(amount);
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      await expect(pool.unstake(amount * 2n)).to.be.revertedWith(
        "MOVE_STAKE_AMOUNT_HIGHER_THAN_WITHDRAWABLE_ERROR",
      );
      await expect(pool.unstake(amount))
        .to.emit(stakingProxy, "Unstake")
        .withArgs(newPoolAddress, amount);
    });
  });

  describe("withdraw rewards", async () => {
    it("withdraw delegator rewards", async () => {
      const { stakingProxy, pop, grgToken, newPoolAddress, user1 } =
        await setupTests();
      const { ethers } = await network.getOrCreate();
      const pool = await ethers.getContractAt("AStaking", newPoolAddress);
      // transaction will success if null rewards
      await pool.withdrawDelegatorRewards();
      const amount = parseEther("100");
      await grgToken.transfer(newPoolAddress, amount);
      const grgPoolBalanceBeforeReward =
        await grgToken.balanceOf(newPoolAddress);
      await pool.stake(amount);
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      await expect(
        pop.creditPopRewardToStakingProxy(newPoolAddress),
      ).to.be.revertedWith("STAKING_ONLY_CALLABLE_BY_POP_ERROR");
      await stakingProxy.addAuthorizedAddress(user1.address);
      await stakingProxy.addPopAddress(await pop.getAddress());
      await pop.creditPopRewardToStakingProxy(newPoolAddress);
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      const poolId = await stakingProxy.poolIdByRbPoolAccount(newPoolAddress);
      const reward = await stakingProxy.computeRewardBalanceOfDelegator(
        poolId,
        newPoolAddress,
      );
      expect(reward).to.be.not.eq(0n);
      await expect(pool.withdrawDelegatorRewards())
        .to.emit(grgToken, "Transfer")
        .withArgs(await stakingProxy.getAddress(), newPoolAddress, reward);
      const grgPoolBalanceAfterReward =
        await grgToken.balanceOf(newPoolAddress);
      expect(grgPoolBalanceBeforeReward).to.be.lt(grgPoolBalanceAfterReward);
    });
  });

  describe("stake-unstake and sync tokens", async () => {
    it("should add grg to active tokens when positive stake", async () => {
      const { stakingProxy, grgToken, newPoolAddress, user1 } =
        await setupTests();
      const { ethers } = await network.getOrCreate();
      const pool = await ethers.getContractAt("AStaking", newPoolAddress);
      const fullPool = await ethers.getContractAt("SmartPool", newPoolAddress);
      const amount = parseEther("100");
      await grgToken.transfer(newPoolAddress, amount);
      // returned active tokens are active tokens array and the base token
      expect((await fullPool.getActiveTokens()).activeTokens.length).to.be.eq(
        0,
      );
      await pool.stake(amount);
      expect((await fullPool.getActiveTokens()).activeTokens.length).to.be.eq(
        0,
      );
      // TODO: we can also assert that token is active before the end of the epoch
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      expect((await fullPool.getActiveTokens()).activeTokens.length).to.be.eq(
        0,
      );
      await expect(fullPool.mint(user1.address, amount, 0, { value: amount }))
        .to.emit(fullPool, "TokenStatusChanged")
        .withArgs(await grgToken.getAddress(), true);
      expect((await fullPool.getActiveTokens()).activeTokens.length).to.be.eq(
        1,
      );
      let activeTokens = (await fullPool.getActiveTokens()).activeTokens;
      expect(activeTokens[0]).to.be.eq(await grgToken.getAddress());
      await expect(
        fullPool.mint(user1.address, amount, 0, { value: amount }),
      ).to.not.emit(fullPool, "TokenStatusChanged");
      activeTokens = (await fullPool.getActiveTokens()).activeTokens;
      expect(activeTokens.length).to.be.eq(1);
      expect(activeTokens[0]).to.be.eq(await grgToken.getAddress());
    });

    it("should not remove grg from active tokens when null stake", async () => {
      const { grgToken, newPoolAddress, oraclePool, user1 } =
        await setupTests();
      const { ethers } = await network.getOrCreate();
      const pool = await ethers.getContractAt("AStaking", newPoolAddress);
      const fullPool = await ethers.getContractAt("SmartPool", newPoolAddress);
      const amount = parseEther("100");
      await grgToken.transfer(newPoolAddress, amount);
      await pool.stake(amount);
      await fullPool.mint(user1.address, amount, 0, { value: amount });
      await fullPool.mint(user1.address, amount, 0, { value: amount });
      expect((await fullPool.getActiveTokens()).activeTokens.length).to.be.eq(
        1,
      );
      await pool.undelegateStake(amount);
      expect((await fullPool.getActiveTokens()).activeTokens.length).to.be.eq(
        1,
      );
      await pool.unstake(amount);
      expect((await fullPool.getActiveTokens()).activeTokens.length).to.be.eq(
        1,
      );
      await fullPool.updateUnitaryValue();
      expect((await fullPool.getActiveTokens()).activeTokens.length).to.be.eq(
        1,
      );
      await fullPool.mint(user1.address, amount, 0, { value: amount });
      expect((await fullPool.getActiveTokens()).activeTokens.length).to.be.eq(
        1,
      );
      // token is removed only with owner action, for gas optimization
      await fullPool.purgeInactiveTokensAndApps();
      // token is not removed because the token pool's balance is not null.
      expect((await fullPool.getActiveTokens()).activeTokens.length).to.be.eq(
        1,
      );
      await timeTravel({ days: 30, mine: true });
      // remove base token balance, so below grg value in base token, so we can burn for token
      expect(
        await ethers.provider.getBalance(await fullPool.getAddress()),
      ).to.be.eq(parseEther("299.7"));
      const { unitaryValue } = await fullPool.getPoolTokens();
      const poolNativeBalance = await ethers.provider.getBalance(
        await fullPool.getAddress(),
      );
      // mint transferred balance minus spread
      expect(poolNativeBalance).to.be.eq(parseEther("299.7"));
      const poolTokensFromBalance =
        (poolNativeBalance * parseEther("1")) / unitaryValue;
      expect(poolTokensFromBalance).to.be.eq(
        parseEther("151.273419778308952543"),
      );
      await fullPool.burn(poolTokensFromBalance, 1);
      const userPoolBalance = await fullPool.balanceOf(user1.address);
      const grgBalanceInBaseToken = await oraclePool.convertTokenAmount(
        await grgToken.getAddress(),
        await grgToken.balanceOf(newPoolAddress),
        ZeroAddress,
      );
      expect(grgBalanceInBaseToken).to.be.eq(
        parseEther("98.019965344057696551"),
      );
      expect((await fullPool.getPoolTokens()).unitaryValue).to.be.eq(
        parseEther("1.981180834274851817"),
      );
      expect(userPoolBalance).to.be.eq(parseEther("49.475526740563682485"));
      await fullPool.burnForToken(
        userPoolBalance,
        1,
        await grgToken.getAddress(),
      );
      expect(await grgToken.balanceOf(newPoolAddress)).to.be.eq(36n);
      await fullPool.purgeInactiveTokensAndApps();
      // TODO: the small roundings in favor of the pool result in a small residual balance, which prevents the token removal
      // This is acceptable, as the vault can get rid of all small balances by converting them into the base token
      // this time, token is removed because the token pool's balance is null or 1.
      expect((await fullPool.getActiveTokens()).activeTokens.length).to.be.eq(
        1,
      );
      expect(await fullPool.totalSupply()).to.be.eq(parseEther("0"));
    });

    it("should clear balances with total burn", async () => {
      const { grgToken, newPoolAddress, oraclePool, user1 } =
        await setupTests();
      const { ethers } = await network.getOrCreate();
      const pool = await ethers.getContractAt("AStaking", newPoolAddress);
      const fullPool = await ethers.getContractAt("SmartPool", newPoolAddress);
      const amount = parseEther("100");
      await grgToken.transfer(newPoolAddress, amount);
      await pool.stake(amount);
      await fullPool.mint(user1.address, amount, 0, { value: amount });
      await fullPool.mint(user1.address, amount, 0, { value: amount });
      await pool.undelegateStake(amount);
      await pool.unstake(amount);
      await fullPool.mint(user1.address, amount, 0, { value: amount });
      // our mock oracle returns 200, so we expect the nav to be 1.981180834274851817
      expect(await oraclePool.getTwap(await grgToken.getAddress())).to.be.eq(
        200n,
      );
      await fullPool.updateUnitaryValue();
      const { unitaryValue } = await fullPool.getPoolTokens();
      expect(unitaryValue).to.be.eq(parseEther("1.981180834274851817"));
      await timeTravel({ days: 30, mine: true });
      // remove base token balance, so below grg value in base token, so we can burn for token. Nav is approx 1.981180834274851817
      // TODO: the following call is reflexive, i.e. not burning the full amount will result in a different nav, and the number of pool tokens
      // to clear grg token balance will be different. We will then find ourselves with a null total supply, but a positive balance in the pool.
      expect(
        await ethers.provider.getBalance(await fullPool.getAddress()),
      ).to.be.eq(parseEther("299.7"));
      const grgBalanceInBaseToken = await oraclePool.convertTokenAmount(
        await grgToken.getAddress(),
        await grgToken.balanceOf(newPoolAddress),
        ZeroAddress,
      );
      expect(grgBalanceInBaseToken).to.be.eq(
        parseEther("98.019965344057696551"),
      );
      const poolNativeBalance = await ethers.provider.getBalance(
        await fullPool.getAddress(),
      );
      // mint transferred balance minus spread
      expect(poolNativeBalance).to.be.eq(parseEther("299.7"));
      const poolTokensFromBalance =
        (poolNativeBalance * parseEther("1")) / unitaryValue;
      expect(poolTokensFromBalance).to.be.eq(
        parseEther("151.273419778308952543"),
      );
      await fullPool.burn(poolTokensFromBalance, 1);
      // there is a small approximation error due to spread application
      expect(
        await ethers.provider.getBalance(await fullPool.getAddress()),
      ).to.be.eq(2n);
      // the burn operation won't affect the unitary value
      expect((await fullPool.getPoolTokens()).unitaryValue).to.be.eq(
        unitaryValue,
      );
      const grgBurnAmount =
        (grgBalanceInBaseToken * parseEther("1")) / unitaryValue;
      expect(grgBurnAmount).to.be.eq(parseEther("49.475526740563682501"));
      const userPoolBalance = await fullPool.balanceOf(user1.address);
      expect(userPoolBalance).to.be.eq(parseEther("49.475526740563682485"));
      expect(grgBurnAmount - userPoolBalance).to.be.lte(21n); // small rounding error in favor of the pool
      await expect(
        fullPool.burnForToken(
          userPoolBalance + 1n,
          1,
          await grgToken.getAddress(),
        ),
      ).to.be.revertedWithCustomError(fullPool, "PoolBurnNotEnough");
      await fullPool.burnForToken(
        userPoolBalance,
        1,
        await grgToken.getAddress(),
      );
      // there is a small residual amount in the pool, due to rounding errors
      expect(await grgToken.balanceOf(newPoolAddress)).to.be.eq(36n);
      const totalSupply = await fullPool.totalSupply();
      expect((await fullPool.getPoolTokens()).unitaryValue).to.be.eq(
        parseEther("1.981180834274851817"),
      );
      expect(await fullPool.totalSupply()).to.be.eq(0n);
      await expect(fullPool.burn(totalSupply, 1)).to.be.revertedWithCustomError(
        fullPool,
        "PoolBurnNullAmount",
      );
      expect(
        await ethers.provider.getBalance(await fullPool.getAddress()),
      ).to.be.eq(2n); // residual native balance has not changed
      // assert pool value does not change (need to mint as supply is null)
      await fullPool.mint(user1.address, amount, 0, { value: amount });
      expect((await fullPool.getPoolTokens()).unitaryValue).to.be.eq(
        parseEther("1.981180834274851817"),
      );
    });
  });
});
