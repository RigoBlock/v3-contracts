import { expect } from "chai";
import { network } from "hardhat";
import { ZeroAddress, parseEther } from "ethers";
import { getFixedGasSigners } from "../shared/helper";
import { createFixture } from "../utils/fixtures";

describe("AUniswap", async () => {
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
    // we never call uniswap adapter directly, therefore do not attach to ABI
    const aUniswap = (await get("AUniswap")).address;
    await authority.setAdapter(aUniswap, true);
    // "49404b7c": "unwrapWETH9(uint256,address)",
    // "1c58db4f": "wrapETH(uint256)"
    await authority.addMethod("0x49404b7c", aUniswap);
    await authority.addMethod("0x1c58db4f", aUniswap);
    const { newPoolAddress } = await factory.createPool.staticCall(
      "testpool",
      "TEST",
      ZeroAddress,
    );
    await factory.createPool("testpool", "TEST", ZeroAddress);
    return {
      aUniswap,
      authority,
      newPoolAddress,
      user1,
      user2,
    };
  });

  // TODO: uncomment once failing test in coverage is fixed (tests pass in normal test run). Error happens after bridge code changes,
  // to (apparently unrelated) different files. Possibly related to hardhat-coverage plugin - or to slow compilation on coverage - requires improving tests execution.
  describe("unwrapWETH9 @skip-on-coverage", async () => {
    it("should call WETH contract", async () => {
      const { aUniswap, authority, newPoolAddress, user1, user2 } =
        await setupTests();
      const { ethers } = await network.getOrCreate();
      const pool = await ethers.getContractAt("AUniswap", newPoolAddress);
      const amount = parseEther("100");
      await user1.sendTransaction({ to: newPoolAddress, value: amount });
      await pool.wrapETH(amount);
      expect(await ethers.provider.getBalance(newPoolAddress)).to.be.eq(0n);
      const rogueRecipient = user2.address;
      const rogueBalance = await ethers.provider.getBalance(rogueRecipient);
      const unwrapAmount = 50;
      let encodedUnwrapData = pool.interface.encodeFunctionData(
        "unwrapWETH9(uint256,address)",
        [unwrapAmount, rogueRecipient],
      );
      await expect(
        authority.addMethod("0x49404b7c", aUniswap),
      ).to.be.revertedWith("SELECTOR_EXISTS_ERROR");
      await user1.sendTransaction({
        to: newPoolAddress,
        value: 0,
        data: encodedUnwrapData,
      });

      // unwrapped token returned to pool regardless recipient input
      expect(await ethers.provider.getBalance(rogueRecipient)).to.be.eq(
        rogueBalance,
      );
      expect(await ethers.provider.getBalance(newPoolAddress)).to.be.eq(
        BigInt(unwrapAmount),
      );
      encodedUnwrapData = pool.interface.encodeFunctionData(
        "unwrapWETH9(uint256)",
        [50],
      );
      await authority.addMethod("0x49616997", aUniswap);
      await user1.sendTransaction({
        to: newPoolAddress,
        value: 0,
        data: encodedUnwrapData,
      });
    });
  });
});
