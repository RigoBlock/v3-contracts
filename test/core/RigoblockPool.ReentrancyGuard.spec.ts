import { expect } from "chai";
import { network } from "hardhat";
import { ZeroAddress, parseEther } from "ethers";
import { deployContract } from "../utils/utils";
import { getFixedGasSigners } from "../shared/helper";
import { createFixture } from "../utils/fixtures";

describe("ReentrancyGuard", async () => {
  const MAX_TICK_SPACING = 32767;

  const setupTests = createFixture(["tests-setup"], async ({ get }) => {
    const { ethers } = await network.getOrCreate();
    const factory = await ethers.getContractAt(
      "RigoblockPoolProxyFactory",
      (await get("RigoblockPoolProxyFactory")).address,
    );
    const oracle = await ethers.getContractAt(
      "MockOracle",
      (await get("MockOracle")).address,
    );
    return {
      factory,
      oracle,
    };
  });

  describe("nonReentrant", async () => {
    // The following test produces an effective reentrancy attack, however because the transaction is reverted with error
    // "TokenTransferFromFailed" when the pool makes a low-level call to the rogue token, we cannot return the
    // expected error "REENTRANCY_ILLEGAL"
    it("should fail when trying to mint", async () => {
      const [user1] = await getFixedGasSigners();
      const { factory, oracle } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const source = `
            contract RogueToken {
                uint256 public totalSupply = 1e24;
                uint8 public decimals = 18;
                address private reentrancyAttack;
                mapping(address => uint256) balances;
                function init(address _reentrancyAttack) public {
                    balances[msg.sender] = totalSupply;
                    reentrancyAttack = _reentrancyAttack;
                }
                function transfer(address to, uint256 amount) public returns (bool success) {
                    balances[to] += amount;
                    balances[msg.sender] -= amount;
                    return true;
                }
                function transferFrom(address from,address to,uint256 amount) public returns (bool success) {
                    balances[to] += amount;
                    balances[from] -= amount;
                    (, bytes memory data) = reentrancyAttack.call(abi.encodeWithSelector(0x1e832ae8));
                    if (data.length != 0) {
                        revert(string(data));
                    }
                    return true;
                }
                function balanceOf(address _who) external view returns (uint256) {
                    return balances[_who];
                }
            }`;
      const rogueToken = await deployContract(user1 as any, source);
      const newPoolAddress = (
        await factory.createPool.staticCall(
          "testpool",
          "TEST",
          await rogueToken.getAddress(),
        )
      )[0];
      await factory.createPool(
        "testpool",
        "TEST",
        await rogueToken.getAddress(),
      );
      const pool = await ethers.getContractAt("SmartPool", newPoolAddress);
      const testReentrancyAttack = await ethers.deployContract(
        "TestReentrancyAttack",
        [newPoolAddress],
      );
      await rogueToken.init(await testReentrancyAttack.getAddress());
      const tokenAmount = parseEther("100");
      await rogueToken.transfer(
        await testReentrancyAttack.getAddress(),
        tokenAmount,
      );
      const poolKey = {
        currency0: ZeroAddress,
        currency1: await rogueToken.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(poolKey);
      await expect(
        testReentrancyAttack.mintPool(),
      ).to.be.revertedWithCustomError(pool, "TokenTransferFromFailed");
      expect(await testReentrancyAttack.count()).to.be.eq(0n);
      await testReentrancyAttack.setMaxCount(1);
      await testReentrancyAttack.mintPool();
      expect(await testReentrancyAttack.count()).to.be.eq(2n);
      const etherAmount = parseEther("10");
      const spread = (await pool.getPoolParams()).spread;
      const expectedMintedAmount =
        etherAmount - (etherAmount * spread) / 10000n;
      expect(
        await pool.balanceOf(await testReentrancyAttack.getAddress()),
      ).to.be.eq(expectedMintedAmount);
      expect(await rogueToken.balanceOf(await pool.getAddress())).to.be.eq(
        expectedMintedAmount,
      );
    });
  });
});
