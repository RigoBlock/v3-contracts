import { expect } from "chai";
import { network } from "hardhat";
import {
  AbiCoder,
  ZeroAddress,
  dataSlice,
  encodeBytes32String,
  getBytes,
  parseEther,
  solidityPacked,
  toUtf8String,
} from "ethers";
import { connect, getFixedGasSigners } from "../shared/helper";
import { createFixture } from "../utils/fixtures";

describe("MixinStorageAccessible", async () => {
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
    const newPoolAddress = (
      await factory.createPool.staticCall("testpool", "TEST", ZeroAddress)
    )[0];
    await factory.createPool("testpool", "TEST", ZeroAddress);
    const pool = await ethers.getContractAt("SmartPool", newPoolAddress);
    return {
      authority,
      factory,
      pool,
      grgTokenAddress: (await get("RigoToken")).address,
      smartPoolAddress: (await get("SmartPool")).address,
      user1,
      user2,
    };
  });

  // this method is not useful when reading non-null uninitialized params (implementation defaults are used),
  //  i.e. 'unitaryValue', 'spread', 'minPeriod', 'decimals'
  describe("getStorageAt", async () => {
    it("can read beacon and upgrade implementation", async () => {
      const { factory, pool } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const extension = await ethers.deployContract("EUpgrade", [
        await factory.getAddress(),
      ]);
      const ePool = await ethers.getContractAt(
        "EUpgrade",
        await pool.getAddress(),
      );
      const beacon = await ePool.getBeacon.staticCall();
      expect(beacon).to.be.eq(await factory.getAddress());
      const implementationSlot =
        "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
      const implementation = await pool.getStorageAt(implementationSlot, 1);
      const encodedPack = solidityPacked(["uint160"], [implementation]);
      expect(encodedPack).to.be.eq(
        (await factory.implementation()).toLowerCase(),
      );
      await factory.setImplementation(await factory.getAddress());
      expect(await factory.implementation()).to.be.eq(
        await factory.getAddress(),
      );
      await expect(ePool.upgradeImplementation())
        .to.emit(ePool, "Upgraded")
        .withArgs(await factory.getAddress());
    });

    it("can read implementation", async () => {
      const { pool, smartPoolAddress } = await setupTests();
      const implementationSlot =
        "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
      const implementation = await pool.getStorageAt(implementationSlot, 1);
      const encodedPack = solidityPacked(["uint256"], [smartPoolAddress]);
      expect(implementation).to.be.eq(encodedPack);
    });

    it("can read pool owner", async () => {
      const { pool, user1 } = await setupTests();
      // owner is stored in same slot as symbol
      const poolInitSlot =
        "0xe48b9bb119adfc3bccddcc581484cc6725fe8d292ebfcec7d67b1f93138d8bd8";
      const ownerSlot = BigInt(poolInitSlot) + BigInt(1);
      let owner = await pool.getStorageAt(ownerSlot, 1);
      owner = dataSlice(owner, 3, 23);
      expect(owner).to.be.eq((await pool.owner()).toLowerCase());
      expect(user1.address).to.be.eq(await pool.owner());
    });

    it("should read true unlocked boolean", async () => {
      const { pool } = await setupTests();
      const poolInitSlot =
        "0xe48b9bb119adfc3bccddcc581484cc6725fe8d292ebfcec7d67b1f93138d8bd8";
      // unlocked is compressed together with owner and symbol
      const poolUnlockedSlot = BigInt(poolInitSlot) + BigInt(1);
      let unlocked = await pool.getStorageAt(poolUnlockedSlot, 1);
      unlocked = dataSlice(unlocked, 2, 3);
      const encodedPack = solidityPacked(["bool"], [true]);
      expect(unlocked).to.be.eq(encodedPack);
    });

    // a string shorter than 32 bytes is saved in location left-aligned and length is stored at the end.
    it("can read pool data", async () => {
      const { pool } = await setupTests();
      const poolInitSlot =
        "0xe48b9bb119adfc3bccddcc581484cc6725fe8d292ebfcec7d67b1f93138d8bd8";
      const poolStruct = await pool.getStorageAt(poolInitSlot, 3);
      // name stored in slot 1 with name length appended at last byte, se if we encode we also must append hex string length.
      const name = dataSlice(poolStruct, 0, 32);
      // symbol is stored as bytes8 in order to be packed with other small units
      let symbol = encodeBytes32String("TEST");
      symbol = dataSlice(symbol, 0, 8);
      const owner = await pool.owner();
      // EVM tickly packs tickls symbol, decimals, owner, unlocked into one uint256 slot
      const encodedPack = solidityPacked(
        ["bytes32", "uint24", "address", "uint8", "bytes8", "uint256"],
        [name, 1, owner, 18, symbol, ZeroAddress],
      );
      expect(poolStruct).to.be.eq(encodedPack);
    });

    it("can read pool struct with different base token", async () => {
      const { factory, grgTokenAddress } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const newPoolAddress = (
        await factory.createPool.staticCall(
          "test pool GRG",
          "PDPG",
          grgTokenAddress,
        )
      )[0];
      await factory.createPool("test pool GRG", "PDPG", grgTokenAddress);
      const pool = await ethers.getContractAt("SmartPool", newPoolAddress);
      const poolInitSlot =
        "0xe48b9bb119adfc3bccddcc581484cc6725fe8d292ebfcec7d67b1f93138d8bd8";
      const poolStruct = await pool.getStorageAt(poolInitSlot, 3);
      // name stored in first struct slot with name length appended at last byte, when encoding we also must append length.
      const name = dataSlice(poolStruct, 0, 32);
      // symbol is stored as bytes8 in order to be packed with other small units
      let symbol = encodeBytes32String("PDPG");
      symbol = dataSlice(symbol, 0, 8);
      const owner = await pool.owner();
      // EVM tickly packs tickls symbol, decimals, owner, unlocked into one uint256 slot
      const encodedPack = solidityPacked(
        ["bytes32", "uint24", "address", "uint8", "bytes8", "uint256"],
        [name, 1, owner, 18, symbol, grgTokenAddress],
      );
      expect(poolStruct).to.be.eq(encodedPack);
    });

    it("can read pool parameters", async () => {
      const { pool, user1, user2 } = await setupTests();
      const poolParamsSlot = BigInt(
        "0xe3ed9e7d534645c345f2d15f0c405f8de0227b60eb37bbeb25b26db462415dec",
      );
      let poolParams = await pool.getStorageAt(poolParamsSlot, 2);
      // we are packing 5 elements, but EVM adds null uint16 to compress 4 elements in first slot
      let encodedPack = solidityPacked(
        ["uint16", "uint48", "uint16", "uint16", "uint160", "uint256"],
        [0, 0, 0, 0, ZeroAddress, ZeroAddress],
      );
      // we assert we are comparing same length null arrays first
      expect(poolParams).to.be.eq(encodedPack);
      await pool.changeMinPeriod(1234567);
      await pool.changeSpread(445);
      await pool.setTransactionFee(67);
      // fee collector must approve receiving fees
      await connect(pool, user2).setOperator(user1.address, true);
      await pool.changeFeeCollector(user2.address);
      await pool.setKycProvider(await pool.getAddress());
      poolParams = await pool.getStorageAt(poolParamsSlot, 2);
      // EVM tightly encodes struct as following, adding 2 null bytes to fill first uint256 slot
      encodedPack = solidityPacked(
        ["uint16", "uint160", "uint16", "uint16", "uint48", "uint256"],
        [0, user2.address, 67, 445, 1234567, await pool.getAddress()],
      );
      expect(poolParams).to.be.eq(encodedPack);
    });

    it("can read pool tokens struct", async () => {
      const { pool, user1, user2 } = await setupTests();
      const poolTokensSlot = BigInt(
        "0xf46fb7ff9ff9a406787c810524417c818e45ab2f1997f38c2555c845d23bb9f6",
      );
      let poolParams = await pool.getStorageAt(poolTokensSlot, 2);
      // unitary value null in pool storage until set, total supply null until first mint
      let encodedPack = solidityPacked(["uint256", "uint256"], [0, 0]);
      expect(poolParams).to.be.eq(encodedPack);
      await expect(
        pool.mint(user2.address, parseEther("10"), 0),
      ).to.be.revertedWithCustomError(pool, "InvalidOperator");
      await connect(pool, user2).setOperator(user1.address, true);
      let etherValue = parseEther("10");
      await pool.mint(user2.address, etherValue, 1, { value: etherValue });
      etherValue =
        etherValue -
        (etherValue * (await pool.getPoolParams()).spread) / 10000n;
      poolParams = await pool.getStorageAt(poolTokensSlot, 2);
      // total supply will be equal to the ether value deposited after spread deduction
      encodedPack = solidityPacked(
        ["uint256", "uint256"],
        [parseEther("1"), etherValue],
      );
      expect(poolParams).to.be.eq(encodedPack);
    });
  });

  describe("getStorageSlotsAt", async () => {
    it("can read beacon slot", async () => {
      const { factory, pool, authority } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const extension = await ethers.deployContract("EUpgrade", [
        await factory.getAddress(),
      ]);
      const ePool = await ethers.getContractAt(
        "EUpgrade",
        await pool.getAddress(),
      );
      await authority.setAdapter(await extension.getAddress(), true);
      // "2d6b3a6b": "getBeacon()"
      await authority.addMethod("0x2d6b3a6b", await extension.getAddress());
      const beacon = await ePool.getBeacon.staticCall();
      expect(beacon).to.be.eq(await factory.getAddress());
      // ""466f3dc3": "upgradeImplementation()"
      await authority.addMethod("0x466f3dc3", await extension.getAddress());
      await factory.setImplementation(await factory.getAddress());
      await ePool.upgradeImplementation();
      const implementationSlot =
        "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
      const { provider } = await network.getOrCreate();
      const implementation = (await provider.request({
        method: "eth_getStorageAt",
        params: [await pool.getAddress(), implementationSlot, "latest"],
      })) as string;
      const encodedPack = solidityPacked(["uint160"], [implementation]);
      expect(encodedPack).to.be.eq((await factory.getAddress()).toLowerCase());
    });

    it("can read owner", async () => {
      const { pool } = await setupTests();
      const poolInitSlot =
        "0xe48b9bb119adfc3bccddcc581484cc6725fe8d292ebfcec7d67b1f93138d8bd8";
      const ownerSlot = BigInt(poolInitSlot) + BigInt(1);
      let owner = await pool.getStorageSlotsAt([ownerSlot]);
      owner = dataSlice(owner, 3, 23);
      const encodedPack = solidityPacked(["address"], [await pool.owner()]);
      expect(owner).to.be.eq(encodedPack);
    });

    it("can read slots from different structs", async () => {
      const { factory, grgTokenAddress, smartPoolAddress } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const newPoolAddress = (
        await factory.createPool.staticCall(
          "test pool GRG",
          "PDPG",
          grgTokenAddress,
        )
      )[0];
      await factory.createPool("test pool GRG", "PDPG", grgTokenAddress);
      const pool = await ethers.getContractAt("SmartPool", newPoolAddress);
      const implementationSlot =
        "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
      const poolInitSlot =
        "0xe48b9bb119adfc3bccddcc581484cc6725fe8d292ebfcec7d67b1f93138d8bd8";
      const baseTokenSlot = BigInt(poolInitSlot) + BigInt(2);
      const returnString = await pool.getStorageSlotsAt([
        implementationSlot,
        baseTokenSlot,
      ]);
      const encodedPack = solidityPacked(
        ["uint256", "uint256"],
        [smartPoolAddress, (await pool.getPool()).baseToken],
      );
      expect(returnString).to.be.eq(encodedPack);
    });

    it("returns name", async () => {
      const { pool } = await setupTests();
      const poolInitSlot =
        "0xe48b9bb119adfc3bccddcc581484cc6725fe8d292ebfcec7d67b1f93138d8bd8";
      const nameSlot = BigInt(poolInitSlot) + BigInt(0);
      const name = await pool.getStorageSlotsAt([nameSlot]);
      // EVM stored string length at last byte if shorter than 31 bytes
      const nameLength = dataSlice(name, 31, 32);
      const length = getBytes(nameLength)[0] / 2;
      // each character is 2 bytes long
      let nameHex = dataSlice(name, 0, length);
      nameHex = toUtf8String(nameHex);
      expect(await pool.name()).to.be.eq(nameHex);
    });

    it("returns symbol", async () => {
      const { pool } = await setupTests();
      // EVM packs symbol with unlocked, owner, decimals
      const poolInitSlot =
        "0xe48b9bb119adfc3bccddcc581484cc6725fe8d292ebfcec7d67b1f93138d8bd8";
      const symbolSlot = BigInt(poolInitSlot) + BigInt(1);
      let symbol = await pool.getStorageSlotsAt([symbolSlot]);
      // symbol is bytes8, we only take the first 4 to eliminate padding.
      symbol = dataSlice(symbol, 24, 32);
      symbol = toUtf8String(symbol);
      // slot stores symbol as bytes8, which is returned with padding
      expect(symbol).to.be.eq("TEST\u0000\u0000\u0000\u0000");
      // in order to comparing storage symbol, we must get rid of padding
      const poolSymbol = await pool.symbol();
      expect(poolSymbol).to.be.eq("TEST");
    });

    it("can read selected struct data", async () => {
      const { factory } = await setupTests();
      const { ethers } = await network.getOrCreate();
      // we later want to check symbol length for 3-char symbol, creating new pool
      const newPoolAddress = (
        await factory.createPool.staticCall("my new pool", "PAL", ZeroAddress)
      )[0];
      await factory.createPool("my new pool", "PAL", ZeroAddress);
      const pool = await ethers.getContractAt("SmartPool", newPoolAddress);
      const poolInitSlot =
        "0xe48b9bb119adfc3bccddcc581484cc6725fe8d292ebfcec7d67b1f93138d8bd8";
      const nameSlot = BigInt(poolInitSlot) + BigInt(0);
      const symbolSlot = BigInt(poolInitSlot) + BigInt(1);
      const baseTokenSlot = BigInt(poolInitSlot) + BigInt(2);
      const poolParamsSlot = BigInt(
        "0xe3ed9e7d534645c345f2d15f0c405f8de0227b60eb37bbeb25b26db462415dec",
      );
      const kycProviderSlot = poolParamsSlot + BigInt(1);
      const poolTokensSlot = BigInt(
        "0xf46fb7ff9ff9a406787c810524417c818e45ab2f1997f38c2555c845d23bb9f6",
      );
      const totalSupplySlot = poolTokensSlot + BigInt(1);
      const returnString = await pool.getStorageSlotsAt([
        nameSlot,
        symbolSlot,
        baseTokenSlot,
        kycProviderSlot,
        totalSupplySlot,
      ]);
      const decodedData = new AbiCoder().decode(
        ["bytes32", "bytes32", "address", "address", "uint256"],
        returnString,
      );
      // TODO: following values are both null in current pool, must test with non-null values
      expect(decodedData[3]).to.be.eq((await pool.getPool()).baseToken);
      expect(decodedData[4]).to.be.eq(await pool.totalSupply());
      let name = decodedData[0];
      const nameLength = dataSlice(name, 31, 32);
      const length = getBytes(nameLength)[0] / 2;
      name = dataSlice(name, 0, length);
      name = toUtf8String(name);
      expect(name).to.be.eq("my new pool");
      expect(name).to.be.eq(await pool.name());
      let symbol = decodedData[1];
      symbol = dataSlice(symbol, 24, 32);
      // symbol is an 8-bytes element
      const poolSymbol = await pool.symbol();
      expect(poolSymbol).to.be.eq("PAL");
      // must add padding to string
      expect(toUtf8String(symbol)).to.be.eq(
        "PAL\u0000\u0000\u0000\u0000\u0000",
      );
    });
  });
});
