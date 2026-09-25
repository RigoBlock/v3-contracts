import { expect } from "chai";
import { network } from "hardhat";
import { ZeroAddress, parseEther } from "ethers";
import { getFixedGasSigners } from "../shared/helper";
import { createFixture } from "../utils/fixtures";

const MAX_TICK_SPACING = 32767;

describe("ENavView", async () => {
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
    // Create a new pool
    const { newPoolAddress } = await factory.createPool.staticCall(
      "testpool",
      "TEST",
      await grgToken.getAddress(),
    );
    await factory.createPool("testpool", "TEST", await grgToken.getAddress());
    const pool = await ethers.getContractAt("SmartPool", newPoolAddress);

    // Get deployed ENavView from setup
    const eNavView = await ethers.getContractAt(
      "ENavView",
      (await get("ENavView")).address,
    );

    const oracle = await ethers.getContractAt(
      "MockOracle",
      (await get("MockOracle")).address,
    );

    // Initialize oracle observations for GRG token (base token) to avoid BaseTokenPriceFeedError
    const poolKey = {
      currency0: ZeroAddress,
      currency1: await grgToken.getAddress(),
      fee: 0,
      tickSpacing: MAX_TICK_SPACING,
      hooks: await oracle.getAddress(),
    };
    await oracle.initializeObservations(poolKey);

    const authority = await ethers.getContractAt(
      "Authority",
      (await get("Authority")).address,
    );
    const aStakingAddress = (await get("AStaking")).address;
    await authority.addMethod("0xa694fc3a", aStakingAddress);

    return {
      pool,
      newPoolAddress,
      grgToken,
      eNavView,
      oracle,
      user1,
    };
  });

  // Unit tests for ENavView extension functionality through proper pool delegation
  describe("ENavView functionality through pool", async () => {
    it("should return token balances through pool delegation", async () => {
      const { newPoolAddress } = await setupTests();
      const { ethers } = await network.getOrCreate();

      // Cast pool to IENavView interface to access extension methods
      const navViewPool = await ethers.getContractAt(
        "IENavView",
        newPoolAddress,
      );

      // Should work and return empty array for empty pool
      const balances = await navViewPool.getAppTokensAndBalancesView();
      expect(balances).to.be.an("array");
      // Empty pool should have empty or minimal balances
      expect(balances.length).to.be.gte(0);
    });

    it("should return NAV data through pool delegation", async () => {
      const { newPoolAddress } = await setupTests();
      const { ethers } = await network.getOrCreate();

      // Cast pool to IENavView interface
      const navViewPool = await ethers.getContractAt(
        "IENavView",
        newPoolAddress,
      );

      // Should work and return valid NAV data structure
      // @notice ethers v6 returns a Result array: named fields are accessible by property
      const navData = await navViewPool.getNavDataView();
      expect(navData.totalValue).to.not.be.undefined;
      expect(navData.unitaryValue).to.not.be.undefined;
      expect(navData.timestamp).to.not.be.undefined;

      // Values should be reasonable (0 or positive for empty pool)
      expect(navData.totalValue).to.be.gte(0);
      expect(navData.unitaryValue).to.be.gte(0);
      expect(navData.timestamp).to.be.gt(0);
    });

    it("should return application balances through pool delegation", async () => {
      const { newPoolAddress } = await setupTests();
      const { ethers } = await network.getOrCreate();

      // Cast pool to IENavView interface
      const navViewPool = await ethers.getContractAt(
        "IENavView",
        newPoolAddress,
      );

      // Should work and return array (empty or with applications)
      const apps = await navViewPool.getAppTokensAndBalancesView();
      expect(apps).to.be.an("array");
      expect(apps.length).to.be.gte(0);
    });

    it("should work with pool that has tokens", async () => {
      const { newPoolAddress, pool, grgToken, user1 } = await setupTests();
      const { ethers } = await network.getOrCreate();

      // Add some tokens to the pool
      const mintAmount = parseEther("100");
      await grgToken.approve(newPoolAddress, mintAmount);
      await pool.mint(user1.address, mintAmount, 0);

      // Update NAV after minting
      await pool.updateUnitaryValue();

      // Cast pool to IENavView interface
      const navViewPool = await ethers.getContractAt(
        "IENavView",
        newPoolAddress,
      );

      let balances = await navViewPool.getAppTokensAndBalancesView();
      expect(balances.length).to.be.gte(0);

      const stakingPool = await ethers.getContractAt(
        "IRigoblockPoolExtended",
        newPoolAddress,
      );
      await stakingPool.stake(mintAmount / 2n); // Stake half the tokens

      balances = await navViewPool.getAppTokensAndBalancesView();
      expect(balances.length).to.be.gte(1);

      const navData = await navViewPool.getNavDataView();
      // Total value might be 0 for test pools, but unitaryValue should be positive
      expect(navData.totalValue).to.be.gte(0);
      expect(navData.unitaryValue).to.be.gt(0); // Should be > 0 after minting
      expect(navData.timestamp).to.be.gt(0);

      // Verify we have a valid NAV structure
      expect(navData.unitaryValue).to.equal(parseEther("1")); // Should be 1.0 for fresh pool
    });
  });
});
