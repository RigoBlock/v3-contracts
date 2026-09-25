import { expect } from "chai";
import { network } from "hardhat";
import { parseEther, encodeBytes32String } from "ethers";
import { ZERO_ADDRESS as ZeroAddress } from "../shared/constants";
import { connect, getFixedGasSigners } from "../shared/helper";
import { createFixture } from "../utils/fixtures";
import { deployContract, timeTravel } from "../utils/utils";

describe("StakingProxy-Pop", async () => {
  const setupTests = createFixture(["tests-setup"], async ({ get }) => {
    const [user1, user2] = await getFixedGasSigners();
    const { ethers } = await network.getOrCreate();
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
    const registry = await ethers.getContractAt(
      "PoolRegistry",
      (await get("PoolRegistry")).address,
    );
    const inflationL2 = await ethers.getContractAt(
      "InflationL2",
      (await get("InflationL2")).address,
    );
    const grgTransferProxyAddress = (await get("ERC20Proxy")).address;
    //"a694fc3a": "stake(uint256)"
    await authority.addMethod("0xa694fc3a", (await get("AStaking")).address);
    await authority.addMethod("0x4aace835", (await get("AStaking")).address);
    const { newPoolAddress, poolId } = await factory.createPool.staticCall(
      "testpool",
      "TEST",
      ZeroAddress,
    );
    await factory.createPool("testpool", "TEST", ZeroAddress);
    return {
      grgToken,
      grgVault,
      pop,
      authority,
      factory,
      stakingProxy,
      registry,
      inflationL2,
      grgTransferProxyAddress,
      newPoolAddress,
      poolId,
      user1,
      user2,
    };
  });

  describe("creditPopRewardToStakingProxy", async () => {
    it("should revert if locked balances are null", async () => {
      const {
        stakingProxy,
        pop,
        grgToken,
        grgTransferProxyAddress,
        newPoolAddress,
        poolId,
      } = await setupTests();
      const amount = parseEther("100");
      await grgToken.approve(grgTransferProxyAddress, amount);
      await stakingProxy.stake(amount);
      await stakingProxy.createStakingPool(newPoolAddress);
      const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      const toInfo = new StakeInfo(StakeStatus.Delegated, poolId);
      await stakingProxy.moveStake(fromInfo, toInfo, amount);
      await expect(
        pop.creditPopRewardToStakingProxy(newPoolAddress),
      ).to.be.revertedWith("POP_STAKING_POOL_BALANCES_NULL_ERROR");
    });

    it("should revert if caller not pop", async () => {
      const { stakingProxy, pop, grgToken, newPoolAddress } =
        await setupTests();
      const amount = parseEther("100");
      await grgToken.transfer(newPoolAddress, amount);
      // must define pool as pool address on adapter instance
      const { ethers } = await network.getOrCreate();
      const pool = await ethers.getContractAt("AStaking", newPoolAddress);
      await pool.stake(amount);
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      await expect(
        pop.creditPopRewardToStakingProxy(newPoolAddress),
      ).to.be.revertedWith("STAKING_ONLY_CALLABLE_BY_POP_ERROR");
    });

    it("should revert if staking pool does not exist", async () => {
      const { stakingProxy, newPoolAddress, user1, user2 } = await setupTests();
      await stakingProxy.addAuthorizedAddress(user1.address);
      await stakingProxy.addPopAddress(user2.address);
      await expect(
        connect(stakingProxy, user2).creditPopReward(newPoolAddress, 100),
      ).to.be.revertedWith("STAKING_NULL_POOL_ID_ERROR");
      await stakingProxy.createStakingPool(newPoolAddress);
      await expect(
        connect(stakingProxy, user2).creditPopReward(newPoolAddress, 100),
      ).to.be.revertedWith("STAKING_STAKE_BELOW_MINIMUM_ERROR");
    });

    it("should revert if stake below minimum", async () => {
      const { stakingProxy, pop, grgToken, newPoolAddress, user1 } =
        await setupTests();
      const amount = parseEther("50");
      await grgToken.transfer(newPoolAddress, amount);
      const { ethers } = await network.getOrCreate();
      const pool = await ethers.getContractAt("AStaking", newPoolAddress);
      await expect(pool.stake(0)).to.be.revertedWith("STAKE_AMOUNT_NULL_ERROR");
      await pool.stake(amount);
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      await stakingProxy.addAuthorizedAddress(user1.address);
      await stakingProxy.addPopAddress(await pop.getAddress());
      await expect(
        pop.creditPopRewardToStakingProxy(newPoolAddress),
      ).to.be.revertedWith("STAKING_STAKE_BELOW_MINIMUM_ERROR");
    });

    it("should credit pop rewards for existing pool", async () => {
      const { stakingProxy, pop, grgToken, newPoolAddress, poolId, user1 } =
        await setupTests();
      const amount = parseEther("100");
      await grgToken.transfer(newPoolAddress, amount);
      // pool address on adapter interface
      const { ethers } = await network.getOrCreate();
      const pool = await ethers.getContractAt("AStaking", newPoolAddress);
      // will automatically create staking pool if doesn't exist (pool is staking pal)
      await pool.stake(amount);
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      await stakingProxy.addAuthorizedAddress(user1.address);
      await stakingProxy.addPopAddress(await pop.getAddress());
      const newEpochPoolStats =
        await stakingProxy.getStakingPoolStatsThisEpoch(poolId);
      expect(newEpochPoolStats.feesCollected).to.be.eq(0n);
      await expect(pop.creditPopRewardToStakingProxy(newPoolAddress))
        .to.emit(stakingProxy, "StakingPoolEarnedRewardsInEpoch")
        .withArgs(2n, poolId);
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      await timeTravel({ days: 14, mine: true });
      await expect(stakingProxy.endEpoch()).to.be.revertedWith(
        "STAKING_MISSING_POOLS_TO_BE_FINALIZED_ERROR",
      );
    });

    it("should not credit null pop rewards for existing pool", async () => {
      const {
        stakingProxy,
        grgToken,
        pop,
        newPoolAddress,
        grgTransferProxyAddress,
        poolId,
        user1,
      } = await setupTests();
      await stakingProxy.addAuthorizedAddress(user1.address);
      await stakingProxy.addPopAddress(await pop.getAddress());
      const amount = parseEther("100");
      await grgToken.approve(grgTransferProxyAddress, amount);
      await stakingProxy.stake(amount);
      await stakingProxy.createStakingPool(newPoolAddress);
      const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      const toInfo = new StakeInfo(StakeStatus.Delegated, poolId);
      await stakingProxy.moveStake(fromInfo, toInfo, amount);
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      await expect(
        pop.creditPopRewardToStakingProxy(newPoolAddress),
      ).to.be.revertedWith("POP_STAKING_POOL_BALANCES_NULL_ERROR");
      await grgToken.transfer(newPoolAddress, amount);
      const { ethers } = await network.getOrCreate();
      const pool = await ethers.getContractAt("AStaking", newPoolAddress);
      await pool.stake(parseEther("1"));
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      await pool.undelegateStake(parseEther("1"));
      await expect(pop.creditPopRewardToStakingProxy(newPoolAddress))
        .to.emit(stakingProxy, "StakingPoolEarnedRewardsInEpoch")
        .withArgs(3n, poolId);
      let newEpochPoolStats;
      newEpochPoolStats =
        await stakingProxy.getStakingPoolStatsThisEpoch(poolId);
      expect(newEpochPoolStats.feesCollected).to.be.eq(parseEther("1"));
      // we can call credit reward multiple times but it won't change reward
      await pop.creditPopRewardToStakingProxy(newPoolAddress);
      newEpochPoolStats =
        await stakingProxy.getStakingPoolStatsThisEpoch(poolId);
      expect(newEpochPoolStats.feesCollected).to.be.eq(parseEther("1"));
    });
  });

  describe("finalize", async () => {
    it("should finalize with multiple pools", async () => {
      const {
        factory,
        stakingProxy,
        grgToken,
        pop,
        newPoolAddress,
        poolId,
        user1,
      } = await setupTests();
      await stakingProxy.addAuthorizedAddress(user1.address);
      await stakingProxy.addPopAddress(await pop.getAddress());
      const amount = parseEther("200");
      await grgToken.transfer(newPoolAddress, amount);
      const { ethers } = await network.getOrCreate();
      const pool = await ethers.getContractAt("AStaking", newPoolAddress);
      await pool.stake(parseEther("100"));
      const pool2Data = await factory.createPool.staticCall(
        "testpool2",
        "TEST",
        ZeroAddress,
      );
      await factory.createPool("testpool2", "TEST", ZeroAddress);
      await grgToken.transfer(pool2Data.newPoolAddress, amount);
      const pool2 = await ethers.getContractAt(
        "AStaking",
        pool2Data.newPoolAddress,
      );
      await pool2.stake(parseEther("200"));
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      await expect(pop.creditPopRewardToStakingProxy(newPoolAddress))
        .to.emit(stakingProxy, "StakingPoolEarnedRewardsInEpoch")
        .withArgs(2n, poolId);
      await expect(pop.creditPopRewardToStakingProxy(pool2Data.newPoolAddress))
        .to.emit(stakingProxy, "StakingPoolEarnedRewardsInEpoch")
        .withArgs(2n, pool2Data.poolId);
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      await stakingProxy.finalizePool(poolId);
    });

    it("should credit null reward with rogue pop", async () => {
      const {
        authority,
        stakingProxy,
        grgToken,
        grgTransferProxyAddress,
        registry,
        user1,
      } = await setupTests();
      await stakingProxy.addAuthorizedAddress(user1.address);
      await stakingProxy.addPopAddress(user1.address);
      await authority.setFactory(user1.address, true);
      const mockName = "mock name";
      const mockBytes32 = encodeBytes32String(mockName);
      const source = `contract MockPool { address public owner = address(1); }`;
      const mockPool = await deployContract(user1 as any, source);
      await registry.register(
        await mockPool.getAddress(),
        mockName,
        "TEST",
        mockBytes32,
      );
      await stakingProxy.createStakingPool(await mockPool.getAddress());
      const amount = parseEther("100");
      await grgToken.approve(grgTransferProxyAddress, amount);
      await stakingProxy.stake(amount);
      const fromInfo = new StakeInfo(StakeStatus.Undelegated, mockBytes32);
      const toInfo = new StakeInfo(StakeStatus.Delegated, mockBytes32);
      await stakingProxy.moveStake(fromInfo, toInfo, amount);
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      await expect(stakingProxy.creditPopReward(await mockPool.getAddress(), 0))
        .to.emit(stakingProxy, "StakingPoolEarnedRewardsInEpoch")
        .withArgs(2n, mockBytes32);
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      await stakingProxy.finalizePool(mockBytes32);
      // test system does not get stuck even in case of rogue pop
      await timeTravel({ days: 14, mine: true });
      // system won't be able to reduce num pools to finalize if reward credited is 0.
      // this condition is excluded by both pop contract which reverts if pool self stake below minimum
      await expect(stakingProxy.endEpoch()).to.be.revertedWith(
        "STAKING_MISSING_POOLS_TO_BE_FINALIZED_ERROR",
      );
    });

    it("should credit null reward on L2s with null token balance on inflation", async () => {
      const {
        stakingProxy,
        grgToken,
        pop,
        newPoolAddress,
        poolId,
        inflationL2,
        user1,
      } = await setupTests();
      await stakingProxy.addAuthorizedAddress(user1.address);
      await stakingProxy.addPopAddress(await pop.getAddress());
      await inflationL2.initParams(
        await grgToken.getAddress(),
        await stakingProxy.getAddress(),
      );
      await grgToken.changeMintingAddress(await inflationL2.getAddress());
      const { ethers } = await network.getOrCreate();
      const amount = parseEther("100");
      await grgToken.transfer(newPoolAddress, amount);
      const pool = await ethers.getContractAt("AStaking", newPoolAddress);
      await pool.stake(amount);
      await timeTravel({ days: 14, mine: true });
      await expect(stakingProxy.endEpoch())
        .to.emit(stakingProxy, "EpochEnded")
        .withArgs(1n, 0n, 0n, 0n, 0n)
        .to.emit(stakingProxy, "EpochFinalized")
        .withArgs(1n, 0n, 0n);
      await expect(pop.creditPopRewardToStakingProxy(newPoolAddress))
        .to.emit(stakingProxy, "StakingPoolEarnedRewardsInEpoch")
        .withArgs(2n, poolId);
      await timeTravel({ days: 14, mine: true });
      await expect(stakingProxy.endEpoch())
        .to.emit(stakingProxy, "EpochEnded")
        .withArgs(2n, 1n, 0n, amount, (amount * 9n) / 10n)
        .to.emit(stakingProxy, "GrgMintEvent")
        .withArgs(0n);
      await expect(stakingProxy.finalizePool(poolId))
        // currentEpoch_, poolId, operatorReward, membersReward
        .to.emit(stakingProxy, "RewardsPaid")
        .withArgs(3n, poolId, 0n, 0n)
        // prevEpoch, totalRewardsFinalized, reamining rewards
        .to.emit(stakingProxy, "EpochFinalized")
        .withArgs(2n, 0n, 0n);
      // system does not get stuck even in case of null token balance
      await expect(pop.creditPopRewardToStakingProxy(newPoolAddress))
        .to.emit(stakingProxy, "StakingPoolEarnedRewardsInEpoch")
        .withArgs(3n, poolId);
      await timeTravel({ days: 14, mine: true });
      const tokenAmount = parseEther("50000");
      await grgToken.transfer(await inflationL2.getAddress(), tokenAmount);
      const nextMintAmount = await inflationL2.getEpochInflation();
      await expect(stakingProxy.endEpoch())
        .to.emit(stakingProxy, "EpochEnded")
        .withArgs(3n, 1n, nextMintAmount, amount, (amount * 9n) / 10n)
        .to.emit(stakingProxy, "GrgMintEvent")
        .withArgs(nextMintAmount);
      await expect(stakingProxy.finalizePool(poolId))
        .to.emit(stakingProxy, "RewardsPaid")
        .withArgs(
          4n,
          poolId,
          (nextMintAmount * 7000n) / 10000n + 1n,
          (nextMintAmount * 3000n) / 10000n,
        )
        .to.emit(stakingProxy, "EpochFinalized")
        .withArgs(3n, nextMintAmount, 0n);
      const mintedAmount = await grgToken.balanceOf(
        await stakingProxy.getAddress(),
      );
      expect(mintedAmount).to.be.not.eq(0n);
      await timeTravel({ days: 14, mine: true });
      await expect(stakingProxy.endEpoch())
        .to.emit(stakingProxy, "EpochEnded")
        .withArgs(4n, 0n, nextMintAmount, 0n, 0n)
        .to.emit(stakingProxy, "GrgMintEvent")
        .withArgs(nextMintAmount);
    });
  });

  describe("proofOfPerformance", async () => {
    // will return 0 until pool has positive active stake
    it("should return value of pop reward", async () => {
      const {
        stakingProxy,
        grgToken,
        pop,
        newPoolAddress,
        grgTransferProxyAddress,
        poolId,
        user1,
      } = await setupTests();
      await stakingProxy.addAuthorizedAddress(user1.address);
      await stakingProxy.addPopAddress(await pop.getAddress());
      expect(await pop.proofOfPerformance(newPoolAddress)).to.be.eq(0n);
      const amount = parseEther("100");
      await grgToken.approve(grgTransferProxyAddress, amount);
      await stakingProxy.stake(amount);
      await stakingProxy.createStakingPool(newPoolAddress);
      const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      const toInfo = new StakeInfo(StakeStatus.Delegated, poolId);
      await stakingProxy.moveStake(fromInfo, toInfo, amount);
      expect(await pop.proofOfPerformance(newPoolAddress)).to.be.eq(0n);
      await grgToken.transfer(newPoolAddress, amount);
      const { ethers } = await network.getOrCreate();
      const pool = await ethers.getContractAt("AStaking", newPoolAddress);
      await pool.stake(amount);
      expect(await pop.proofOfPerformance(newPoolAddress)).to.be.eq(0n);
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      expect(await pop.proofOfPerformance(newPoolAddress)).to.be.eq(amount);
    });
  });

  describe("withdrawDelegatorRewards", async () => {
    it("should withdraw delegator rewards", async () => {
      const {
        stakingProxy,
        grgToken,
        pop,
        newPoolAddress,
        grgTransferProxyAddress,
        poolId,
        user1,
      } = await setupTests();
      await stakingProxy.addAuthorizedAddress(user1.address);
      await stakingProxy.addPopAddress(await pop.getAddress());
      const amount = parseEther("100");
      await grgToken.approve(grgTransferProxyAddress, amount);
      await stakingProxy.stake(amount);
      await stakingProxy.createStakingPool(newPoolAddress);
      const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      const toInfo = new StakeInfo(StakeStatus.Delegated, poolId);
      await stakingProxy.moveStake(fromInfo, toInfo, amount);
      await grgToken.transfer(newPoolAddress, amount);
      const { ethers } = await network.getOrCreate();
      const pool = await ethers.getContractAt("AStaking", newPoolAddress);
      await pool.stake(amount);
      let delegatorReward;
      delegatorReward = await stakingProxy.computeRewardBalanceOfDelegator(
        poolId,
        user1.address,
      );
      expect(delegatorReward).to.be.deep.eq(0n);
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      await pop.creditPopRewardToStakingProxy(newPoolAddress);
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      await expect(
        stakingProxy.withdrawDelegatorRewards(poolId),
      ).to.be.revertedWith("STAKING_POOL_NOT_FINALIZED_ERROR");
      let poolOperatorReward;
      poolOperatorReward =
        await stakingProxy.computeRewardBalanceOfOperator(poolId);
      expect(poolOperatorReward).to.be.not.eq(0n);
      await stakingProxy.finalizePool(poolId);
      // noop if thepool already finalized
      await stakingProxy.finalizePool(poolId);
      poolOperatorReward =
        await stakingProxy.computeRewardBalanceOfOperator(poolId);
      // reward is paid to pool operator at pool finalization
      expect(poolOperatorReward).to.be.eq(0n);
      delegatorReward = await stakingProxy.computeRewardBalanceOfDelegator(
        poolId,
        user1.address,
      );
      await expect(stakingProxy.withdrawDelegatorRewards(poolId))
        .to.emit(grgToken, "Transfer")
        .withArgs(
          await stakingProxy.getAddress(),
          user1.address,
          delegatorReward,
        );
    });
  });

  describe("getStakingPoolStatsThisEpoch", async () => {
    it("should return staking pool earned rewards", async () => {
      const { stakingProxy, grgToken, pop, poolId, newPoolAddress, user1 } =
        await setupTests();
      await stakingProxy.addAuthorizedAddress(user1.address);
      await stakingProxy.addPopAddress(await pop.getAddress());
      const poolStats = await stakingProxy.getStakingPoolStatsThisEpoch(poolId);
      expect(poolStats.feesCollected).to.be.eq(0n);
      expect(poolStats.weightedStake).to.be.eq(0n);
      expect(poolStats.membersStake).to.be.eq(0n);
      const amount = parseEther("100");
      await grgToken.transfer(newPoolAddress, amount);
      const { ethers } = await network.getOrCreate();
      const pool = await ethers.getContractAt("AStaking", newPoolAddress);
      await pool.stake(amount);
      // noop if thepool already finalized
      await stakingProxy.finalizePool(poolId);
      await expect(
        pop.creditPopRewardToStakingProxy(newPoolAddress),
      ).to.be.revertedWith("POP_STAKING_POOL_BALANCES_NULL_ERROR");
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      await expect(pop.creditPopRewardToStakingProxy(newPoolAddress))
        .to.emit(stakingProxy, "StakingPoolEarnedRewardsInEpoch")
        .withArgs(2n, poolId);
      const newEpochPoolStats =
        await stakingProxy.getStakingPoolStatsThisEpoch(poolId);
      expect(newEpochPoolStats.feesCollected).to.be.eq(amount);
      expect(newEpochPoolStats.weightedStake).to.be.eq(parseEther("90"));
      expect(newEpochPoolStats.membersStake).to.be.eq(parseEther("100"));
    });
  });

  describe("addPopAddress", async () => {
    it("should revert pop registration if already registered", async () => {
      const { stakingProxy, pop, user1, user2 } = await setupTests();
      await expect(
        stakingProxy.addPopAddress(await pop.getAddress()),
      ).to.be.revertedWith("AUTHORIZABLE_SENDER_NOT_AUTHORIZED_ERROR");
      await expect(
        connect(stakingProxy, user2).addAuthorizedAddress(user2.address),
      ).to.be.revertedWith("CALLER_NOT_OWNER_ERROR");
      await stakingProxy.addAuthorizedAddress(user1.address);
      await expect(stakingProxy.addPopAddress(await pop.getAddress()))
        .to.emit(stakingProxy, "PopAdded")
        .withArgs(await pop.getAddress());
      await expect(
        stakingProxy.addPopAddress(await pop.getAddress()),
      ).to.be.revertedWith("STAKING_POP_ALREADY_REGISTERED_ERROR");
    });
  });

  describe("removePopAddress", async () => {
    it("should revert removing non-registered pop", async () => {
      const { stakingProxy, pop, user1 } = await setupTests();
      await expect(
        stakingProxy.removePopAddress(await pop.getAddress()),
      ).to.be.revertedWith("AUTHORIZABLE_SENDER_NOT_AUTHORIZED_ERROR");
      await stakingProxy.addAuthorizedAddress(user1.address);
      await expect(
        stakingProxy.removePopAddress(await pop.getAddress()),
      ).to.be.revertedWith("STAKING_POP_NOT_REGISTERED_ERROR");
      await stakingProxy.addPopAddress(await pop.getAddress());
      await expect(stakingProxy.removePopAddress(await pop.getAddress()))
        .to.emit(stakingProxy, "PopRemoved")
        .withArgs(await pop.getAddress());
    });
  });
});

export enum StakeStatus {
  Undelegated,
  Delegated,
}

export class StakeInfo {
  constructor(
    public status: StakeStatus,
    public poolId: any,
  ) {}
}
