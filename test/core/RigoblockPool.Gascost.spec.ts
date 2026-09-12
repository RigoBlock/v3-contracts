import { expect } from "chai";
import { network } from "hardhat";
import { ZeroAddress, parseEther } from "ethers";
import { getFixedGasSigners } from "../shared/helper";
import { createFixture } from "../utils/fixtures";

describe("ProxyGasCost", async () => {
  const MAX_TICK_SPACING = 32767;

  const setupTests = createFixture(["tests-setup"], async ({ get }) => {
    const [user1] = await getFixedGasSigners();
    const { ethers } = await network.getOrCreate();
    const factory = await ethers.getContractAt(
      "RigoblockPoolProxyFactory",
      (await get("RigoblockPoolProxyFactory")).address,
    );
    const grgToken = await ethers.getContractAt(
      "RigoToken",
      (await get("RigoToken")).address,
    );
    const oracle = await ethers.getContractAt(
      "MockOracle",
      (await get("MockOracle")).address,
    );
    return {
      factory,
      grgToken,
      oracle,
      user1,
    };
  });

  describe("calculateCost", async () => {
    it("should create pool whose size is smaller than 500k gas", async () => {
      const { factory } = await setupTests();
      const txReceipt = await factory.createPool(
        "t est pool",
        "TEST",
        ZeroAddress,
      );
      const result = await txReceipt.wait();
      const gasCost = Number(result!.gasUsed);
      console.log(gasCost, "pool with base coin");
      // actual size will be affected in tests coverage (+100K), will require updating
      expect(gasCost).to.be.lt(500000);
    });

    it("should cost less than 500k gas with base token", async () => {
      const { factory, grgToken } = await setupTests();
      const txReceipt = await factory.createPool(
        "t est pool",
        "TEST",
        await grgToken.getAddress(),
      );
      const result = await txReceipt.wait();
      const gasCost = Number(result!.gasUsed);
      console.log(gasCost, "pool with base token");
      // actual size will be affected in tests coverage (+100K), will require updating
      expect(gasCost).to.be.lt(500000);
    });

    it("logs gas cost for eth pool mint", async () => {
      const { factory, user1 } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const newPoolAddress = (
        await factory.createPool.staticCall("testpool", "TEST", ZeroAddress)
      )[0];
      await factory.createPool("testpool", "TEST", ZeroAddress);
      const pool = await ethers.getContractAt("SmartPool", newPoolAddress);
      const etherAmount = parseEther("1");
      let txReceipt = await pool.mint(user1.address, etherAmount, 0, {
        value: etherAmount,
      });
      let result = await txReceipt.wait();
      let gasCost = Number(result!.gasUsed);
      console.log(gasCost, "first eth pool mint");
      txReceipt = await pool.mint(user1.address, etherAmount, 0, {
        value: etherAmount,
      });
      result = await txReceipt.wait();
      gasCost = Number(result!.gasUsed);
      console.log(gasCost, "second eth pool mint");
    });

    it("logs gas cost for token pool mint", async () => {
      const { factory, grgToken, oracle, user1 } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const newPoolAddress = (
        await factory.createPool.staticCall(
          "testpool",
          "TEST",
          await grgToken.getAddress(),
        )
      )[0];
      await factory.createPool("testpool", "TEST", await grgToken.getAddress());
      const pool = await ethers.getContractAt("SmartPool", newPoolAddress);
      const etherAmount = parseEther("1");
      const numberOfMintOperations = 2;
      await grgToken.approve(
        await pool.getAddress(),
        etherAmount * BigInt(numberOfMintOperations),
      );
      const poolKey = {
        currency0: ZeroAddress,
        currency1: await grgToken.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(poolKey);
      let txReceipt = await pool.mint(user1.address, etherAmount, 0);
      let result = await txReceipt.wait();
      let gasCost = Number(result!.gasUsed);
      console.log(gasCost, "first token pool mint");
      txReceipt = await pool.mint(user1.address, etherAmount, 0);
      result = await txReceipt.wait();
      gasCost = Number(result!.gasUsed);
      console.log(gasCost, "second token pool mint");
    });
  });
});
