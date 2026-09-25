import { expect } from "chai";
import { network } from "hardhat";
import { ZeroAddress } from "ethers";
import { connect, getFixedGasSigners } from "../shared/helper";
import { createFixture } from "../utils/fixtures";

describe("EUpgrade", async () => {
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
    const { newPoolAddress } = await factory.createPool.staticCall(
      "testpool",
      "TEST",
      ZeroAddress,
    );
    await factory.createPool("testpool", "TEST", ZeroAddress);
    const pool = await ethers.getContractAt(
      "IRigoblockPoolExtended",
      newPoolAddress,
    );
    const eUpgrade = await ethers.deployContract("EUpgrade", [
      await factory.getAddress(),
    ]);
    const multicallAddress = (await get("AMulticall")).address;
    await authority.setAdapter(await eUpgrade.getAddress(), true);
    // "466f3dc3": "upgradeImplementation()"
    await authority.addMethod("0x466f3dc3", await eUpgrade.getAddress());
    // "2d6b3a6b": "getBeacon()"
    await authority.addMethod("0x2d6b3a6b", await eUpgrade.getAddress());
    return {
      authority,
      eUpgrade,
      multicallAddress,
      pool,
      factory,
      newPoolAddress,
      user1,
      user2,
    };
  });

  describe("upgradeImplementation", async () => {
    it("should revert if called directly", async () => {
      const { eUpgrade } = await setupTests();
      await expect(
        eUpgrade.upgradeImplementation(),
      ).to.be.revertedWithCustomError(eUpgrade, "EUpgradeDirectCall");
    });

    it("should revert if new implementation is same as current", async () => {
      const { eUpgrade, pool } = await setupTests();
      await expect(pool.upgradeImplementation()).to.be.revertedWithCustomError(
        eUpgrade,
        "EUpgradeImplementationIsSameAsCurrent",
      );
    });

    it("should upgrade implementation", async () => {
      const { factory, pool } = await setupTests();
      await factory.setImplementation(await factory.getAddress());
      await expect(pool.upgradeImplementation())
        .to.emit(pool, "Upgraded")
        .withArgs(await factory.getAddress());
    });

    // when a user who is not the pool owner tries to upgrade the implementation a staticcall is made to the extension, instead of a delegatecall
    it("should revert if caller is not pool owner", async () => {
      const { eUpgrade, factory, pool, user2 } = await setupTests();
      await factory.setImplementation(await factory.getAddress());
      await expect(
        connect(pool, user2).upgradeImplementation(),
      ).to.be.revertedWithCustomError(eUpgrade, "EUpgradeDirectCall");
    });

    it("should not allow multicall to upgrade for non-owner", async () => {
      const {
        authority,
        eUpgrade,
        multicallAddress,
        newPoolAddress,
        pool,
        user1,
      } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const encodedUpgradeData = pool.interface.encodeFunctionData(
        "upgradeImplementation",
      );
      const multicallPool = await ethers.getContractAt(
        "AMulticall",
        newPoolAddress,
      );
      await authority.setAdapter(multicallAddress, true);
      // "ac9650d8": "multicall(bytes[])"
      await authority.addMethod("0xac9650d8", multicallAddress);
      const encodedMulticallData = multicallPool.interface.encodeFunctionData(
        "multicall(bytes[])",
        [[encodedUpgradeData]],
      );
      // multicall forwards the underlying custom error
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedMulticallData,
        }),
      ).to.be.revertedWithCustomError(
        eUpgrade,
        "EUpgradeImplementationIsSameAsCurrent",
      );
    });
  });
});
