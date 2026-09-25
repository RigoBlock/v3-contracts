import { expect } from "chai";
import { network } from "hardhat";
import { ZeroAddress } from "ethers";
import { getFixedGasSigners } from "../shared/helper";
import { createFixture } from "../utils/fixtures";

describe("Staking", async () => {
  const setupTests = createFixture(["tests-setup"], async ({ get }) => {
    const [user1] = await getFixedGasSigners();
    const { ethers } = await network.getOrCreate();
    const factory = await ethers.getContractAt(
      "RigoblockPoolProxyFactory",
      (await get("RigoblockPoolProxyFactory")).address,
    );
    const { newPoolAddress } = await factory.createPool.staticCall(
      "testpool",
      "TEST",
      ZeroAddress,
    );
    await factory.createPool("testpool", "TEST", ZeroAddress);
    return {
      staking: await ethers.getContractAt(
        "Staking",
        (await get("Staking")).address,
      ),
      newPoolAddress,
      user1,
    };
  });

  describe("createStakingPool", async () => {
    it("should revert with non registered pool", async () => {
      const { staking, newPoolAddress } = await setupTests();
      await expect(
        staking.createStakingPool(newPoolAddress),
      ).to.be.revertedWith("STAKING_DIRECT_CALL_NOT_ALLOWED_ERROR");
    });
  });

  describe("stake", async () => {
    it("should revert with non registered pool", async () => {
      const { staking } = await setupTests();
      await expect(staking.stake(1)).to.be.revertedWith(
        "GRG_VAULT_ONLY_CALLABLE_BY_STAKING_PROXY_ERROR",
      );
    });
  });

  describe("endEpoch", async () => {
    it("should revert with non registered pool", async () => {
      const { staking } = await setupTests();
      const { ethers } = await network.getOrCreate();
      // will revert as not initilized
      // following test will underflow epoch number subtraction
      await expect(staking.endEpoch()).to.revert(ethers);
    });
  });

  describe("init", async () => {
    it("should revert as caller not authorized", async () => {
      const { staking } = await setupTests();
      await expect(staking.init()).to.be.revertedWith(
        "AUTHORIZABLE_SENDER_NOT_AUTHORIZED_ERROR",
      );
    });
  });

  describe("addAuthorizedAddress", async () => {
    it("should revert without error", async () => {
      const { staking, user1 } = await setupTests();
      await expect(
        staking.addAuthorizedAddress(user1.address),
      ).to.be.revertedWith("CALLER_NOT_OWNER_ERROR");
    });
  });

  describe("transferOwnership", async () => {
    it("should revert without error", async () => {
      const { staking } = await setupTests();
      await expect(staking.transferOwnership(ZeroAddress)).to.be.revertedWith(
        "CALLER_NOT_OWNER_ERROR",
      );
    });
  });
});
