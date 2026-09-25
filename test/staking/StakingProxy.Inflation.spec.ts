import { expect } from "chai";
import { network } from "hardhat";
import { ZeroAddress, parseEther } from "ethers";
import { connect, getFixedGasSigners } from "../shared/helper";
import { createFixture } from "../utils/fixtures";
import { timeTravel } from "../utils/utils";

describe("Inflation", async () => {
  const setupTests = createFixture(["tests-setup"], async ({ get }) => {
    const [user1, user2] = await getFixedGasSigners();
    const { ethers } = await network.getOrCreate();
    const factory = await ethers.getContractAt(
      "RigoblockPoolProxyFactory",
      (await get("RigoblockPoolProxyFactory")).address,
    );
    const { newPoolAddress, poolId } = await factory.createPool.staticCall(
      "testpool",
      "TEST",
      ZeroAddress,
    );
    await factory.createPool("testpool", "TEST", ZeroAddress);
    return {
      inflation: await ethers.getContractAt(
        "Inflation",
        (await get("Inflation")).address,
      ),
      rigoToken: await ethers.getContractAt(
        "RigoToken",
        (await get("RigoToken")).address,
      ),
      stakingProxy: await ethers.getContractAt(
        "Staking",
        (await get("StakingProxy")).address,
      ),
      newPoolAddress,
      poolId,
      user1,
      user2,
    };
  });

  describe("mintInflation", async () => {
    it("should revert if caller not staking proxy", async () => {
      const { inflation } = await setupTests();
      await expect(inflation.mintInflation()).to.be.revertedWith(
        "CALLER_NOT_STAKING_PROXY_ERROR",
      );
    });

    it("should revert if epoch time shortened but time not enough", async () => {
      const { stakingProxy, user1 } = await setupTests();
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      const minimumPoolStake = parseEther("100"); // 100 GRG
      await stakingProxy.addAuthorizedAddress(user1.address);
      await stakingProxy.setParams(
        432001, //uint256 _epochDurationInSeconds,
        100, //uint32 _rewardDelegatedStakeWeight,
        minimumPoolStake, //uint256 _minimumPoolStake,
        2, //uint32 _cobbDouglasAlphaNumerator,
        3, //uint32 _cobbDouglasAlphaDenominator
      );
      // error in inflation will never be returned as staking will revert first
      await expect(stakingProxy.endEpoch()).to.be.revertedWith(
        "STAKING_TIMESTAMP_TOO_LOW_ERROR",
      );
    });

    it("should wait for epoch 2 before first mint", async () => {
      const { inflation, stakingProxy, rigoToken } = await setupTests();
      const stakingProxyAddress = await stakingProxy.getAddress();
      expect(await inflation.epochEnded()).to.be.eq(true);
      await expect(stakingProxy.endEpoch()).to.be.revertedWith(
        "STAKING_TIMESTAMP_TOO_LOW_ERROR",
      );
      await timeTravel({ days: 14, mine: true });
      await expect(stakingProxy.endEpoch())
        .to.emit(stakingProxy, "EpochFinalized")
        .withArgs(1n, 0n, 0n);
      expect(await inflation.epochEnded()).to.be.eq(true);
      expect(await rigoToken.balanceOf(stakingProxyAddress)).to.be.eq(0n);
      await timeTravel({ days: 14, mine: true });
      await expect(stakingProxy.endEpoch()).to.emit(
        stakingProxy,
        "GrgMintEvent",
      );
      expect(await inflation.epochEnded()).to.be.eq(false);
      const mintedAmount = await rigoToken.balanceOf(stakingProxyAddress);
      expect(mintedAmount).to.be.not.eq(0n);

      const nextMintAmount = await inflation.getEpochInflation();
      await timeTravel({ days: 14, mine: true });
      const rewardsAvailable = mintedAmount + nextMintAmount;
      await expect(stakingProxy.endEpoch())
        .to.emit(stakingProxy, "EpochFinalized")
        .withArgs(3n, 0n, rewardsAvailable);
      expect(await rigoToken.balanceOf(stakingProxyAddress)).to.be.eq(
        rewardsAvailable,
      );
    });

    // on mainnet it is already set to 0, on altchains we use inflationL2 and standard token
    it("should not allow changing rigoblock address in rigo token contract after set to 0", async () => {
      const { inflation, rigoToken, user1, user2 } = await setupTests();
      const { ethers } = await network.getOrCreate();
      expect(await rigoToken.minter()).to.be.eq(await inflation.getAddress());
      await expect(
        rigoToken.mintToken(ZeroAddress, 5),
      ).to.be.revertedWithoutReason(ethers);
      await rigoToken.changeMintingAddress(user2.address);
      await expect(connect(rigoToken, user2).mintToken(ZeroAddress, 5))
        .to.emit(rigoToken, "TokenMinted")
        .withArgs(ZeroAddress, 5);
      // GRG does not return rich errors. Note: we set minter to 0 after initial setup
      await rigoToken.changeRigoblockAddress(ZeroAddress);
      await expect(
        rigoToken.changeMintingAddress(user1.address),
      ).to.be.revertedWithoutReason(ethers);
      await expect(
        rigoToken.mintToken(ZeroAddress, 5),
      ).to.be.revertedWithoutReason(ethers);
    });
  });

  describe("timeUntilNextClaim", async () => {
    it("should return 0 before second epoch", async () => {
      const { inflation, stakingProxy } = await setupTests();
      expect(await inflation.timeUntilNextClaim()).to.be.eq(0n);
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      expect(await inflation.timeUntilNextClaim()).to.be.eq(0n);
    });

    it("should return positive amount after first claim, 0 after 14 days", async () => {
      const { inflation, stakingProxy } = await setupTests();
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      // after first epoch end will mint for the first time
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      expect(await inflation.timeUntilNextClaim()).to.be.not.eq(0n);
      await timeTravel({ days: 14, mine: true });
      expect(await inflation.timeUntilNextClaim()).to.be.eq(0n);
    });
  });

  describe("getEpochInflation", async () => {
    it("should return 0 before second epoch", async () => {
      const { inflation, stakingProxy } = await setupTests();
      // first epoch required to activate stake
      expect(await inflation.getEpochInflation()).to.be.eq(0n);
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      expect(await inflation.getEpochInflation()).to.be.eq(0n);
    });

    it("should return epoch inflation after first claim", async () => {
      const { inflation, stakingProxy, rigoToken } = await setupTests();
      // first epoch finalization will not mint as no active stake would be possible
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      expect(await inflation.getEpochInflation()).to.be.not.eq(0n);
      const grgSupply = await rigoToken.totalSupply();
      const epochInflation = (((Number(grgSupply) * 2) / 100) * 14) / 365;
      expect(Number(await inflation.getEpochInflation())).to.be.eq(
        epochInflation,
      );
      // fixed amount per epoch regardless time of claim
      await timeTravel({ days: 7, mine: true });
      expect(Number(await inflation.getEpochInflation())).to.be.eq(
        epochInflation,
      );
    });
  });
});
