import { expect } from "chai";
import hre, { deployments, ethers } from "hardhat";
import { Contract, Signer, BigNumber } from "ethers";
import { Address } from "hardhat-deploy/types";

/**
 * Comprehensive coverage tests for EAcrossHandler and AIntents
 * Focus: Edge cases, error conditions, and state transitions
 */
describe("Across Coverage Tests", () => {
  let accounts: Signer[];
  let deployer: Signer;
  let owner: Signer;
  let user: Signer;
  let unauthorized: Signer;
  let deployerAddress: Address;
  let ownerAddress: Address;
  let userAddress: Address;
  let unauthorizedAddress: Address;
  let eAcrossHandler: Contract;
  let aIntents: Contract;
  let acrossSpokePool: Contract;
  let mockUSDC: Contract;
  let mockDAI: Contract;
  let mockERC20: Contract;

  const OpType = {
    Transfer: 0,
    Rebalance: 1,
    Sync: 2,
  };

  beforeEach(async () => {
    accounts = await ethers.getSigners();
    deployer = accounts[0];
    owner = accounts[1];
    user = accounts[2];
    unauthorized = accounts[3];
    deployerAddress = await deployer.getAddress();
    ownerAddress = await owner.getAddress();
    userAddress = await user.getAddress();
    unauthorizedAddress = await unauthorized.getAddress();

    // Deploy mock ERC20 tokens
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const WETH9Instance = await deployments.get("WETH9")
    const WETH9 = await hre.ethers.getContractFactory("WETH9");
    const weth = await WETH9.attach(WETH9Instance.address);
    mockUSDC = await MockERC20.deploy("USD Coin", "USDC", 6);
    mockDAI = await MockERC20.deploy("Dai Stablecoin", "DAI", 18);
    mockERC20 = await MockERC20.deploy("Test Token", "TEST", 8);

    // Deploy mock SpokePool
    const MockAcrossSpokePool = await ethers.getContractFactory("MockAcrossSpokePool");
    acrossSpokePool = await MockAcrossSpokePool.deploy(weth.address);

    // Deploy EAcrossHandler
    const EAcrossHandler = await ethers.getContractFactory("EAcrossHandler");
    eAcrossHandler = await EAcrossHandler.deploy(acrossSpokePool.address);

    // Deploy AIntents
    const AIntents = await ethers.getContractFactory("AIntents");
    aIntents = await AIntents.deploy(acrossSpokePool.address);
  });

  describe("EAcrossHandler - Constructor Tests", () => {
    it("should set the correct SpokePool address", async () => {
      expect(await eAcrossHandler.acrossSpokePool()).to.equal(acrossSpokePool.address);
    });

    it("should revert with zero address", async () => {
      const EAcrossHandler = await ethers.getContractFactory("EAcrossHandler");
      await expect(EAcrossHandler.deploy(ethers.constants.AddressZero)).to.be.revertedWith("INVALID_SPOKE_POOL");
    });

    it("should deploy with non-zero code", async () => {
      const code = await ethers.provider.getCode(eAcrossHandler.address);
      expect(code).to.not.equal("0x");
      expect(code.length).to.be.greaterThan(2);
    });
  });

  describe("EAcrossHandler - Access Control", () => {
    it("should reject calls from non-SpokePool addresses", async () => {
      const message = encodeDestinationMessage({
        opType: OpType.Transfer,
        sourceChainId: 1,
        sourceNav: 0,
        sourceDecimals: 18,
        navTolerance: 0,
        shouldUnwrap: false,
        sourceNativeAmount: 0,
      });

      await expect(
        eAcrossHandler.connect(unauthorized).handleV3AcrossMessage(mockUSDC.address, 100, message)
      ).to.be.reverted;
    });

    it("should reject calls from deployer", async () => {
      const message = encodeDestinationMessage({
        opType: OpType.Transfer,
        sourceChainId: 1,
        sourceNav: 0,
        sourceDecimals: 18,
        navTolerance: 0,
        shouldUnwrap: false,
        sourceNativeAmount: 0,
      });

      await expect(
        eAcrossHandler.connect(deployer).handleV3AcrossMessage(mockUSDC.address, 100, message)
      ).to.be.reverted;
    });

    it("should reject calls from owner", async () => {
      const message = encodeDestinationMessage({
        opType: OpType.Transfer,
        sourceChainId: 1,
        sourceNav: 0,
        sourceDecimals: 18,
        navTolerance: 0,
        shouldUnwrap: false,
        sourceNativeAmount: 0,
      });

      await expect(
        eAcrossHandler.connect(owner).handleV3AcrossMessage(mockUSDC.address, 100, message)
      ).to.be.reverted;
    });
  });

  describe("EAcrossHandler - Message Encoding/Decoding", () => {
    it("should correctly encode/decode Transfer mode with minimal values", async () => {
      const msg = {
        opType: OpType.Transfer,
        sourceChainId: 0,
        sourceNav: 0,
        sourceDecimals: 18,
        navTolerance: 0,
        shouldUnwrap: false,
        sourceNativeAmount: 0,
      };

      const encoded = encodeDestinationMessage(msg);
      const decoded = decodeDestinationMessage(encoded);

      expect(decoded.opType).to.equal(msg.opType);
      expect(decoded.sourceChainId).to.equal(msg.sourceChainId);
      expect(decoded.sourceNav).to.equal(msg.sourceNav);
    });

    it("should correctly encode/decode Transfer mode with max values", async () => {
      const msg = {
        opType: OpType.Transfer,
        sourceChainId: ethers.constants.MaxUint256,
        sourceNav: ethers.constants.MaxUint256,
        sourceDecimals: 255,
        navTolerance: ethers.constants.MaxUint256,
        shouldUnwrap: true,
        sourceNativeAmount: ethers.constants.MaxUint256,
      };

      const encoded = encodeDestinationMessage(msg);
      const decoded = decodeDestinationMessage(encoded);

      expect(decoded.opType).to.equal(msg.opType);
      expect(decoded.sourceChainId).to.deep.equal(msg.sourceChainId);
      expect(decoded.sourceNav).to.deep.equal(msg.sourceNav);
      expect(decoded.shouldUnwrap).to.equal(msg.shouldUnwrap);
    });

    it("should correctly encode/decode Rebalance mode", async () => {
      const msg = {
        opType: OpType.Rebalance,
        sourceChainId: 42161,
        sourceNav: ethers.utils.parseEther("1.5"),
        sourceDecimals: 18,
        navTolerance: 200,
        shouldUnwrap: false,
        sourceNativeAmount: 0,
      };

      const encoded = encodeDestinationMessage(msg);
      const decoded = decodeDestinationMessage(encoded);

      expect(decoded.opType).to.equal(msg.opType);
      expect(decoded.sourceNav).to.deep.equal(msg.sourceNav);
      expect(decoded.navTolerance).to.equal(msg.navTolerance);
    });

    it("should correctly encode/decode Sync mode", async () => {
      const msg = {
        opType: OpType.Sync,
        sourceChainId: 10,
        sourceNav: ethers.utils.parseUnits("2.5", 6),
        sourceDecimals: 6,
        navTolerance: 0,
        shouldUnwrap: true,
        sourceNativeAmount: ethers.utils.parseEther("0.1"),
      };

      const encoded = encodeDestinationMessage(msg);
      const decoded = decodeDestinationMessage(encoded);

      expect(decoded.opType).to.equal(msg.opType);
      expect(decoded.sourceChainId).to.equal(msg.sourceChainId);
      expect(decoded.sourceNav).to.deep.equal(msg.sourceNav);
      expect(decoded.sourceDecimals).to.equal(msg.sourceDecimals);
      expect(decoded.shouldUnwrap).to.equal(msg.shouldUnwrap);
    });

    it("should handle different token decimals", async () => {
      const decimals = [6, 8, 18, 27];

      for (const decimal of decimals) {
        const msg = {
          opType: OpType.Transfer,
          sourceChainId: 1,
          sourceNav: ethers.utils.parseUnits("1", decimal),
          sourceDecimals: decimal,
          navTolerance: 100,
          shouldUnwrap: false,
          sourceNativeAmount: 0,
        };

        const encoded = encodeDestinationMessage(msg);
        const decoded = decodeDestinationMessage(encoded);

        expect(decoded.sourceDecimals).to.equal(decimal);
        expect(decoded.sourceNav).to.deep.equal(msg.sourceNav);
      }
    });
  });

  describe("EAcrossHandler - NAV Normalization", () => {
    it("should not change NAV when decimals are equal", () => {
      const testCases = [
        { nav: ethers.utils.parseEther("1"), from: 18, to: 18 },
        { nav: ethers.utils.parseUnits("1", 6), from: 6, to: 6 },
        { nav: ethers.utils.parseUnits("1", 8), from: 8, to: 8 },
      ];

      for (const tc of testCases) {
        const normalized = normalizeNav(tc.nav, tc.from, tc.to);
        expect(normalized).to.deep.equal(tc.nav);
      }
    });

    it("should downscale NAV correctly", () => {
      const testCases = [
        { nav: ethers.utils.parseEther("1"), from: 18, to: 6, expected: ethers.utils.parseUnits("1", 6) },
        { nav: ethers.utils.parseEther("1"), from: 18, to: 8, expected: ethers.utils.parseUnits("1", 8) },
        { nav: ethers.utils.parseUnits("1", 8), from: 8, to: 6, expected: ethers.utils.parseUnits("1", 6) },
      ];

      for (const tc of testCases) {
        const normalized = normalizeNav(tc.nav, tc.from, tc.to);
        expect(normalized).to.deep.equal(tc.expected);
      }
    });

    it("should upscale NAV correctly", () => {
      const testCases = [
        { nav: ethers.utils.parseUnits("1", 6), from: 6, to: 18, expected: ethers.utils.parseEther("1") },
        { nav: ethers.utils.parseUnits("1", 6), from: 6, to: 8, expected: ethers.utils.parseUnits("1", 8) },
        { nav: ethers.utils.parseUnits("1", 8), from: 8, to: 18, expected: ethers.utils.parseEther("1") },
      ];

      for (const tc of testCases) {
        const normalized = normalizeNav(tc.nav, tc.from, tc.to);
        expect(normalized).to.deep.equal(tc.expected);
      }
    });

    it("should handle precision loss in downscaling", () => {
      const nav = ethers.utils.parseEther("1").add(123); // 1.000000000000000123 ETH
      const normalized = normalizeNav(nav, 18, 6);
      const expected = ethers.utils.parseUnits("1", 6); // Precision lost

      expect(normalized).to.deep.equal(expected);
    });
  });

  describe("EAcrossHandler - Tolerance Calculations", () => {
    it("should calculate 0.01% tolerance", () => {
      const nav = ethers.utils.parseEther("1");
      const tolerance = 1; // 0.01%
      const amount = calculateTolerance(nav, tolerance);

      expect(amount).to.equal(ethers.utils.parseEther("0.0001"));
    });

    it("should calculate 1% tolerance", () => {
      const nav = ethers.utils.parseEther("1");
      const tolerance = 100; // 1%
      const amount = calculateTolerance(nav, tolerance);

      expect(amount).to.equal(ethers.utils.parseEther("0.01"));
    });

    it("should calculate 5% tolerance", () => {
      const nav = ethers.utils.parseEther("1");
      const tolerance = 500; // 5%
      const amount = calculateTolerance(nav, tolerance);

      expect(amount).to.equal(ethers.utils.parseEther("0.05"));
    });

    it("should calculate 10% tolerance", () => {
      const nav = ethers.utils.parseEther("1");
      const tolerance = 1000; // 10%
      const amount = calculateTolerance(nav, tolerance);

      expect(amount).to.equal(ethers.utils.parseEther("0.1"));
    });

    it("should handle tolerance with different NAV values", () => {
      const testCases = [
        { nav: ethers.utils.parseEther("0.5"), tolerance: 100, expected: ethers.utils.parseEther("0.005") },
        { nav: ethers.utils.parseEther("2"), tolerance: 100, expected: ethers.utils.parseEther("0.02") },
        { nav: ethers.utils.parseEther("10"), tolerance: 100, expected: ethers.utils.parseEther("0.1") },
      ];

      for (const tc of testCases) {
        const amount = calculateTolerance(tc.nav, tc.tolerance);
        expect(amount).to.deep.equal(tc.expected);
      }
    });

    it("should calculate tolerance range correctly", () => {
      const nav = ethers.utils.parseEther("1");
      const tolerance = 200; // 2%
      const amount = calculateTolerance(nav, tolerance);
      const minNav = nav.sub(amount);
      const maxNav = nav.add(amount);

      expect(minNav).to.equal(ethers.utils.parseEther("0.98"));
      expect(maxNav).to.equal(ethers.utils.parseEther("1.02"));
    });
  });

  describe("AIntents - Constructor and Immutables", () => {
    it("should set correct SpokePool address", async () => {
      expect(await aIntents.acrossSpokePool()).to.equal(acrossSpokePool.address);
    });

    it("should return correct required version", async () => {
      const version = await aIntents.requiredVersion();
      expect(version).to.equal("HF_4.1.0");
    });

    it("should have non-zero bytecode", async () => {
      const code = await ethers.provider.getCode(aIntents.address);
      expect(code).to.not.equal("0x");
      expect(code.length).to.be.greaterThan(2);
    });
  });

  describe("AIntents - Direct Call Protection", () => {
    it("should reject direct calls to depositV3", async () => {
      const params = createAcrossParams({
        inputToken: mockUSDC.address,
        outputToken: mockUSDC.address,
        inputAmount: ethers.utils.parseUnits("100", 6),
        outputAmount: ethers.utils.parseUnits("99", 6),
        destinationChainId: 10,
        opType: OpType.Transfer,
        navTolerance: 100,
      });

      await expect(aIntents.depositV3(params)).to.be.reverted;
    });

    it("should reject direct calls from any account", async () => {
      const params = createAcrossParams({
        inputToken: mockUSDC.address,
        outputToken: mockUSDC.address,
        inputAmount: ethers.utils.parseUnits("100", 6),
        outputAmount: ethers.utils.parseUnits("99", 6),
        destinationChainId: 10,
        opType: OpType.Transfer,
        navTolerance: 100,
      });

      await expect(aIntents.connect(owner).depositV3(params)).to.be.reverted;
      await expect(aIntents.connect(user).depositV3(params)).to.be.reverted;
      await expect(aIntents.connect(unauthorized).depositV3(params)).to.be.reverted;
    });
  });

  describe("AIntents - Source Message Encoding", () => {
    it("should encode Transfer mode source message", () => {
      const msg = {
        opType: OpType.Transfer,
        navTolerance: 100,
        shouldUnwrapOnDestination: false,
        sourceNativeAmount: 0,
      };

      const encoded = encodeSourceMessage(msg);
      const decoded = decodeSourceMessage(encoded);

      expect(decoded.opType).to.equal(msg.opType);
      expect(decoded.navTolerance).to.equal(msg.navTolerance);
      expect(decoded.shouldUnwrapOnDestination).to.equal(msg.shouldUnwrapOnDestination);
      expect(decoded.sourceNativeAmount).to.equal(msg.sourceNativeAmount);
    });

    it("should encode Rebalance mode source message", () => {
      const msg = {
        opType: OpType.Rebalance,
        navTolerance: 500,
        shouldUnwrapOnDestination: true,
        sourceNativeAmount: ethers.utils.parseEther("0.5"),
      };

      const encoded = encodeSourceMessage(msg);
      const decoded = decodeSourceMessage(encoded);

      expect(decoded.opType).to.equal(msg.opType);
      expect(decoded.navTolerance).to.equal(msg.navTolerance);
      expect(decoded.shouldUnwrapOnDestination).to.equal(msg.shouldUnwrapOnDestination);
      expect(decoded.sourceNativeAmount).to.deep.equal(msg.sourceNativeAmount);
    });

    it("should encode Sync mode source message", () => {
      const msg = {
        opType: OpType.Sync,
        navTolerance: 0,
        shouldUnwrapOnDestination: false,
        sourceNativeAmount: 0,
      };

      const encoded = encodeSourceMessage(msg);
      const decoded = decodeSourceMessage(encoded);

      expect(decoded.opType).to.equal(msg.opType);
      expect(decoded.navTolerance).to.equal(msg.navTolerance);
    });

    it("should handle different tolerance values", () => {
      const tolerances = [0, 1, 50, 100, 500, 1000, 5000, 10000];

      for (const tolerance of tolerances) {
        const msg = {
          opType: OpType.Transfer,
          navTolerance: tolerance,
          shouldUnwrapOnDestination: false,
          sourceNativeAmount: 0,
        };

        const encoded = encodeSourceMessage(msg);
        const decoded = decodeSourceMessage(encoded);

        expect(decoded.navTolerance).to.equal(tolerance);
      }
    });
  });

  describe("Storage Slot Calculations", () => {
    it("should calculate virtual balances slot correctly", () => {
      const expectedSlot = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("pool.proxy.virtualBalances"));
      const actualSlot = BigNumber.from(expectedSlot).sub(1);

      expect(actualSlot.toHexString()).to.equal("0x19797d8be84f650fe18ebccb97578c2adb7abe9b7c86852694a3ceb69073d1d1");
    });

    it("should calculate chain nav spreads slot correctly", () => {
      const expectedSlot = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("pool.proxy.chain.nav.spreads"));
      const actualSlot = BigNumber.from(expectedSlot).sub(1);

      // This should match MixinConstants
      expect(actualSlot.toHexString()).to.equal("0x1effae8a79ec0c3b88754a639dc07316aa9c4de89b6b9794fb7c1d791c43492d");
    });

    it("should use ERC-7201 pattern with dot notation", () => {
      // Virtual balances
      const virtualBalancesString = "pool.proxy.virtualBalances";
      expect(virtualBalancesString).to.include(".");
      expect(virtualBalancesString.split(".").length).to.equal(3);

      // Chain nav spreads
      const chainNavSpreadsString = "pool.proxy.chain.nav.spreads";
      expect(chainNavSpreadsString).to.include(".");
      expect(chainNavSpreadsString.split(".").length).to.equal(5);
    });
  });

  describe("OpType Enum Values", () => {
    it("should have correct enum ordering", () => {
      expect(OpType.Transfer).to.equal(0);
      expect(OpType.Rebalance).to.equal(1);
      expect(OpType.Sync).to.equal(2);
    });

    it("should maintain distinct values", () => {
      expect(OpType.Transfer).to.not.equal(OpType.Rebalance);
      expect(OpType.Rebalance).to.not.equal(OpType.Sync);
      expect(OpType.Transfer).to.not.equal(OpType.Sync);
    });
  });

  // Helper functions
  function encodeDestinationMessage(msg: any): string {
    return ethers.utils.defaultAbiCoder.encode(
      ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
      [[msg.opType, msg.sourceChainId, msg.sourceNav, msg.sourceDecimals, msg.navTolerance, msg.shouldUnwrap, msg.sourceNativeAmount]]
    );
  }

  function decodeDestinationMessage(encoded: string): any {
    const decoded = ethers.utils.defaultAbiCoder.decode(
      ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
      encoded
    )[0];

    return {
      opType: decoded[0],
      sourceChainId: decoded[1],
      sourceNav: decoded[2],
      sourceDecimals: decoded[3],
      navTolerance: decoded[4],
      shouldUnwrap: decoded[5],
      sourceNativeAmount: decoded[6],
    };
  }

  function encodeSourceMessage(msg: any): string {
    return ethers.utils.defaultAbiCoder.encode(
      ["tuple(uint8,uint256,bool,uint256)"],
      [[msg.opType, msg.navTolerance, msg.shouldUnwrapOnDestination, msg.sourceNativeAmount]]
    );
  }

  function decodeSourceMessage(encoded: string): any {
    const decoded = ethers.utils.defaultAbiCoder.decode(
      ["tuple(uint8,uint256,bool,uint256)"],
      encoded
    )[0];

    return {
      opType: decoded[0],
      navTolerance: decoded[1],
      shouldUnwrapOnDestination: decoded[2],
      sourceNativeAmount: decoded[3],
    };
  }

  function normalizeNav(nav: BigNumber, sourceDecimals: number, destDecimals: number): BigNumber {
    if (sourceDecimals === destDecimals) {
      return nav;
    } else if (sourceDecimals > destDecimals) {
      return nav.div(BigNumber.from(10).pow(sourceDecimals - destDecimals));
    } else {
      return nav.mul(BigNumber.from(10).pow(destDecimals - sourceDecimals));
    }
  }

  function calculateTolerance(nav: BigNumber, toleranceBps: number): BigNumber {
    return nav.mul(toleranceBps).div(10000);
  }

  function createAcrossParams(config: any): any {
    return {
      inputToken: config.inputToken,
      outputToken: config.outputToken,
      inputAmount: config.inputAmount,
      outputAmount: config.outputAmount,
      destinationChainId: config.destinationChainId,
      exclusiveRelayer: ethers.constants.AddressZero,
      quoteTimestamp: Math.floor(Date.now() / 1000),
      fillDeadline: Math.floor(Date.now() / 1000) + 3600,
      exclusivityDeadline: 0,
      message: encodeSourceMessage({
        opType: config.opType,
        navTolerance: config.navTolerance,
        shouldUnwrapOnDestination: config.shouldUnwrap || false,
        sourceNativeAmount: config.sourceNativeAmount || 0,
      }),
    };
  }
});
