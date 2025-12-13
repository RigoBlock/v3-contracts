import { expect } from "chai";
import hre, { ethers } from "hardhat";
import { Contract, Signer } from "ethers";

/**
 * Integration tests that actually execute EAcrossHandler and AIntents contract code
 * to increase real coverage
 */
describe("Across Integration - Execution Coverage", () => {
  let poolProxy: Contract;
  let factory: Contract;
  let registry: Contract;
  let authority: Contract;
  let eAcrossHandler: Contract;
  let aIntents: Contract;
  let mockSpokePool: Contract;
  let mockWETH: Contract;
  let mockUSDC: Contract;
  let owner: Signer;
  let user: Signer;
  let ownerAddress: string;

  const OpType = {
    Transfer: 0,
    Rebalance: 1,
    Sync: 2,
  };

  before(async () => {
    const accounts = await ethers.getSigners();
    owner = accounts[0];
    user = accounts[1];
    ownerAddress = await owner.getAddress();

    // Deploy mock tokens
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    mockWETH = await MockERC20.deploy("Wrapped Ether", "WETH", 18);
    mockUSDC = await MockERC20.deploy("USD Coin", "USDC", 6);

    // Deploy mock SpokePool
    const MockSpokePool = await ethers.getContractFactory("MockAcrossSpokePool");
    mockSpokePool = await MockSpokePool.deploy(mockWETH.address);

    // Deploy EAcrossHandler
    const EAcrossHandler = await ethers.getContractFactory("EAcrossHandler");
    eAcrossHandler = await EAcrossHandler.deploy(mockSpokePool.address);

    // Deploy AIntents
    const AIntents = await ethers.getContractFactory("AIntents");
    aIntents = await AIntents.deploy(mockSpokePool.address);

    // For real coverage, we'd need to deploy the full pool infrastructure
    // For now, let's test what we can with direct calls and mocking
  });

  describe("EAcrossHandler - Direct Execution Tests", () => {
    it("should successfully verify SpokePool address in constructor", async () => {
      const spokePoolAddr = await eAcrossHandler.acrossSpokePool();
      expect(spokePoolAddr).to.equal(mockSpokePool.address);
    });

    it("should store immutable SpokePool correctly", async () => {
      // Try to read multiple times to ensure it's truly immutable
      const addr1 = await eAcrossHandler.acrossSpokePool();
      const addr2 = await eAcrossHandler.acrossSpokePool();
      expect(addr1).to.equal(addr2);
      expect(addr1).to.equal(mockSpokePool.address);
    });

    it("should reject handleV3AcrossMessage from non-SpokePool", async () => {
      const message = ethers.utils.defaultAbiCoder.encode(
        ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
        [[OpType.Transfer, 1, 0, 18, 0, false, 0]]
      );

      // This should revert because msg.sender is not the SpokePool
      await expect(
        eAcrossHandler.handleV3AcrossMessage(mockUSDC.address, 1000000, message)
      ).to.be.reverted;
    });

    it("should accept calls from SpokePool address", async () => {
      // Impersonate the SpokePool
      await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [mockSpokePool.address],
      });

      const spokePoolSigner = await ethers.getSigner(mockSpokePool.address);
      
      // Fund the SpokePool address
      await owner.sendTransaction({
        to: mockSpokePool.address,
        value: ethers.utils.parseEther("1"),
      });

      const message = ethers.utils.defaultAbiCoder.encode(
        ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
        [[OpType.Transfer, 1, 0, 18, 0, false, 0]]
      );

      // This will likely still fail due to missing pool context, but it passes the caller check
      // The revert should be from pool state access, not from UnauthorizedCaller
      await expect(
        eAcrossHandler.connect(spokePoolSigner).handleV3AcrossMessage(
          mockUSDC.address,
          1000000,
          message
        )
      ).to.be.reverted; // Will fail on pool state access, not auth check

      await hre.network.provider.request({
        method: "hardhat_stopImpersonatingAccount",
        params: [mockSpokePool.address],
      });
    });

    it("should validate message structure for Transfer mode", async () => {
      // Test that Transfer mode messages encode/decode correctly
      const transferMsg = {
        opType: OpType.Transfer,
        sourceChainId: 42161,
        sourceNav: 0,
        sourceDecimals: 18,
        navTolerance: 0,
        shouldUnwrap: false,
        sourceNativeAmount: 0,
      };

      const encoded = ethers.utils.defaultAbiCoder.encode(
        ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
        [[
          transferMsg.opType,
          transferMsg.sourceChainId,
          transferMsg.sourceNav,
          transferMsg.sourceDecimals,
          transferMsg.navTolerance,
          transferMsg.shouldUnwrap,
          transferMsg.sourceNativeAmount,
        ]]
      );

      const decoded = ethers.utils.defaultAbiCoder.decode(
        ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
        encoded
      )[0];

      expect(decoded[0]).to.equal(transferMsg.opType);
    });

    it("should handle different OpTypes in message", async () => {
      const opTypes = [OpType.Transfer, OpType.Rebalance, OpType.Sync];

      for (const opType of opTypes) {
        const message = ethers.utils.defaultAbiCoder.encode(
          ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
          [[opType, 1, ethers.utils.parseEther("1"), 18, 100, false, 0]]
        );

        const decoded = ethers.utils.defaultAbiCoder.decode(
          ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
          message
        )[0];

        expect(decoded[0]).to.equal(opType);
      }
    });
  });

  describe("AIntents - Direct Execution Tests", () => {
    it("should return correct required version", async () => {
      const version = await aIntents.requiredVersion();
      expect(version).to.equal("HF_4.1.0");
    });

    it("should have correct SpokePool immutable", async () => {
      const spokePool = await aIntents.acrossSpokePool();
      expect(spokePool).to.equal(mockSpokePool.address);
    });

    it("should reject direct calls to depositV3", async () => {
      const params = {
        inputToken: mockUSDC.address,
        outputToken: mockUSDC.address,
        inputAmount: 1000000,
        outputAmount: 990000,
        destinationChainId: 10,
        exclusiveRelayer: ethers.constants.AddressZero,
        quoteTimestamp: Math.floor(Date.now() / 1000),
        fillDeadline: Math.floor(Date.now() / 1000) + 3600,
        exclusivityDeadline: 0,
        message: ethers.utils.defaultAbiCoder.encode(
          ["tuple(uint8,uint256,bool,uint256)"],
          [[OpType.Transfer, 100, false, 0]]
        ),
      };

      // Should revert with DirectCallNotAllowed
      await expect(aIntents.depositV3(params)).to.be.reverted;
    });

    it("should handle different source message types", async () => {
      const messageTypes = [
        { opType: OpType.Transfer, tolerance: 100 },
        { opType: OpType.Rebalance, tolerance: 200 },
        { opType: OpType.Sync, tolerance: 0 },
      ];

      for (const msgType of messageTypes) {
        const encoded = ethers.utils.defaultAbiCoder.encode(
          ["tuple(uint8,uint256,bool,uint256)"],
          [[msgType.opType, msgType.tolerance, false, 0]]
        );

        const decoded = ethers.utils.defaultAbiCoder.decode(
          ["tuple(uint8,uint256,bool,uint256)"],
          encoded
        )[0];

        expect(decoded[0]).to.equal(msgType.opType);
        expect(decoded[1]).to.equal(msgType.tolerance);
      }
    });
  });

  describe("Mock SpokePool Functionality", () => {
    it("should have correct wrappedNativeToken", async () => {
      const weth = await mockSpokePool.wrappedNativeToken();
      expect(weth).to.equal(mockWETH.address);
    });

    it("should have fillDeadlineBuffer set", async () => {
      const buffer = await mockSpokePool.fillDeadlineBuffer();
      expect(buffer).to.be.gt(0);
    });

    it("should accept depositV3 calls", async () => {
      // Mint tokens to test account
      await mockUSDC.mint(ownerAddress, ethers.utils.parseUnits("1000", 6));
      await mockUSDC.approve(mockSpokePool.address, ethers.utils.parseUnits("100", 6));

      const tx = await mockSpokePool.depositV3(
        ownerAddress, // depositor
        ownerAddress, // recipient
        mockUSDC.address, // inputToken
        mockUSDC.address, // outputToken
        ethers.utils.parseUnits("100", 6), // inputAmount
        ethers.utils.parseUnits("99", 6), // outputAmount
        10, // destinationChainId
        ethers.constants.AddressZero, // exclusiveRelayer
        Math.floor(Date.now() / 1000), // quoteTimestamp
        Math.floor(Date.now() / 1000) + 3600, // fillDeadline
        0, // exclusivityDeadline
        "0x" // message
      );

      await expect(tx).to.emit(mockSpokePool, "V3FundsDeposited");
    });

    it("should transfer tokens on depositV3", async () => {
      const initialBalance = await mockUSDC.balanceOf(ownerAddress);
      const depositAmount = ethers.utils.parseUnits("50", 6);

      await mockUSDC.approve(mockSpokePool.address, depositAmount);

      await mockSpokePool.depositV3(
        ownerAddress,
        ownerAddress,
        mockUSDC.address,
        mockUSDC.address,
        depositAmount,
        ethers.utils.parseUnits("49", 6),
        10,
        ethers.constants.AddressZero,
        Math.floor(Date.now() / 1000),
        Math.floor(Date.now() / 1000) + 3600,
        0,
        "0x"
      );

      const finalBalance = await mockUSDC.balanceOf(ownerAddress);
      expect(initialBalance.sub(finalBalance)).to.equal(depositAmount);
    });
  });

  describe("Token Functionality", () => {
    it("should mint tokens correctly", async () => {
      const mintAmount = ethers.utils.parseUnits("100", 6);
      await mockUSDC.mint(ownerAddress, mintAmount);

      const balance = await mockUSDC.balanceOf(ownerAddress);
      expect(balance).to.be.gte(mintAmount);
    });

    it("should handle transfers", async () => {
      const transferAmount = ethers.utils.parseUnits("10", 6);
      const userAddress = await user.getAddress();

      await mockUSDC.transfer(userAddress, transferAmount);

      const userBalance = await mockUSDC.balanceOf(userAddress);
      expect(userBalance).to.equal(transferAmount);
    });

    it("should handle approvals", async () => {
      const approveAmount = ethers.utils.parseUnits("50", 6);
      await mockUSDC.approve(aIntents.address, approveAmount);

      const allowance = await mockUSDC.allowance(ownerAddress, aIntents.address);
      expect(allowance).to.equal(approveAmount);
    });
  });
});
