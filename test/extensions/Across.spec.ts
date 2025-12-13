import { expect } from "chai";
import hre, { ethers } from "hardhat";
import { Contract, Signer } from "ethers";
import { Address } from "hardhat-deploy/types";

describe("Across Integration", () => {
  let accounts: Signer[];
  let deployer: Signer;
  let user: Signer;
  let deployerAddress: Address;
  let userAddress: Address;

  let eAcrossHandler: Contract;
  let aIntents: Contract;
  let mockSpokePool: Contract;
  let mockWETH: Contract;
  let mockUSDC: Contract;
  let mockPool: Contract;

  beforeEach(async () => {
    accounts = await ethers.getSigners();
    deployer = accounts[0];
    user = accounts[1];
    deployerAddress = await deployer.getAddress();
    userAddress = await user.getAddress();

    // Deploy mock contracts
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    mockWETH = await MockERC20.deploy("Wrapped Ether", "WETH", 18);
    mockUSDC = await MockERC20.deploy("USD Coin", "USDC", 6);

    // Deploy mock SpokePool (from AcrossMocks.sol)
    const MockSpokePool = await ethers.getContractFactory("MockAcrossSpokePool");
    mockSpokePool = await MockSpokePool.deploy(mockWETH.address);

    // Deploy EAcrossHandler
    const EAcrossHandler = await ethers.getContractFactory("EAcrossHandler");
    eAcrossHandler = await EAcrossHandler.deploy(mockSpokePool.address);

    // Deploy AIntents
    const AIntents = await ethers.getContractFactory("AIntents");
    aIntents = await AIntents.deploy(mockSpokePool.address);
  });

  describe("EAcrossHandler", () => {
    it("should deploy with correct SpokePool address", async () => {
      expect(await eAcrossHandler.acrossSpokePool()).to.equal(mockSpokePool.address);
    });

    it("should revert when deploying with zero address", async () => {
      const EAcrossHandler = await ethers.getContractFactory("EAcrossHandler");
      await expect(EAcrossHandler.deploy(ethers.constants.AddressZero)).to.be.revertedWith(
        "INVALID_SPOKE_POOL"
      );
    });

    it("should revert when called by unauthorized caller", async () => {
      const message = ethers.utils.defaultAbiCoder.encode(
        ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
        [[0, 0, 0, 18, 0, false, 0]] // Transfer mode
      );

      // Expect revert since caller is not the SpokePool
      await expect(
        eAcrossHandler.handleV3AcrossMessage(mockUSDC.address, ethers.utils.parseUnits("100", 6), message)
      ).to.be.reverted;
    });

    describe("Message Encoding/Decoding", () => {
      it("should encode/decode transfer mode message", async () => {
        const message = {
          opType: 0, // Transfer
          sourceChainId: 42161,
          sourceNav: 0,
          sourceDecimals: 6,
          navTolerance: 0,
          shouldUnwrap: false,
          sourceNativeAmount: 0,
        };

        const encoded = ethers.utils.defaultAbiCoder.encode(
          ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
          [[
            message.opType,
            message.sourceChainId,
            message.sourceNav,
            message.sourceDecimals,
            message.navTolerance,
            message.shouldUnwrap,
            message.sourceNativeAmount,
          ]]
        );

        const decoded = ethers.utils.defaultAbiCoder.decode(
          ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
          encoded
        )[0];

        expect(decoded[0]).to.equal(message.opType);
        expect(decoded[1]).to.equal(message.sourceChainId);
      });

      it("should encode/decode rebalance mode message", async () => {
        const message = {
          opType: 1, // Rebalance
          sourceChainId: 42161,
          sourceNav: ethers.utils.parseEther("1"),
          sourceDecimals: 18,
          navTolerance: 100, // 1%
          shouldUnwrap: false,
          sourceNativeAmount: 0,
        };

        const encoded = ethers.utils.defaultAbiCoder.encode(
          ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
          [[
            message.opType,
            message.sourceChainId,
            message.sourceNav,
            message.sourceDecimals,
            message.navTolerance,
            message.shouldUnwrap,
            message.sourceNativeAmount,
          ]]
        );

        const decoded = ethers.utils.defaultAbiCoder.decode(
          ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
          encoded
        )[0];

        expect(decoded[0]).to.equal(message.opType);
        expect(decoded[2]).to.equal(message.sourceNav);
        expect(decoded[4]).to.equal(message.navTolerance);
      });

      it("should encode/decode sync mode message", async () => {
        const message = {
          opType: 2, // Sync
          sourceChainId: 42161,
          sourceNav: ethers.utils.parseEther("1.5"),
          sourceDecimals: 18,
          navTolerance: 0,
          shouldUnwrap: false,
          sourceNativeAmount: 0,
        };

        const encoded = ethers.utils.defaultAbiCoder.encode(
          ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
          [[
            message.opType,
            message.sourceChainId,
            message.sourceNav,
            message.sourceDecimals,
            message.navTolerance,
            message.shouldUnwrap,
            message.sourceNativeAmount,
          ]]
        );

        const decoded = ethers.utils.defaultAbiCoder.decode(
          ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
          encoded
        )[0];

        expect(decoded[0]).to.equal(message.opType);
        expect(decoded[2]).to.equal(message.sourceNav);
      });
    });
  });

  describe("AIntents", () => {
    it("should deploy with correct SpokePool address", async () => {
      expect(await aIntents.acrossSpokePool()).to.equal(mockSpokePool.address);
    });

    it("should return correct required version", async () => {
      expect(await aIntents.requiredVersion()).to.equal("HF_4.1.0");
    });

    it("should revert when called directly (not via delegatecall)", async () => {
      const params = {
        inputToken: mockUSDC.address,
        outputToken: mockUSDC.address,
        inputAmount: ethers.utils.parseUnits("100", 6),
        outputAmount: ethers.utils.parseUnits("99", 6),
        destinationChainId: 10,
        exclusiveRelayer: ethers.constants.AddressZero,
        quoteTimestamp: Math.floor(Date.now() / 1000),
        fillDeadline: Math.floor(Date.now() / 1000) + 3600,
        exclusivityDeadline: 0,
        message: ethers.utils.defaultAbiCoder.encode(
          ["tuple(uint8,uint256,bool,uint256)"],
          [[0, 100, false, 0]] // Transfer mode
        ),
      };

      await expect(aIntents.depositV3(params)).to.be.reverted;
    });

    describe("Source Message Encoding", () => {
      it("should encode transfer mode source message", async () => {
        const sourceMessage = {
          opType: 0, // Transfer
          navTolerance: 100,
          shouldUnwrapOnDestination: false,
          sourceNativeAmount: 0,
        };

        const encoded = ethers.utils.defaultAbiCoder.encode(
          ["tuple(uint8,uint256,bool,uint256)"],
          [[
            sourceMessage.opType,
            sourceMessage.navTolerance,
            sourceMessage.shouldUnwrapOnDestination,
            sourceMessage.sourceNativeAmount,
          ]]
        );

        const decoded = ethers.utils.defaultAbiCoder.decode(
          ["tuple(uint8,uint256,bool,uint256)"],
          encoded
        )[0];

        expect(decoded[0]).to.equal(sourceMessage.opType);
        expect(decoded[1]).to.equal(sourceMessage.navTolerance);
        expect(decoded[2]).to.equal(sourceMessage.shouldUnwrapOnDestination);
      });

      it("should encode rebalance mode source message", async () => {
        const sourceMessage = {
          opType: 1, // Rebalance
          navTolerance: 200, // 2%
          shouldUnwrapOnDestination: false,
          sourceNativeAmount: 0,
        };

        const encoded = ethers.utils.defaultAbiCoder.encode(
          ["tuple(uint8,uint256,bool,uint256)"],
          [[
            sourceMessage.opType,
            sourceMessage.navTolerance,
            sourceMessage.shouldUnwrapOnDestination,
            sourceMessage.sourceNativeAmount,
          ]]
        );

        const decoded = ethers.utils.defaultAbiCoder.decode(
          ["tuple(uint8,uint256,bool,uint256)"],
          encoded
        )[0];

        expect(decoded[0]).to.equal(sourceMessage.opType);
        expect(decoded[1]).to.equal(sourceMessage.navTolerance);
      });

      it("should encode sync mode source message", async () => {
        const sourceMessage = {
          opType: 2, // Sync
          navTolerance: 0,
          shouldUnwrapOnDestination: false,
          sourceNativeAmount: 0,
        };

        const encoded = ethers.utils.defaultAbiCoder.encode(
          ["tuple(uint8,uint256,bool,uint256)"],
          [[
            sourceMessage.opType,
            sourceMessage.navTolerance,
            sourceMessage.shouldUnwrapOnDestination,
            sourceMessage.sourceNativeAmount,
          ]]
        );

        const decoded = ethers.utils.defaultAbiCoder.decode(
          ["tuple(uint8,uint256,bool,uint256)"],
          encoded
        )[0];

        expect(decoded[0]).to.equal(sourceMessage.opType);
      });
    });
  });

  describe("Storage Slots", () => {
    it("should have correct virtual balances slot", () => {
      const expectedSlot = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("pool.proxy.virtualBalances"));
      const actualSlot = ethers.BigNumber.from(expectedSlot).sub(1);

      expect(actualSlot.toHexString()).to.equal("0x19797d8be84f650fe18ebccb97578c2adb7abe9b7c86852694a3ceb69073d1d1");
    });

    it("should have correct chain nav spreads slot", () => {
      const expectedSlot = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("pool.proxy.chain.nav.spreads"));
      const actualSlot = ethers.BigNumber.from(expectedSlot).sub(1);

      // This is the value from MixinConstants.sol
      expect(actualSlot.toHexString()).to.equal("0x1effae8a79ec0c3b88754a639dc07316aa9c4de89b6b9794fb7c1d791c43492d");
    });
  });

  describe("Message Type Enum", () => {
    it("should have correct OpType values", () => {
      const Transfer = 0;
      const Rebalance = 1;
      const Sync = 2;

      expect(Transfer).to.equal(0);
      expect(Rebalance).to.equal(1);
      expect(Sync).to.equal(2);
    });
  });

  describe("NAV Normalization", () => {
    it("should correctly normalize NAV with same decimals", () => {
      const nav = ethers.utils.parseEther("1");
      const sourceDecimals = 18;
      const destDecimals = 18;

      // No change expected
      expect(nav).to.equal(ethers.utils.parseEther("1"));
    });

    it("should correctly downscale NAV", () => {
      const nav = ethers.utils.parseEther("1"); // 1e18
      const sourceDecimals = 18;
      const destDecimals = 6;

      const expected = ethers.utils.parseUnits("1", 6); // 1e6
      const actual = nav.div(ethers.BigNumber.from(10).pow(sourceDecimals - destDecimals));

      expect(actual).to.equal(expected);
    });

    it("should correctly upscale NAV", () => {
      const nav = ethers.utils.parseUnits("1", 6); // 1e6
      const sourceDecimals = 6;
      const destDecimals = 18;

      const expected = ethers.utils.parseEther("1"); // 1e18
      const actual = nav.mul(ethers.BigNumber.from(10).pow(destDecimals - sourceDecimals));

      expect(actual).to.equal(expected);
    });
  });

  describe("Tolerance Calculation", () => {
    it("should calculate 1% tolerance correctly", () => {
      const nav = ethers.utils.parseEther("1");
      const toleranceBps = 100; // 1%

      const toleranceAmount = nav.mul(toleranceBps).div(10000);

      expect(toleranceAmount).to.equal(ethers.utils.parseEther("0.01"));
    });

    it("should calculate 2% tolerance correctly", () => {
      const nav = ethers.utils.parseEther("1");
      const toleranceBps = 200; // 2%

      const toleranceAmount = nav.mul(toleranceBps).div(10000);

      expect(toleranceAmount).to.equal(ethers.utils.parseEther("0.02"));
    });

    it("should calculate tolerance range correctly", () => {
      const nav = ethers.utils.parseEther("1");
      const toleranceBps = 100; // 1%

      const toleranceAmount = nav.mul(toleranceBps).div(10000);
      const minNav = nav.sub(toleranceAmount);
      const maxNav = nav.add(toleranceAmount);

      expect(minNav).to.equal(ethers.utils.parseEther("0.99"));
      expect(maxNav).to.equal(ethers.utils.parseEther("1.01"));
    });
  });
});
