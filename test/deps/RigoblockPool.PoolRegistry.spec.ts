import { expect } from "chai";
import { network } from "hardhat";
import { encodeBytes32String, ZeroAddress } from "ethers";
import { connect, getFixedGasSigners } from "../shared/helper";
import { createFixture } from "../utils/fixtures";
import { deployContract } from "../utils/utils";

describe("PoolRegistry", async () => {
  const setupTests = createFixture(["tests-setup"], async ({ get }) => {
    const [user1, user2] = await getFixedGasSigners();
    const { ethers } = await network.getOrCreate();
    const factory = await ethers.getContractAt(
      "RigoblockPoolProxyFactory",
      (await get("RigoblockPoolProxyFactory")).address,
    );
    const registry = await ethers.getContractAt(
      "PoolRegistry",
      (await get("PoolRegistry")).address,
    );
    const authority = await ethers.getContractAt(
      "Authority",
      (await get("Authority")).address,
    );
    return {
      factory,
      registry,
      authority,
      user1,
      user2,
    };
  });

  describe("register", async () => {
    it("should revert if address not whitelisted in authority", async () => {
      const { registry } = await setupTests();
      const mockBytes32 = encodeBytes32String("mock");
      await expect(
        registry.register(ZeroAddress, "testpool", "TEST", mockBytes32),
      ).to.be.revertedWith("REGISTRY_FACTORY_NOT_WHITELISTED_ERROR");
    });

    it("should revert if address already registered", async () => {
      const { authority, registry, user1 } = await setupTests();
      await authority.setFactory(user1.address, true);
      const mockBytes32 = encodeBytes32String("mock");
      await registry.register(ZeroAddress, "testpool", "TEST", mockBytes32);
      await expect(
        registry.register(ZeroAddress, " testpool", "TEST", mockBytes32),
      ).to.be.revertedWith("REGISTRY_ADDRESS_ALREADY_TAKEN_ERROR");
    });

    it("should revert if name longer than 32 characters", async () => {
      const { authority, registry, user1 } = await setupTests();
      await authority.setFactory(user1.address, true);
      const mockBytes32 = encodeBytes32String("mock");
      const longName = "40 characters are way too long for a name";
      const shortName = "sho";
      await expect(
        registry.register(ZeroAddress, longName, "TEST", mockBytes32),
      ).to.be.revertedWith("REGISTRY_NAME_LENGTH_ERROR");
      await expect(
        registry.register(ZeroAddress, shortName, "TEST", mockBytes32),
      ).to.be.revertedWith("REGISTRY_NAME_LENGTH_ERROR");
    });
  });

  describe("setMeta", async () => {
    it("should revert if caller is not pool owner", async () => {
      const { registry, user2 } = await setupTests();
      const source = `
            contract Owned {
                address public owner;
                function setOwner(address _owner) public { owner = _owner; }
            }`;
      const mockPool = await deployContract(user2 as any, source);
      await mockPool.setOwner(user2.address);
      const key = encodeBytes32String("mock");
      const value = encodeBytes32String("value");
      await expect(
        registry.setMeta(await mockPool.getAddress(), key, value),
      ).to.be.revertedWith("REGISTRY_CALLER_IS_NOT_POOL_OWNER_ERROR");
    });

    it("should revert if pool not registered", async () => {
      const { registry, authority, user1, user2 } = await setupTests();
      const source = `
            contract Owned {
                address public owner;
                function setOwner(address _owner) public { owner = _owner; }
            }`;
      const mockPool = await deployContract(user1 as any, source);
      await mockPool.setOwner(user2.address);
      const poolAddress = await mockPool.getAddress();
      const poolId = encodeBytes32String("mockId");
      const key = encodeBytes32String("mock");
      const value = encodeBytes32String("value");
      await expect(
        connect(registry, user2).setMeta(poolAddress, key, value),
      ).to.be.revertedWith("REGISTRY_ADDRESS_NOT_REGISTERED_ERROR");
      await authority.setFactory(user1.address, true);
      await registry.register(poolAddress, "testName", "TEST", poolId);
      await expect(connect(registry, user2).setMeta(poolAddress, key, value))
        .to.emit(registry, "MetaChanged")
        .withArgs(poolAddress, key, value);
      expect(await registry.getMeta(poolAddress, key)).to.be.eq(value);
    });
  });

  describe("setAuthority", async () => {
    it("should revert if caller not dao address", async () => {
      const { factory, registry, user1, user2 } = await setupTests();
      await expect(
        connect(registry, user2).setAuthority(ZeroAddress),
      ).to.be.revertedWith("REGISTRY_CALLER_NOT_DAO_ERROR");
      const authorityAddress = await registry.authority();
      await expect(registry.setAuthority(authorityAddress)).to.be.revertedWith(
        "REGISTRY_SAME_INPUT_ADDRESS_ERROR",
      );
      await expect(registry.setAuthority(user1.address)).to.be.revertedWith(
        "REGISTRY_NEW_AUTHORITY_NOT_CONTRACT_ERROR",
      );
      await expect(registry.setAuthority(ZeroAddress)).to.be.revertedWith(
        "REGISTRY_NEW_AUTHORITY_NOT_CONTRACT_ERROR",
      );
      const factoryAddress = await factory.getAddress();
      await expect(registry.setAuthority(factoryAddress))
        .to.emit(registry, "AuthorityChanged")
        .withArgs(factoryAddress);
      expect(await registry.authority()).to.be.eq(factoryAddress);
    });
  });

  describe("setRigoblockDao", async () => {
    it("should revert if caller not dao address", async () => {
      const { factory, registry, user1, user2 } = await setupTests();
      await expect(
        connect(registry, user2).setRigoblockDao(ZeroAddress),
      ).to.be.revertedWith("REGISTRY_CALLER_NOT_DAO_ERROR");
      const daoAddress = await registry.rigoblockDao();
      await expect(registry.setRigoblockDao(daoAddress)).to.be.revertedWith(
        "REGISTRY_SAME_INPUT_ADDRESS_ERROR",
      );
      await expect(registry.setRigoblockDao(user2.address)).to.be.revertedWith(
        "REGISTRY_NEW_DAO_NOT_CONTRACT_ERROR",
      );
      await expect(registry.setRigoblockDao(ZeroAddress)).to.be.revertedWith(
        "REGISTRY_NEW_DAO_NOT_CONTRACT_ERROR",
      );
      const factoryAddress = await factory.getAddress();
      await expect(registry.setRigoblockDao(factoryAddress))
        .to.emit(registry, "RigoblockDaoChanged")
        .withArgs(factoryAddress);
      expect(await registry.rigoblockDao()).to.be.eq(factoryAddress);
    });
  });
});
