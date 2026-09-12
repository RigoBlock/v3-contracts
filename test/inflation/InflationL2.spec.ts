import { expect } from "chai";
import { network } from "hardhat";
import { parseEther, ZeroAddress } from "ethers";
import { connect, getFixedGasSigners } from "../shared/helper";
import { createFixture } from "../utils/fixtures";
import { timeTravel } from "../utils/utils";

describe("InflationL2", async () => {
  const setupTests = createFixture(["tests-setup"], async ({ get }) => {
    const [user1, user2] = await getFixedGasSigners();
    const { ethers } = await network.getOrCreate();
    const factory = await ethers.getContractAt(
      "RigoblockPoolProxyFactory",
      (await get("RigoblockPoolProxyFactory")).address,
    );
    const stakingProxy = await ethers.getContractAt(
      "Staking",
      (await get("StakingProxy")).address,
    );
    const rigoToken = await ethers.getContractAt(
      "RigoToken",
      (await get("RigoToken")).address,
    );
    const inflation = await ethers.getContractAt(
      "InflationL2",
      (await get("InflationL2")).address,
    );
    await rigoToken.changeMintingAddress(await inflation.getAddress());
    const { newPoolAddress, poolId } = await factory.createPool.staticCall(
      "testpool",
      "TEST",
      ZeroAddress,
    );
    await factory.createPool("testpool", "TEST", ZeroAddress);
    return {
      inflation,
      rigoToken,
      stakingProxy,
      newPoolAddress,
      poolId,
      user1,
      user2,
    };
  });

  // inflation is hardcoded in staking proxy, whenever the inflationL2 address changes
  //  it must be changed in the staking implementation as well.
  describe("deployedAddress", async () => {
    it("should deploy expected deterministic deployment address", async () => {
      if (
        process.env.PROD == "true" &&
        process.env.CUSTOM_DETERMINISTIC_DEPLOYMENT == "true"
      ) {
        const { inflation } = await setupTests();
        expect(await inflation.getAddress()).to.be.eq(
          "0xA889E90d4F1BA125Df1B4C1f55c7fff9F4377C03",
        );
      }
    });
  });

  describe("initParams", async () => {
    it("should revert if caller not initializer", async () => {
      const { inflation, user2 } = await setupTests();
      await expect(
        connect(inflation, user2).initParams(ZeroAddress, ZeroAddress),
      ).to.be.revertedWith("INFLATIONL2_CALLER_ERROR");
    });

    it("should revert with null inputs", async () => {
      const { inflation } = await setupTests();
      await expect(
        inflation.initParams(ZeroAddress, ZeroAddress),
      ).to.be.revertedWith("INFLATION_NULL_INPUTS_ERROR");
    });

    it("should initialize contract", async () => {
      const { inflation, rigoToken, stakingProxy } = await setupTests();
      expect(await inflation.rigoToken()).to.be.eq(ZeroAddress);
      expect(await inflation.stakingProxy()).to.be.eq(ZeroAddress);
      await inflation.initParams(
        await rigoToken.getAddress(),
        await stakingProxy.getAddress(),
      );
      expect(await inflation.rigoToken()).to.be.eq(
        await rigoToken.getAddress(),
      );
      expect(await inflation.stakingProxy()).to.be.eq(
        await stakingProxy.getAddress(),
      );
    });

    it("should revert if already initialized", async () => {
      const { inflation, rigoToken, stakingProxy, user1 } = await setupTests();
      expect(await inflation.rigoToken()).to.be.eq(ZeroAddress);
      expect(await inflation.stakingProxy()).to.be.eq(ZeroAddress);
      await inflation.initParams(user1.address, user1.address);
      await expect(
        inflation.initParams(
          await rigoToken.getAddress(),
          await stakingProxy.getAddress(),
        ),
      ).to.be.revertedWith("INFLATION_ALREADY_INIT_ERROR");
    });
  });

  describe("mintInflation", async () => {
    it("should revert if InflationL2 not initialized", async () => {
      const { inflation } = await setupTests();
      await expect(inflation.mintInflation()).to.be.revertedWith(
        "INFLATIONL2_NOT_INIT_ERROR",
      );
    });

    it("should revert if caller not staking proxy", async () => {
      const { inflation, stakingProxy, rigoToken } = await setupTests();
      await inflation.initParams(
        await rigoToken.getAddress(),
        await stakingProxy.getAddress(),
      );
      await expect(inflation.mintInflation()).to.be.revertedWith(
        "CALLER_NOT_STAKING_PROXY_ERROR",
      );
    });

    it("should revert if epoch time shortened but time not enough", async () => {
      const { inflation, stakingProxy, rigoToken, user1 } = await setupTests();
      await inflation.initParams(
        await rigoToken.getAddress(),
        await stakingProxy.getAddress(),
      );
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
      await inflation.initParams(
        await rigoToken.getAddress(),
        await stakingProxy.getAddress(),
      );
      // _epochEndTime is initialized in storage only at first mint
      expect(await inflation.epochEnded()).to.be.eq(true);
      await expect(stakingProxy.endEpoch()).to.be.revertedWith(
        "STAKING_TIMESTAMP_TOO_LOW_ERROR",
      );
      await timeTravel({ days: 14, mine: true });
      await expect(stakingProxy.endEpoch())
        .to.emit(stakingProxy, "EpochFinalized")
        .withArgs(1, 0, 0);
      // since staking proxy still does not call mint on inflation, _epochEndTime is still uninitialized
      expect(await inflation.epochEnded()).to.be.eq(true);
      expect(
        await rigoToken.balanceOf(await stakingProxy.getAddress()),
      ).to.be.eq(0n);
      await timeTravel({ days: 14, mine: true });
      let nextMintAmount = await inflation.getEpochInflation();
      expect(nextMintAmount).to.be.eq(0n);
      await expect(stakingProxy.endEpoch())
        .to.emit(stakingProxy, "GrgMintEvent")
        .withArgs(nextMintAmount)
        .to.emit(stakingProxy, "EpochFinalized")
        .withArgs(2, 0, nextMintAmount);
      expect(await inflation.epochEnded()).to.be.eq(false);
      let mintedAmount = await rigoToken.balanceOf(
        await stakingProxy.getAddress(),
      );
      // mint amount returns 0 as contract has null GRG balance
      expect(mintedAmount).to.be.eq(0n);
      nextMintAmount = await inflation.getEpochInflation();
      let tokenAmount = parseEther("500");
      await rigoToken.transfer(await inflation.getAddress(), tokenAmount);
      await timeTravel({ days: 14, mine: true });
      let rewardsAvailable = mintedAmount + nextMintAmount;
      await expect(stakingProxy.endEpoch())
        .to.emit(stakingProxy, "EpochFinalized")
        .withArgs(3, 0, tokenAmount)
        .to.emit(stakingProxy, "GrgMintEvent")
        .withArgs(tokenAmount);
      mintedAmount = await rigoToken.balanceOf(await stakingProxy.getAddress());
      // because inflation contract balance is lower than reward, the minted amount is lower
      expect(mintedAmount).to.be.lt(rewardsAvailable);
      expect(mintedAmount).to.be.eq(tokenAmount);
      nextMintAmount = await inflation.getEpochInflation();
      // this time we transfer enough GRG to enable full epoch reward
      tokenAmount = parseEther("50000");
      await rigoToken.transfer(await inflation.getAddress(), tokenAmount);
      await timeTravel({ days: 14, mine: true });
      rewardsAvailable = mintedAmount + nextMintAmount;
      await expect(stakingProxy.endEpoch())
        .to.emit(stakingProxy, "EpochFinalized")
        .withArgs(4, 0, rewardsAvailable)
        .to.emit(stakingProxy, "GrgMintEvent")
        .withArgs(nextMintAmount);
      mintedAmount = await rigoToken.balanceOf(await stakingProxy.getAddress());
      expect(mintedAmount).to.be.eq(rewardsAvailable);
      expect(mintedAmount).to.be.not.eq(0n);
      expect(mintedAmount).to.be.lt(tokenAmount);
    });

    // on altchains we use standard token, must set to 0 after setup in case we have mainnet clone.
    it("should not allow changing rigoblock address in rigo token contract after set to 0", async () => {
      const { inflation, stakingProxy, rigoToken, user1, user2 } =
        await setupTests();
      await inflation.initParams(
        await rigoToken.getAddress(),
        await stakingProxy.getAddress(),
      );
      expect(await rigoToken.minter()).to.be.eq(await inflation.getAddress());
      const { ethers } = await network.getOrCreate();
      // GRG does not return rich errors, so we assert a plain revert
      await expect(rigoToken.mintToken(ZeroAddress, 5)).to.revert(ethers);
      await rigoToken.changeMintingAddress(user2.address);
      await expect(connect(rigoToken, user2).mintToken(ZeroAddress, 5))
        .to.emit(rigoToken, "TokenMinted")
        .withArgs(ZeroAddress, 5);
      // we set minter to 0 after initial setup
      await rigoToken.changeRigoblockAddress(ZeroAddress);
      await expect(rigoToken.changeMintingAddress(user1.address)).to.revert(
        ethers,
      );
      await expect(rigoToken.mintToken(ZeroAddress, 5)).to.revert(ethers);
    });
  });

  describe("timeUntilNextClaim", async () => {
    it("should return 0 before second epoch", async () => {
      const { inflation, stakingProxy, rigoToken } = await setupTests();
      await inflation.initParams(
        await rigoToken.getAddress(),
        await stakingProxy.getAddress(),
      );
      expect(await inflation.timeUntilNextClaim()).to.be.eq(0n);
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      expect(await inflation.timeUntilNextClaim()).to.be.eq(0n);
    });

    it("should return positive amount after first claim, 0 after 14 days", async () => {
      const { inflation, stakingProxy, rigoToken } = await setupTests();
      await inflation.initParams(
        await rigoToken.getAddress(),
        await stakingProxy.getAddress(),
      );
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
      const { inflation, stakingProxy, rigoToken } = await setupTests();
      await inflation.initParams(
        await rigoToken.getAddress(),
        await stakingProxy.getAddress(),
      );
      // first epoch required to activate stake
      expect(await inflation.getEpochInflation()).to.be.eq(0n);
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      expect(await inflation.getEpochInflation()).to.be.eq(0n);
    });

    it("should return epoch inflation after first claim", async () => {
      const { inflation, stakingProxy, rigoToken } = await setupTests();
      await inflation.initParams(
        await rigoToken.getAddress(),
        await stakingProxy.getAddress(),
      );
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
