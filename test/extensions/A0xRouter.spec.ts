import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import { AddressZero } from "@ethersproject/constants";
import { Contract, BigNumber } from "ethers";

describe("A0xRouter", async () => {
  const [user1, user2] = waffle.provider.getWallets();

  // Feature ID for Taker Submitted Settler (matches the adapter constant)
  const SETTLER_TAKER_FEATURE = 2;

  // Settler.execute selector: execute((address,address,uint256),bytes[],bytes32)
  const SETTLER_EXECUTE_SELECTOR = "0x1fff991f";

  // AllowanceHolder.exec selector: exec(address,address,uint256,address,bytes)
  const EXEC_SELECTOR = "0x2213bc0b";

  const MAX_TICK_SPACING = 32767;

  const setupTests = deployments.createFixture(async ({ deployments }) => {
    await deployments.fixture("tests-setup");
    const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory");
    const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory");
    const AuthorityInstance = await deployments.get("Authority");
    const Authority = await hre.ethers.getContractFactory("Authority");
    const authority = Authority.attach(AuthorityInstance.address);
    const factory = Factory.attach(RigoblockPoolProxyFactory.address);

    // Create pool
    const { newPoolAddress } = await factory.callStatic.createPool("testpool", "TEST", AddressZero);
    await factory.createPool("testpool", "TEST", AddressZero);

    // Deploy mock contracts
    const MockAllowanceHolder = await ethers.getContractFactory("MockAllowanceHolder");
    const mockAllowanceHolder = await MockAllowanceHolder.deploy();

    const Mock0xDeployer = await ethers.getContractFactory("Mock0xDeployer");
    const mockDeployer = await Mock0xDeployer.deploy();

    const MockSettler = await ethers.getContractFactory("MockSettler");
    const mockSettler = await MockSettler.deploy();

    // Register settler in deployer
    await mockDeployer.setCurrentSettler(SETTLER_TAKER_FEATURE, mockSettler.address);

    // Deploy the A0xRouter adapter
    const A0xRouter = await ethers.getContractFactory("A0xRouter");
    const a0xRouter = await A0xRouter.deploy(mockAllowanceHolder.address, mockDeployer.address);

    // Register adapter in authority
    await authority.setAdapter(a0xRouter.address, true);
    await authority.addMethod(EXEC_SELECTOR, a0xRouter.address);

    // Deploy mock ERC20 tokens for testing
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const sellToken = await MockERC20.deploy("Sell Token", "SELL", 18);
    const buyToken = await MockERC20.deploy("Buy Token", "BUY", 18);

    // Setup oracle for buyToken price feed
    // The hasPriceFeed function in EOracle builds a PoolKey with (address(0), buyToken, fee=0, tickSpacing=MAX, hooks=oracle)
    // and checks if the oracle has observations for that pool. We need to initialize observations.
    const HookInstance = await deployments.get("MockOracle");
    const Hook = await hre.ethers.getContractFactory("MockOracle");
    const oracle = Hook.attach(HookInstance.address);

    const Pool = await hre.ethers.getContractFactory("SmartPool");
    const pool = Pool.attach(newPoolAddress);

    return {
      pool,
      newPoolAddress,
      a0xRouter,
      mockAllowanceHolder,
      mockDeployer,
      mockSettler,
      sellToken,
      buyToken,
      authority,
      oracle,
    };
  });

  /// @dev Helper: initialize oracle observations for a token so hasPriceFeed returns true
  async function initializePriceFeed(oracle: Contract, tokenAddress: string) {
    const poolKey = {
      currency0: AddressZero,
      currency1: tokenAddress,
      fee: 0,
      tickSpacing: MAX_TICK_SPACING,
      hooks: oracle.address,
    };
    await oracle.initializeObservations(poolKey);
  }

  /// @dev Helper: encode AllowedSlippage into Settler.execute calldata
  function encodeSettlerExecute(
    recipient: string,
    buyToken: string,
    minAmountOut: BigNumber,
    actions: string[] = [],
    zid: string = ethers.constants.HashZero
  ): string {
    const iface = new ethers.utils.Interface([
      "function execute((address,address,uint256),bytes[],bytes32)",
    ]);
    return iface.encodeFunctionData("execute", [
      [recipient, buyToken, minAmountOut],
      actions,
      zid,
    ]);
  }

  /// @dev Helper: encode full AllowanceHolder.exec call via the pool
  function encodeExecCall(
    operator: string,
    token: string,
    amount: BigNumber,
    target: string,
    data: string
  ): string {
    const iface = new ethers.utils.Interface([
      "function exec(address,address,uint256,address,bytes) returns (bytes)",
    ]);
    return iface.encodeFunctionData("exec", [operator, token, amount, target, data]);
  }

  describe("exec", async () => {
    it("should execute a valid 0x swap", async () => {
      const { pool, mockAllowanceHolder, mockSettler, sellToken, buyToken, oracle } = await setupTests();

      // Setup: fund pool with sell tokens
      const sellAmount = ethers.utils.parseEther("100");
      const buyAmount = ethers.utils.parseEther("200");
      await sellToken.mint(pool.address, sellAmount);

      // Setup: fund settler with buy tokens (for the mock swap)
      await buyToken.mint(mockSettler.address, buyAmount);

      // Setup: register buyToken price feed in oracle
      await initializePriceFeed(oracle, buyToken.address);

      // Encode Settler.execute calldata
      const settlerData = encodeSettlerExecute(
        pool.address,
        buyToken.address,
        buyAmount,
        [], // no actions needed for mock
        ethers.constants.HashZero
      );

      // Encode AllowanceHolder.exec calldata
      const execData = encodeExecCall(
        mockSettler.address,
        sellToken.address,
        sellAmount,
        mockSettler.address,
        settlerData
      );

      // Send transaction to pool (routes via fallback → Authority → A0xRouter)
      // First mint some pool tokens so pool has funds
      const etherAmount = ethers.utils.parseEther("1");
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount });

      await expect(user1.sendTransaction({ to: pool.address, value: 0, data: execData })).to.not.be
        .reverted;

      // Verify AllowanceHolder received the call with correct parameters
      expect(await mockAllowanceHolder.lastOperator()).to.equal(mockSettler.address);
      expect(await mockAllowanceHolder.lastToken()).to.equal(sellToken.address);
      expect(await mockAllowanceHolder.lastAmount()).to.equal(sellAmount);
      expect(await mockAllowanceHolder.lastTarget()).to.equal(mockSettler.address);
    });

    it("should revert if target is not a genuine settler", async () => {
      const { pool, mockSettler, sellToken, buyToken, oracle } = await setupTests();
      const fakeSettler = user2.address;

      await initializePriceFeed(oracle, buyToken.address);

      const settlerData = encodeSettlerExecute(
        pool.address,
        buyToken.address,
        ethers.utils.parseEther("1"),
      );

      const execData = encodeExecCall(
        fakeSettler,
        sellToken.address,
        ethers.utils.parseEther("1"),
        fakeSettler, // target is not registered in deployer
        settlerData
      );

      const etherAmount = ethers.utils.parseEther("1");
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount });

      await expect(
        user1.sendTransaction({ to: pool.address, value: 0, data: execData })
      ).to.be.reverted;
    });

    it("should accept previous settler during dwell time", async () => {
      const { pool, mockAllowanceHolder, mockDeployer, sellToken, buyToken, oracle } = await setupTests();

      // Deploy a new mock settler to be the "previous" one
      const MockSettler = await ethers.getContractFactory("MockSettler");
      const previousSettler = await MockSettler.deploy();

      // Set up deployer: current settler is different, previous is our target
      const newSettler = await MockSettler.deploy();
      await mockDeployer.setCurrentSettler(SETTLER_TAKER_FEATURE, newSettler.address);
      await mockDeployer.setPreviousSettler(SETTLER_TAKER_FEATURE, previousSettler.address);

      await initializePriceFeed(oracle, buyToken.address);
      await buyToken.mint(previousSettler.address, ethers.utils.parseEther("100"));

      const sellAmount = ethers.utils.parseEther("10");
      await sellToken.mint(pool.address, sellAmount);

      const settlerData = encodeSettlerExecute(
        pool.address,
        buyToken.address,
        ethers.utils.parseEther("1"),
      );

      const execData = encodeExecCall(
        previousSettler.address,
        sellToken.address,
        sellAmount,
        previousSettler.address, // previous settler as target
        settlerData
      );

      const etherAmount = ethers.utils.parseEther("1");
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount });

      await expect(user1.sendTransaction({ to: pool.address, value: 0, data: execData })).to.not.be
        .reverted;
    });

    it("should revert if recipient is not the pool", async () => {
      const { pool, mockSettler, sellToken, buyToken, oracle } = await setupTests();

      await initializePriceFeed(oracle, buyToken.address);

      // Set recipient to user2 (not the pool)
      const settlerData = encodeSettlerExecute(
        user2.address, // wrong recipient
        buyToken.address,
        ethers.utils.parseEther("1"),
      );

      const execData = encodeExecCall(
        mockSettler.address,
        sellToken.address,
        ethers.utils.parseEther("1"),
        mockSettler.address,
        settlerData
      );

      const etherAmount = ethers.utils.parseEther("1");
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount });

      await expect(
        user1.sendTransaction({ to: pool.address, value: 0, data: execData })
      ).to.be.revertedWith("RecipientNotSmartPool()");
    });

    it("should revert if buyToken has no price feed", async () => {
      const { pool, mockSettler, sellToken, buyToken } = await setupTests();

      // Don't register buyToken price feed
      const settlerData = encodeSettlerExecute(
        pool.address,
        buyToken.address,
        ethers.utils.parseEther("1"),
      );

      const execData = encodeExecCall(
        mockSettler.address,
        sellToken.address,
        ethers.utils.parseEther("1"),
        mockSettler.address,
        settlerData
      );

      const etherAmount = ethers.utils.parseEther("1");
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount });

      await expect(
        user1.sendTransaction({ to: pool.address, value: 0, data: execData })
      ).to.be.reverted; // TokenPriceFeedDoesNotExist
    });

    it("should revert on direct call (not delegatecall)", async () => {
      const { a0xRouter, mockSettler, sellToken, buyToken } = await setupTests();

      const settlerData = encodeSettlerExecute(
        user1.address,
        buyToken.address,
        ethers.utils.parseEther("1"),
      );

      await expect(
        a0xRouter.exec(
          mockSettler.address,
          sellToken.address,
          ethers.utils.parseEther("1"),
          mockSettler.address,
          settlerData
        )
      ).to.be.revertedWith("DirectCallNotAllowed()");
    });

    it("should revert if settler function selector is wrong", async () => {
      const { pool, mockSettler, sellToken, buyToken, oracle } = await setupTests();

      await initializePriceFeed(oracle, buyToken.address);

      // Encode with a wrong selector (using executeWithPermit or random selector)
      const wrongData = "0xdeadbeef" + ethers.utils.defaultAbiCoder.encode(
        ["address", "address", "uint256"],
        [pool.address, buyToken.address, ethers.utils.parseEther("1")]
      ).slice(2);

      const execData = encodeExecCall(
        mockSettler.address,
        sellToken.address,
        ethers.utils.parseEther("1"),
        mockSettler.address,
        wrongData
      );

      const etherAmount = ethers.utils.parseEther("1");
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount });

      await expect(
        user1.sendTransaction({ to: pool.address, value: 0, data: execData })
      ).to.be.revertedWith("UnsupportedSettlerFunction()");
    });

    it("should revert if settler calldata too short", async () => {
      const { pool, mockSettler, sellToken, oracle } = await setupTests();

      // Calldata shorter than 100 bytes (just a selector + partial data)
      const shortData = SETTLER_EXECUTE_SELECTOR + "0000000000000000";

      const execData = encodeExecCall(
        mockSettler.address,
        sellToken.address,
        ethers.utils.parseEther("1"),
        mockSettler.address,
        shortData
      );

      const etherAmount = ethers.utils.parseEther("1");
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount });

      await expect(
        user1.sendTransaction({ to: pool.address, value: 0, data: execData })
      ).to.be.revertedWith("InvalidSettlerCalldata()");
    });

    it("should revert if feature is paused", async () => {
      const { pool, mockDeployer, mockSettler, sellToken, buyToken, oracle } = await setupTests();

      // Pause the feature
      await mockDeployer.setPaused(SETTLER_TAKER_FEATURE, true);

      await initializePriceFeed(oracle, buyToken.address);

      const settlerData = encodeSettlerExecute(
        pool.address,
        buyToken.address,
        ethers.utils.parseEther("1"),
      );

      const execData = encodeExecCall(
        mockSettler.address,
        sellToken.address,
        ethers.utils.parseEther("1"),
        mockSettler.address,
        settlerData
      );

      const etherAmount = ethers.utils.parseEther("1");
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount });

      // Should revert because ownerOf reverts when paused
      await expect(
        user1.sendTransaction({ to: pool.address, value: 0, data: execData })
      ).to.be.reverted;
    });

    it("should handle AllowanceHolder revert with reason", async () => {
      const { pool, mockAllowanceHolder, mockSettler, sellToken, buyToken, oracle } = await setupTests();

      await initializePriceFeed(oracle, buyToken.address);

      // Set mock to revert with reason
      await mockAllowanceHolder.setMockMode(2, "MockRevertReason"); // RevertWithReason

      const settlerData = encodeSettlerExecute(
        pool.address,
        buyToken.address,
        ethers.utils.parseEther("1"),
      );

      const execData = encodeExecCall(
        mockSettler.address,
        sellToken.address,
        ethers.utils.parseEther("1"),
        mockSettler.address,
        settlerData
      );

      const etherAmount = ethers.utils.parseEther("1");
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount });

      await expect(
        user1.sendTransaction({ to: pool.address, value: 0, data: execData })
      ).to.be.revertedWith("MockRevertReason");
    });

    it("should handle AllowanceHolder revert without reason", async () => {
      const { pool, mockAllowanceHolder, mockSettler, sellToken, buyToken, oracle } = await setupTests();

      await initializePriceFeed(oracle, buyToken.address);

      // Set mock to revert without reason
      await mockAllowanceHolder.setMockMode(1, ""); // Revert

      const settlerData = encodeSettlerExecute(
        pool.address,
        buyToken.address,
        ethers.utils.parseEther("1"),
      );

      const execData = encodeExecCall(
        mockSettler.address,
        sellToken.address,
        ethers.utils.parseEther("1"),
        mockSettler.address,
        settlerData
      );

      const etherAmount = ethers.utils.parseEther("1");
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount });

      await expect(
        user1.sendTransaction({ to: pool.address, value: 0, data: execData })
      ).to.be.reverted;
    });

    it("should not allow non-owner to call exec", async () => {
      const { pool, mockSettler, sellToken, buyToken, oracle } = await setupTests();

      await initializePriceFeed(oracle, buyToken.address);

      const settlerData = encodeSettlerExecute(
        pool.address,
        buyToken.address,
        ethers.utils.parseEther("1"),
      );

      const execData = encodeExecCall(
        mockSettler.address,
        sellToken.address,
        ethers.utils.parseEther("1"),
        mockSettler.address,
        settlerData
      );

      // user2 is not the pool owner, should revert
      await expect(
        user2.sendTransaction({ to: pool.address, value: 0, data: execData })
      ).to.be.reverted;
    });

    it("should approve exact amount before exec and reset to 1 after (per-call)", async () => {
      const { pool, mockAllowanceHolder, mockSettler, sellToken, buyToken, oracle } = await setupTests();

      const sellAmount = ethers.utils.parseEther("100");
      await sellToken.mint(pool.address, sellAmount);
      await buyToken.mint(mockSettler.address, ethers.utils.parseEther("200"));
      await initializePriceFeed(oracle, buyToken.address);

      const settlerData = encodeSettlerExecute(
        pool.address,
        buyToken.address,
        ethers.utils.parseEther("1"),
      );

      const execData = encodeExecCall(
        mockSettler.address,
        sellToken.address,
        sellAmount,
        mockSettler.address,
        settlerData
      );

      const etherAmount = ethers.utils.parseEther("1");
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount });

      // Before exec, allowance should be 0
      const allowanceBefore = await sellToken.allowance(pool.address, mockAllowanceHolder.address);
      expect(allowanceBefore).to.equal(0);

      await user1.sendTransaction({ to: pool.address, value: 0, data: execData });

      // After exec, allowance should be 1 (gas optimization: keep storage slot warm,
      // so next swap pays 5000 gas for non-zero→non-zero instead of 20000 for zero→non-zero)
      const allowanceAfter = await sellToken.allowance(pool.address, mockAllowanceHolder.address);
      expect(allowanceAfter).to.equal(1);
    });

    it("should add buyToken to active tokens", async () => {
      const { pool, mockAllowanceHolder, mockSettler, sellToken, buyToken, oracle } = await setupTests();

      const sellAmount = ethers.utils.parseEther("100");
      await sellToken.mint(pool.address, sellAmount);
      await buyToken.mint(mockSettler.address, ethers.utils.parseEther("200"));
      await initializePriceFeed(oracle, buyToken.address);

      const settlerData = encodeSettlerExecute(
        pool.address,
        buyToken.address,
        ethers.utils.parseEther("1"),
      );

      const execData = encodeExecCall(
        mockSettler.address,
        sellToken.address,
        sellAmount,
        mockSettler.address,
        settlerData
      );

      const etherAmount = ethers.utils.parseEther("1");
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount });

      await expect(user1.sendTransaction({ to: pool.address, value: 0, data: execData }))
        .to.emit(pool, "TokenStatusChanged")
        .withArgs(buyToken.address, true);

      const activeTokens = (await pool.getActiveTokens()).activeTokens;
      expect(activeTokens).to.include(buyToken.address);
    });

    it("should return the required version", async () => {
      const { a0xRouter } = await setupTests();
      expect(await a0xRouter.requiredVersion()).to.equal("4.0.0");
    });
  });
});
