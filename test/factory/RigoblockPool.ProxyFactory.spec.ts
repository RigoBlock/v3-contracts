import { expect } from "chai";
import { network } from "hardhat";
import { encodeBytes32String, ZeroAddress, type EventLog } from "ethers";
import { connect, getFixedGasSigners } from "../shared/helper";
import { createFixture } from "../utils/fixtures";
import { deployContract } from "../utils/utils";

describe("ProxyFactory", async () => {
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
    const authorityAddress = (await get("Authority")).address;
    return {
      factory,
      registry,
      authorityAddress,
      user1,
      user2,
    };
  });

  describe("createPool", async () => {
    it("should revert with space before pool name", async () => {
      const { factory } = await setupTests();
      await expect(
        factory.createPool(" testpool", "TEST", ZeroAddress),
      ).to.be.revertedWith("LIBSANITIZE_SPACE_AT_BEGINNING_ERROR");
    });

    it("should revert with space after pool name", async () => {
      const { factory } = await setupTests();
      await expect(
        factory.createPool("testpool ", "TEST", ZeroAddress),
      ).to.be.revertedWith("LIBSANITIZE_SPACE_AT_END_ERROR");
    });

    it("should revert with special character in pool name", async () => {
      const { factory } = await setupTests();
      await expect(
        factory.createPool("test+pool", "TEST", ZeroAddress),
      ).to.be.revertedWith("LIBSANITIZE_SPECIAL_CHARACTER_ERROR");
    });

    it("should revert with space before pool symbol", async () => {
      const { factory } = await setupTests();
      await expect(
        factory.createPool("testpool2", " TEST", ZeroAddress),
      ).to.be.revertedWith("LIBSANITIZE_SPACE_AT_BEGINNING_ERROR");
    });

    it("should create address when creating pool", async () => {
      const { factory, registry } = await setupTests();
      const { newPoolAddress, poolId } = await factory.createPool.staticCall(
        "testpool",
        "TEST",
        ZeroAddress,
      );
      const bytes32symbol = encodeBytes32String("testpool");
      const bytes32name = encodeBytes32String("TEST");
      await expect(factory.createPool("testpool", "TEST", ZeroAddress))
        .to.emit(registry, "Registered")
        .withArgs(
          await factory.getAddress(),
          newPoolAddress,
          bytes32symbol,
          bytes32name,
          poolId,
        );
      expect(await registry.getPoolIdFromAddress(newPoolAddress)).to.be.eq(
        poolId,
      );
      await expect(
        factory.createPool("testpool", "TEST", ZeroAddress),
      ).to.be.revertedWith("FACTORY_CREATE2_FAILED_ERROR");
    });

    // following test used to assert try/catch return bytes error.
    // Careful with upgrades as upgrading an address could result in revert in another contract.
    it("should be reverted in registry without error", async () => {
      const { factory, registry, authorityAddress } = await setupTests();
      await registry.setAuthority(await factory.getAddress());
      // will be reverted without error as registry modifier calls non-implemented Authority.isWhitelistedFactory method
      await expect(
        factory.createPool("testpool", "TEST", ZeroAddress),
      ).to.be.revertedWith("");
      await registry.setAuthority(authorityAddress);
      await factory.setRegistry(await factory.getAddress());
      // will be reverted without error as factory does not implement Registry.register method
      await expect(
        factory.createPool("testpool", "TEST", ZeroAddress),
      ).to.be.revertedWith("");
    });

    it("should create pool with space not first or last character", async () => {
      const { factory } = await setupTests();
      const { newPoolAddress } = await factory.createPool.staticCall(
        "t est pool",
        "TEST",
        ZeroAddress,
      );
      const tx = await factory.createPool("t est pool", "TEST", ZeroAddress);
      // 4 logs are emitted at pool creation, could expect exact event.withArgs
      const receipt = await tx.wait();
      expect((receipt!.logs[3] as EventLog).args.poolAddress).to.be.eq(
        newPoolAddress,
      );
    });

    it("should create pool with uppercase character in name", async () => {
      const { factory } = await setupTests();
      await expect(factory.createPool("testPool", "TEST", ZeroAddress)).to.emit(
        factory,
        "PoolCreated",
      );
    });

    // a pool with same owner and name should have unique address
    it("should revert when contract exists already", async () => {
      const { factory } = await setupTests();
      await factory.createPool("duplicateName", "TEST", ZeroAddress);
      await expect(
        factory.createPool("duplicateName", "TEST", ZeroAddress),
      ).to.be.revertedWith("FACTORY_CREATE2_FAILED_ERROR");
      await expect(
        factory.createPool("duplicateName", "TEST2", ZeroAddress),
      ).to.be.revertedWith("FACTORY_CREATE2_FAILED_ERROR");
    });

    it("should revert when contract exists with base token", async () => {
      const { factory } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const weth = await ethers.deployContract("WETH9");
      await factory.createPool(
        "duplicateName",
        "TEST",
        await weth.getAddress(),
      );
      await expect(
        factory.createPool("duplicateName", "TEST", await weth.getAddress()),
      ).to.be.revertedWith("FACTORY_CREATE2_FAILED_ERROR");
      await expect(
        factory.createPool("duplicateName", "TEST2", await weth.getAddress()),
      ).to.be.revertedWith("FACTORY_CREATE2_FAILED_ERROR");
    });

    it("should revert when contract exists with different implementation", async () => {
      const { factory, user1 } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const weth = await ethers.deployContract("WETH9");
      await factory.createPool(
        "duplicateName",
        "TEST",
        await weth.getAddress(),
      );
      const source = "contract Impl { function initializePool() external {} }";
      const impl = await deployContract(user1 as any, source);
      await factory.setImplementation(await impl.getAddress());
      await expect(
        factory.createPool("duplicateName", "TEST", await weth.getAddress()),
      ).to.be.revertedWith("FACTORY_CREATE2_FAILED_ERROR");
      await expect(
        factory.createPool("duplicateName", "TEST2", await weth.getAddress()),
      ).to.be.revertedWith("FACTORY_CREATE2_FAILED_ERROR");
    });

    it("should create pool with duplicate name", async () => {
      const { factory, user2 } = await setupTests();
      await expect(
        factory.createPool("duplicateName", "TEST", ZeroAddress),
      ).to.emit(factory, "PoolCreated");
      await expect(
        factory.createPool("duplicateName", "TEST", ZeroAddress),
      ).to.be.revertedWith("FACTORY_CREATE2_FAILED_ERROR");
      await expect(
        connect(factory, user2).createPool(
          "duplicateName",
          "TEST",
          ZeroAddress,
        ),
      ).to.emit(factory, "PoolCreated");
    });

    it("should create pool with duplicate symbol", async () => {
      const { factory } = await setupTests();
      await factory.createPool("someName", "TEST", ZeroAddress);
      await expect(
        factory.createPool("someOtherName", "TEST", ZeroAddress),
      ).to.emit(factory, "PoolCreated");
    });

    it("should revert with symbol longer than 5 characters", async () => {
      const { factory } = await setupTests();
      await expect(
        factory.createPool("testpool2", "TOOLONG", ZeroAddress),
      ).to.be.revertedWith("REGISTRY_SYMBOL_LENGTH_ERROR");
    });

    it("should revert with symbol shorter than 3 characters", async () => {
      const { factory } = await setupTests();
      await expect(
        factory.createPool("testpool2", "TS", ZeroAddress),
      ).to.be.revertedWith("REGISTRY_SYMBOL_LENGTH_ERROR");
    });

    it("should revert with lowercase symbol", async () => {
      const { factory } = await setupTests();
      await expect(
        factory.createPool("testpool2", "test", ZeroAddress),
      ).to.be.revertedWith("LIBSANITIZE_UPPERCASE_CHARACTER_ERROR");
    });

    it("should revert with rogue base token", async () => {
      const { factory, user1 } = await setupTests();
      const source =
        "contract RogueToken { function decimals() external pure returns (uint8) { return 5; } }";
      const rogueToken = await deployContract(user1 as any, source);
      await expect(
        factory.createPool("testpool", "TEST", await rogueToken.getAddress()),
      ).to.be.revertedWith("POOL_INITIALIZATION_FAILED_ERROR");
    });

    it("should revert when base token does not implement decimals", async () => {
      const { factory, user1 } = await setupTests();
      const source =
        "contract RogueToken { function rogue() external pure returns (uint8) { return 0; } }";
      const rogueToken = await deployContract(user1 as any, source);
      await expect(
        factory.createPool("testpool", "TEST", await rogueToken.getAddress()),
      ).to.be.revertedWith("POOL_INITIALIZATION_FAILED_ERROR");
    });

    it("should revert when base token is not a contract", async () => {
      const { factory, user1 } = await setupTests();
      const source =
        "contract RogueToken { function decimals() external pure returns (uint8) { return 5; } }";
      const rogueToken = await deployContract(user1 as any, source);
      await expect(
        factory.createPool("testpool", "TEST", user1.address),
      ).to.be.revertedWith("POOL_INITIALIZATION_FAILED_ERROR");
    });
  });

  describe("setImplementation", async () => {
    it("should revert if caller not dao address", async () => {
      const { factory, registry, user1, user2 } = await setupTests();
      await expect(
        connect(factory, user2).setImplementation(ZeroAddress),
      ).to.be.revertedWith("FACTORY_CALLER_NOT_DAO_ERROR");
      await expect(factory.setImplementation(user1.address)).to.be.revertedWith(
        "FACTORY_NEW_IMPLEMENTATION_NOT_CONTRACT_ERROR",
      );
      await expect(factory.setImplementation(ZeroAddress)).to.be.revertedWith(
        "FACTORY_NEW_IMPLEMENTATION_NOT_CONTRACT_ERROR",
      );
      const registryAddress = await registry.getAddress();
      await expect(factory.setImplementation(registryAddress))
        .to.emit(factory, "Upgraded")
        .withArgs(registryAddress);
      expect(await factory.implementation()).to.be.eq(registryAddress);
      await expect(
        factory.setImplementation(registryAddress),
      ).to.be.revertedWith("FACTORY_SAME_INPUT_ADDRESS_ERROR");
    });
  });

  describe("setRegistry", async () => {
    it("should revert if caller not dao address", async () => {
      const { factory, registry, user1, user2 } = await setupTests();
      await expect(
        connect(factory, user2).setRegistry(ZeroAddress),
      ).to.be.revertedWith("FACTORY_CALLER_NOT_DAO_ERROR");
      await expect(factory.setRegistry(user1.address)).to.be.revertedWith(
        "FACTORY_NEW_REGISTRY_NOT_CONTRACT_ERROR",
      );
      await expect(factory.setRegistry(ZeroAddress)).to.be.revertedWith(
        "FACTORY_NEW_REGISTRY_NOT_CONTRACT_ERROR",
      );
      const registryAddress = await registry.getAddress();
      await expect(factory.setRegistry(registryAddress)).to.be.revertedWith(
        "FACTORY_SAME_INPUT_ADDRESS_ERROR",
      );
      const factoryAddress = await factory.getAddress();
      await expect(factory.setRegistry(factoryAddress))
        .to.emit(factory, "RegistryUpgraded")
        .withArgs(factoryAddress);
      expect(await factory.getRegistry()).to.be.eq(factoryAddress);
      // the following transaction will be reverted as rigoblock dao assertion queries dao from registry and in this context
      // factory does not implement same interface. Factory used as mock address to test that address gets updated.
      // ethers v6 returns empty revert data for calls to unrecognized selectors on contracts without fallback
      const { ethers } = await network.getOrCreate();
      await expect(factory.setRegistry(factoryAddress)).to.revert(ethers);
    });
  });
});
