import { expect } from "chai";
import { network } from "hardhat";

describe("TestCobbDouglas", async () => {
  describe("getCobbDouglasReward", async () => {
    it("should return 0 with 0 fee ratio or 0 stake ratio", async () => {
      const { ethers } = await network.getOrCreate();
      const testCobbDouglas = await ethers.deployContract("TestCobbDouglas");
      let reward;
      reward = await testCobbDouglas.getCobbDouglasReward(
        100,
        10,
        100,
        20,
        200,
        2,
        3,
      );
      expect(reward).to.be.not.eq(0n);
      reward = await testCobbDouglas.getCobbDouglasReward(
        100,
        0,
        100,
        20,
        200,
        2,
        3,
      );
      expect(reward).to.be.deep.eq(0n);
      reward = await testCobbDouglas.getCobbDouglasReward(
        100,
        10,
        100,
        0,
        200,
        2,
        3,
      );
      expect(reward).to.be.deep.eq(0n);
    });
  });
});
