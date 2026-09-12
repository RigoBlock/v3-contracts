import { expect } from "chai";
import { network } from "hardhat";
import { MaxUint256, ZeroAddress } from "ethers";
import { connect, getFixedGasSigners } from "../shared/helper";
import { createFixture } from "../utils/fixtures";

describe("AMulticall", async () => {
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
    // used to match custom errors emitted by the implementation
    const poolImplementation = await ethers.getContractAt(
      "SmartPool",
      newPoolAddress,
    );
    const aMulticall = await ethers.getContractAt(
      "AMulticall",
      (await get("AMulticall")).address,
    );
    const eUpgrade = await ethers.deployContract("EUpgrade", [
      await factory.getAddress(),
    ]);
    await authority.setAdapter(await aMulticall.getAddress(), true);
    await authority.setAdapter(await eUpgrade.getAddress(), true);
    // "ac9650d8": "multicall(bytes[])"
    await authority.addMethod("0xac9650d8", await aMulticall.getAddress());
    // "5ae401dc": "multicall(uint256,bytes[])"
    await authority.addMethod("0x5ae401dc", await aMulticall.getAddress());
    // "1f0464d1": "multicall(bytes32,bytes[])"
    await authority.addMethod("0x1f0464d1", await aMulticall.getAddress());
    // "466f3dc3": "upgradeImplementation()"
    await authority.addMethod("0x466f3dc3", await eUpgrade.getAddress());
    return {
      authority,
      aMulticall,
      eUpgrade,
      pool,
      poolImplementation,
      factory,
      newPoolAddress,
      user1,
      user2,
    };
  });

  describe("multicall", async () => {
    // as a call gets re-routed to the contract, a direct call will be reverted in the implementing methods.
    it("should allow direct call", async () => {
      const { aMulticall, pool, user1, user2 } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const encodedSetOwnerData = pool.interface.encodeFunctionData(
        "setOwner",
        [user2.address],
      );
      const encodedMulticallData = aMulticall.interface.encodeFunctionData(
        "multicall(bytes[])",
        [[encodedSetOwnerData]],
      );
      // a direct call to the extension always fails
      await expect(
        user1.sendTransaction({
          to: await aMulticall.getAddress(),
          value: 0,
          data: encodedMulticallData,
        }),
      ).to.revert(ethers);
    });

    it("should revert if method not implemented", async () => {
      const {
        aMulticall,
        authority,
        factory,
        newPoolAddress,
        pool,
        poolImplementation,
        user1,
        user2,
      } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const encodedSetImplementation = factory.interface.encodeFunctionData(
        "setImplementation",
        [user2.address],
      );
      const encodedMulticallData = pool.interface.encodeFunctionData(
        "multicall(bytes[])",
        [[encodedSetImplementation]],
      );
      // txn will always revert in fallback: setImplementation is not mapped,
      // pool fallback reverts with PoolMethodNotAllowed, AMulticall forwards the underlying revert reason.
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedMulticallData,
        }),
      ).to.be.revertedWithCustomError(
        poolImplementation,
        "PoolMethodNotAllowed",
      );
      // if a rogue adapter could be added by the governance, but that is part of the protocol rules.
      await authority.setAdapter(await factory.getAddress(), true);
      // "d784d426": "setImplementation(address)"
      await authority.addMethod("0xd784d426", await factory.getAddress());
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedMulticallData,
        }),
      ).to.revert(ethers);
      // however, an adapter <> selector mapping misconfiguration will result in revert
      await authority.removeMethod("0xd784d426", await factory.getAddress());
      await authority.addMethod("0xd784d426", await aMulticall.getAddress());
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedMulticallData,
        }),
      ).to.revert(ethers);
    });

    it("should prevent skipping owner check", async () => {
      const { eUpgrade, factory, newPoolAddress, pool, user1, user2 } =
        await setupTests();
      const { ethers } = await network.getOrCreate();
      // when the method is called by a wallet other than the pool owner, the ExtensionsMap prompts the fallback
      // to forward a `staticcall` to the target extension. Therefore, instead of being executed in the context
      // of the pool proxy, it gets executed in the EUpgrade contract and is thus reverted as a direct call is not allowed.
      await expect(
        connect(pool, user2).upgradeImplementation(),
      ).to.be.revertedWithCustomError(eUpgrade, "EUpgradeDirectCall");
      await factory.setImplementation(await factory.getAddress());
      const encodedUpgradeData = pool.interface.encodeFunctionData(
        "upgradeImplementation",
      );
      const encodedMulticallData = pool.interface.encodeFunctionData(
        "multicall(bytes[])",
        [[encodedUpgradeData]],
      );
      // in the non-owner staticcall path the inner delegatecall target is the adapter itself,
      // so no rich revert reason is produced; the transaction still reverts.
      await expect(
        user2.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedMulticallData,
        }),
      ).to.revert(ethers);
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedMulticallData,
        }),
      )
        .to.emit(pool, "Upgraded")
        .withArgs(await factory.getAddress());
    });

    it("should allow owner to set a new owner", async () => {
      const { newPoolAddress, pool, poolImplementation, user1, user2 } =
        await setupTests();
      const { ethers } = await network.getOrCreate();
      await expect(
        connect(pool, user2).setOwner(user2.address),
      ).to.be.revertedWithCustomError(
        poolImplementation,
        "PoolCallerIsNotOwner",
      );
      const encodedSetOwnerData = pool.interface.encodeFunctionData(
        "setOwner",
        [user2.address],
      );
      const encodedMulticallData = pool.interface.encodeFunctionData(
        "multicall(bytes[])",
        [[encodedSetOwnerData]],
      );
      // in the non-owner staticcall path the inner delegatecall target is the adapter itself,
      // so no rich revert reason is produced; the transaction still reverts.
      await expect(
        user2.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedMulticallData,
        }),
      ).to.revert(ethers);
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedMulticallData,
        }),
      )
        .to.emit(pool, "NewOwner")
        .withArgs(user1.address, user2.address);
    });

    it("should upgrade implementation", async () => {
      const { factory, newPoolAddress, pool, user1, user2 } =
        await setupTests();
      const { ethers } = await network.getOrCreate();
      await factory.setImplementation(await factory.getAddress());
      const encodedUpgradeData = pool.interface.encodeFunctionData(
        "upgradeImplementation",
      );
      const encodedMulticallData = pool.interface.encodeFunctionData(
        "multicall(bytes[])",
        [[encodedUpgradeData]],
      );
      // in the non-owner staticcall path the inner delegatecall target is the adapter itself,
      // so no rich revert reason is produced; the transaction still reverts.
      await expect(
        user2.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedMulticallData,
        }),
      ).to.revert(ethers);
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedMulticallData,
        }),
      )
        .to.emit(pool, "Upgraded")
        .withArgs(await factory.getAddress());
    });

    // reentrancy is blocked in the methods' implementations, where needed.
    it("should not prevent reentrancy", async () => {
      const { newPoolAddress, pool, user1, user2 } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const encodedSetOwnerData = pool.interface.encodeFunctionData(
        "setOwner",
        [user2.address],
      );
      const encodedMulticallData = pool.interface.encodeFunctionData(
        "multicall(bytes[])",
        [[encodedSetOwnerData]],
      );
      const recursiveMulticallData = pool.interface.encodeFunctionData(
        "multicall(bytes[])",
        [[encodedMulticallData]],
      );
      await expect(
        user2.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: recursiveMulticallData,
        }),
      ).to.revert(ethers);
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: recursiveMulticallData,
        }),
      )
        .to.emit(pool, "NewOwner")
        .withArgs(user1.address, user2.address);
    });

    it("should revert on recursive call with unknown method", async () => {
      const { authority, factory, newPoolAddress, pool, user1, user2 } =
        await setupTests();
      const { ethers } = await network.getOrCreate();
      await authority.setAdapter(await factory.getAddress(), true);
      // "d784d426": "setImplementation(address)"
      await authority.addMethod("0xd784d426", await factory.getAddress());
      const unknownData = factory.interface.encodeFunctionData(
        "setImplementation",
        [user2.address],
      );
      const encodedMulticallData = pool.interface.encodeFunctionData(
        "multicall(bytes[])",
        [[unknownData]],
      );
      const recursiveMulticallData = pool.interface.encodeFunctionData(
        "multicall(bytes[])",
        [[encodedMulticallData]],
      );
      await expect(
        user2.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: recursiveMulticallData,
        }),
      ).to.revert(ethers);
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: recursiveMulticallData,
        }),
      ).to.revert(ethers);
    });

    it("should propagate custom errors from inner calls", async () => {
      const { eUpgrade, newPoolAddress, pool, user1 } = await setupTests();
      const encodedUpgradeData = pool.interface.encodeFunctionData(
        "upgradeImplementation",
      );
      const encodedMulticallData = pool.interface.encodeFunctionData(
        "multicall(bytes[])",
        [[encodedUpgradeData]],
      );
      // implementation has not changed, so upgrade reverts with a custom error
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

    it("should support multicall with deadline", async () => {
      const { newPoolAddress, pool, user1, user2 } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const encodedSetOwnerData = pool.interface.encodeFunctionData(
        "setOwner",
        [user2.address],
      );
      const encodedMulticallData = pool.interface.encodeFunctionData(
        "multicall(uint256,bytes[])",
        [MaxUint256, [encodedSetOwnerData]],
      );
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedMulticallData,
        }),
      )
        .to.emit(pool, "NewOwner")
        .withArgs(user1.address, user2.address);
    });

    it("should support multicall with previousBlockhash", async () => {
      const { newPoolAddress, pool, user1, user2 } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const previousBlock = await ethers.provider.getBlock("latest");
      const encodedSetOwnerData = pool.interface.encodeFunctionData(
        "setOwner",
        [user2.address],
      );
      const encodedMulticallData = pool.interface.encodeFunctionData(
        "multicall(bytes32,bytes[])",
        [previousBlock!.hash!, [encodedSetOwnerData]],
      );
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedMulticallData,
        }),
      )
        .to.emit(pool, "NewOwner")
        .withArgs(user1.address, user2.address);
    });
  });
});
