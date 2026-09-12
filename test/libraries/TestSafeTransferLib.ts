import { expect } from "chai";
import { network } from "hardhat";
import { parseEther } from "ethers";
import { getFixedGasSigners } from "../shared/helper";

describe("TestSafeTransferLib", async () => {
  describe("testForceApprove", async () => {
    it("should set approval of non-standard ERC20", async () => {
      const [, user2] = await getFixedGasSigners();
      const { ethers } = await network.getOrCreate();
      const testSafeTransferLib = await ethers.deployContract(
        "TestSafeTransferLib",
      );
      const amount = parseEther("1");
      await expect(testSafeTransferLib.testForceApprove(user2.address, amount))
        .to.emit(testSafeTransferLib, "Approval")
        .withArgs(
          await testSafeTransferLib.getAddress(),
          user2.address,
          amount,
        );
      await expect(
        testSafeTransferLib.testForceApprove(user2.address, amount / 2n),
      )
        .to.emit(testSafeTransferLib, "Approval")
        .withArgs(
          await testSafeTransferLib.getAddress(),
          user2.address,
          amount / 2n,
        );
    });
  });
});
