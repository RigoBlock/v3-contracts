import { expect } from "chai";
import { network } from "hardhat";

describe("TestSafeDowncast", async () => {
  describe("downcastToUint96", async () => {
    it("should revert when bigger than uint96", async () => {
      const { ethers } = await network.getOrCreate();
      const testSafeDowncast = await ethers.deployContract(
        "TestLibSafeDowncast",
      );
      const uint100 = 2n ** 100n - 1n;
      await expect(
        testSafeDowncast.downcastToUint96(uint100),
      ).to.be.revertedWith("VALUE_TOO_LARGE_TO_DOWNCAST_TO_UINT96");
    });
  });

  describe("downcastToUint64", async () => {
    it("should revert when bigger than uint64", async () => {
      const { ethers } = await network.getOrCreate();
      const testSafeDowncast = await ethers.deployContract(
        "TestLibSafeDowncast",
      );
      const uint80 = 2n ** 80n - 1n;
      await expect(
        testSafeDowncast.downcastToUint64(uint80),
      ).to.be.revertedWith("VALUE_TOO_LARGE_TO_DOWNCAST_TO_UINT64");
    });
  });
});
