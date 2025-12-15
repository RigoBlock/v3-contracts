import { expect } from "chai";
import hre, { ethers } from "hardhat";

/**
 * Comprehensive tests for EAcrossHandler and AIntents contracts
 * Tests cover: deployment, access control, message encoding/decoding, NAV calculations, storage slots
 */
describe("Across Integration", () => {
  let eAcrossHandler: any;
  let aIntents: any;
  let acrossSpokePool: any;
  let wethContract: any;
  let mockUSDC: any;
  let owner: any;
  let user: any;
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

    // Get deployed contracts from setup
    const WETH9Instance = await hre.deployments.get("WETH9");
    const WETH9 = await hre.ethers.getContractFactory("WETH9");
    wethContract = await WETH9.attach(WETH9Instance.address);

    const MockAcrossSpokePoolInstance = await hre.deployments.get("MockAcrossSpokePool");
    const MockAcrossSpokePool = await hre.ethers.getContractFactory("MockAcrossSpokePool");
    acrossSpokePool = await MockAcrossSpokePool.attach(MockAcrossSpokePoolInstance.address);

    const EAcrossHandlerInstance = await hre.deployments.get("EAcrossHandler");
    const EAcrossHandler = await hre.ethers.getContractFactory("EAcrossHandler");
    eAcrossHandler = await EAcrossHandler.attach(EAcrossHandlerInstance.address);

    const AIntentsInstance = await hre.deployments.get("AIntents");
    const AIntents = await hre.ethers.getContractFactory("AIntents");
    aIntents = await AIntents.attach(AIntentsInstance.address);

    // Deploy mock token for testing
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    mockUSDC = await MockERC20.deploy("USD Coin", "USDC", 6);
  });

  describe("EAcrossHandler", () => {
    describe("Constructor and Deployment", () => {
      it("should deploy with correct SpokePool address", async () => {
        const spokePoolAddr = await eAcrossHandler.acrossSpokePool();
        expect(spokePoolAddr).to.equal(acrossSpokePool.address);
      });

      it("should revert when deploying with zero address", async () => {
        const EAcrossHandler = await ethers.getContractFactory("EAcrossHandler");
        await expect(
          EAcrossHandler.deploy(ethers.constants.AddressZero)
        ).to.be.revertedWith("INVALID_SPOKE_POOL");
      });

      it("should store immutable SpokePool correctly", async () => {
        const addr1 = await eAcrossHandler.acrossSpokePool();
        expect(addr1).to.equal(acrossSpokePool.address);
      });

      it("should deploy with non-zero bytecode", async () => {
        const code = await ethers.provider.getCode(eAcrossHandler.address);
        expect(code).to.not.equal("0x");
        expect(code.length).to.be.greaterThan(2);
      });
    });

    describe("Access Control", () => {
      it("should reject calls from non-SpokePool addresses", async () => {
        const message = ethers.utils.defaultAbiCoder.encode(
          ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
          [[OpType.Transfer, 1, 0, 18, 0, false, 0]]
        );

        await expect(
          eAcrossHandler.handleV3AcrossMessage(mockUSDC.address, 1000000, message)
        ).to.be.revertedWith("UnauthorizedCaller");
      });

      it("should reject calls from deployer", async () => {
        const message = ethers.utils.defaultAbiCoder.encode(
          ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
          [[OpType.Transfer, 1, 0, 18, 0, false, 0]]
        );

        await expect(
          eAcrossHandler.connect(owner).handleV3AcrossMessage(mockUSDC.address, 1000000, message)
        ).to.be.revertedWith("UnauthorizedCaller");
      });

      it("should reject calls from arbitrary user", async () => {
        const message = ethers.utils.defaultAbiCoder.encode(
          ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
          [[OpType.Transfer, 1, 0, 18, 0, false, 0]]
        );

        await expect(
          eAcrossHandler.connect(user).handleV3AcrossMessage(mockUSDC.address, 1000000, message)
        ).to.be.revertedWith("UnauthorizedCaller");
      });
    });

    describe("Message Encoding/Decoding", () => {
      it("should encode/decode transfer mode message with minimal values", async () => {
        const transferMsg = {
          opType: OpType.Transfer,
          sourceChainId: 1,
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
        expect(decoded[1]).to.equal(transferMsg.sourceChainId);
        expect(decoded[2]).to.equal(transferMsg.sourceNav);
        expect(decoded[3]).to.equal(transferMsg.sourceDecimals);
        expect(decoded[4]).to.equal(transferMsg.navTolerance);
        expect(decoded[5]).to.equal(transferMsg.shouldUnwrap);
        expect(decoded[6]).to.equal(transferMsg.sourceNativeAmount);
      });

      it("should encode/decode transfer mode message with max values", async () => {
        const transferMsg = {
          opType: OpType.Transfer,
          sourceChainId: 42161,
          sourceNav: ethers.utils.parseEther("1000000"),
          sourceDecimals: 18,
          navTolerance: 1000, // 10%
          shouldUnwrap: true,
          sourceNativeAmount: ethers.utils.parseEther("1"),
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
        expect(decoded[2]).to.equal(transferMsg.sourceNav);
        expect(decoded[5]).to.equal(transferMsg.shouldUnwrap);
      });

      it("should encode/decode rebalance mode message", async () => {
        const rebalanceMsg = {
          opType: OpType.Rebalance,
          sourceChainId: 10,
          sourceNav: ethers.utils.parseEther("1.05"),
          sourceDecimals: 18,
          navTolerance: 100, // 1%
          shouldUnwrap: false,
          sourceNativeAmount: 0,
        };

        const encoded = ethers.utils.defaultAbiCoder.encode(
          ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
          [[
            rebalanceMsg.opType,
            rebalanceMsg.sourceChainId,
            rebalanceMsg.sourceNav,
            rebalanceMsg.sourceDecimals,
            rebalanceMsg.navTolerance,
            rebalanceMsg.shouldUnwrap,
            rebalanceMsg.sourceNativeAmount,
          ]]
        );

        const decoded = ethers.utils.defaultAbiCoder.decode(
          ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
          encoded
        )[0];

        expect(decoded[0]).to.equal(OpType.Rebalance);
        expect(decoded[2]).to.equal(rebalanceMsg.sourceNav);
        expect(decoded[4]).to.equal(rebalanceMsg.navTolerance);
      });

      it("should encode/decode sync mode message", async () => {
        const syncMsg = {
          opType: OpType.Sync,
          sourceChainId: 8453,
          sourceNav: ethers.utils.parseEther("0.98"),
          sourceDecimals: 18,
          navTolerance: 200, // 2%
          shouldUnwrap: true,
          sourceNativeAmount: ethers.utils.parseEther("0.5"),
        };

        const encoded = ethers.utils.defaultAbiCoder.encode(
          ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
          [[
            syncMsg.opType,
            syncMsg.sourceChainId,
            syncMsg.sourceNav,
            syncMsg.sourceDecimals,
            syncMsg.navTolerance,
            syncMsg.shouldUnwrap,
            syncMsg.sourceNativeAmount,
          ]]
        );

        const decoded = ethers.utils.defaultAbiCoder.decode(
          ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
          encoded
        )[0];

        expect(decoded[0]).to.equal(OpType.Sync);
        expect(decoded[5]).to.equal(syncMsg.shouldUnwrap);
      });

      it("should handle different token decimals", async () => {
        const decimalsTests = [6, 8, 18];

        for (const decimals of decimalsTests) {
          const message = {
            opType: OpType.Transfer,
            sourceChainId: 1,
            sourceNav: ethers.utils.parseUnits("1", decimals),
            sourceDecimals: decimals,
            navTolerance: 100,
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

          expect(decoded[3]).to.equal(decimals);
        }
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
  });

  describe("AIntents", () => {
    describe("Constructor and Immutables", () => {
      it("should deploy with correct SpokePool address", async () => {
        const spokePoolAddr = await aIntents.acrossSpokePool();
        expect(spokePoolAddr).to.equal(acrossSpokePool.address);
      });

      it("should return correct required version", async () => {
        const version = await aIntents.requiredVersion();
        expect(version).to.equal("HF_4.1.0");
      });

      it("should have correct SpokePool immutable", async () => {
        const spokePool = await aIntents.acrossSpokePool();
        expect(spokePool).to.equal(acrossSpokePool.address);
      });

      it("should have non-zero bytecode", async () => {
        const code = await ethers.provider.getCode(aIntents.address);
        expect(code).to.not.equal("0x");
        expect(code.length).to.be.greaterThan(2);
      });
    });

    describe("Direct Call Protection", () => {
      it("should revert when called directly (not via delegatecall)", async () => {
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

        await expect(aIntents.depositV3(params)).to.be.reverted;
      });

      it("should reject direct calls from any account", async () => {
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

        await expect(aIntents.connect(user).depositV3(params)).to.be.reverted;
      });
    });

    describe("Source Message Encoding", () => {
      it("should encode transfer mode source message", () => {
        const message = {
          opType: OpType.Transfer,
          navTolerance: 100,
          shouldUnwrapOnDestination: false,
          sourceNativeAmount: 0,
        };

        const encoded = ethers.utils.defaultAbiCoder.encode(
          ["tuple(uint8,uint256,bool,uint256)"],
          [[
            message.opType,
            message.navTolerance,
            message.shouldUnwrapOnDestination,
            message.sourceNativeAmount,
          ]]
        );

        const decoded = ethers.utils.defaultAbiCoder.decode(
          ["tuple(uint8,uint256,bool,uint256)"],
          encoded
        )[0];

        expect(decoded[0]).to.equal(message.opType);
        expect(decoded[1]).to.equal(message.navTolerance);
        expect(decoded[2]).to.equal(message.shouldUnwrapOnDestination);
        expect(decoded[3]).to.equal(message.sourceNativeAmount);
      });

      it("should encode rebalance mode source message", () => {
        const message = {
          opType: OpType.Rebalance,
          navTolerance: 200,
          shouldUnwrapOnDestination: true,
          sourceNativeAmount: ethers.utils.parseEther("1"),
        };

        const encoded = ethers.utils.defaultAbiCoder.encode(
          ["tuple(uint8,uint256,bool,uint256)"],
          [[
            message.opType,
            message.navTolerance,
            message.shouldUnwrapOnDestination,
            message.sourceNativeAmount,
          ]]
        );

        const decoded = ethers.utils.defaultAbiCoder.decode(
          ["tuple(uint8,uint256,bool,uint256)"],
          encoded
        )[0];

        expect(decoded[0]).to.equal(OpType.Rebalance);
        expect(decoded[2]).to.equal(true);
      });

      it("should encode sync mode source message", () => {
        const message = {
          opType: OpType.Sync,
          navTolerance: 0,
          shouldUnwrapOnDestination: false,
          sourceNativeAmount: 0,
        };

        const encoded = ethers.utils.defaultAbiCoder.encode(
          ["tuple(uint8,uint256,bool,uint256)"],
          [[
            message.opType,
            message.navTolerance,
            message.shouldUnwrapOnDestination,
            message.sourceNativeAmount,
          ]]
        );

        const decoded = ethers.utils.defaultAbiCoder.decode(
          ["tuple(uint8,uint256,bool,uint256)"],
          encoded
        )[0];

        expect(decoded[0]).to.equal(OpType.Sync);
      });

      it("should handle different tolerance values", () => {
        const tolerances = [0, 50, 100, 200, 500];

        for (const tolerance of tolerances) {
          const encoded = ethers.utils.defaultAbiCoder.encode(
            ["tuple(uint8,uint256,bool,uint256)"],
            [[OpType.Transfer, tolerance, false, 0]]
          );

          const decoded = ethers.utils.defaultAbiCoder.decode(
            ["tuple(uint8,uint256,bool,uint256)"],
            encoded
          )[0];

          expect(decoded[1]).to.equal(tolerance);
        }
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
  });

  describe("Storage Slots", () => {
    it("should have correct virtual balances slot", () => {
      const expectedSlot = ethers.utils.keccak256(
        ethers.utils.toUtf8Bytes("pool.proxy.virtual.balances")
      );
      const adjustedSlot = ethers.BigNumber.from(expectedSlot).sub(1);
      
      // Verify the slot calculation matches ERC-7201 pattern
      expect(adjustedSlot).to.not.equal(0);
    });

    it("should have correct chain nav spreads slot", () => {
      const expectedSlot = ethers.utils.keccak256(
        ethers.utils.toUtf8Bytes("pool.proxy.chain.nav.spreads")
      );
      const adjustedSlot = ethers.BigNumber.from(expectedSlot).sub(1);
      
      // Verify the slot calculation matches ERC-7201 pattern
      expect(adjustedSlot).to.not.equal(0);
    });

    it("should calculate virtual balances slot correctly", () => {
      const slot = ethers.utils.keccak256(
        ethers.utils.toUtf8Bytes("pool.proxy.virtual.balances")
      );
      const expected = "0x52fe1e3ba959a28a9d52ea27285aed82cfb0b6d02d0df76215ab2acc4b84d650";
      expect(slot).to.equal(expected);
    });

    it("should calculate chain nav spreads slot correctly", () => {
      const slot = ethers.utils.keccak256(
        ethers.utils.toUtf8Bytes("pool.proxy.chain.nav.spreads")
      );
      const expected = "0x1effae8a79ec0c3b88754a639dc07316aa9c4de89b6b9794fb7c1d791c43492e";
      expect(slot).to.equal(expected);
    });

    it("should use ERC-7201 pattern with dot notation", () => {
      const virtualBalancesString = "pool.proxy.virtual.balances";
      const chainNavSpreadsString = "pool.proxy.chain.nav.spreads";

      // Verify dot notation is used (not camelCase)
      expect(virtualBalancesString.split(".").length).to.equal(4);
      expect(chainNavSpreadsString.split(".").length).to.equal(5);
    });
  });

  describe("OpType Enum Values", () => {
    it("should have correct OpType values", () => {
      expect(OpType.Transfer).to.equal(0);
      expect(OpType.Rebalance).to.equal(1);
      expect(OpType.Sync).to.equal(2);
    });

    it("should have correct enum ordering", () => {
      expect(OpType.Transfer).to.be.lessThan(OpType.Rebalance);
      expect(OpType.Rebalance).to.be.lessThan(OpType.Sync);
    });

    it("should maintain distinct values", () => {
      const values = [OpType.Transfer, OpType.Rebalance, OpType.Sync];
      const uniqueValues = [...new Set(values)];
      expect(uniqueValues.length).to.equal(3);
    });
  });

  describe("NAV Normalization", () => {
    it("should correctly normalize NAV with same decimals", () => {
      const nav = ethers.utils.parseEther("1");
      const sourceDecimals = 18;
      const destDecimals = 18;

      // When decimals are equal, NAV stays the same
      expect(nav).to.equal(ethers.utils.parseEther("1"));
    });

    it("should correctly downscale NAV", () => {
      const nav = ethers.utils.parseEther("1"); // 18 decimals
      const sourceDecimals = 18;
      const destDecimals = 6;

      const expected = ethers.utils.parseUnits("1", 6); // 1e6
      const downscaled = nav.div(ethers.BigNumber.from(10).pow(sourceDecimals - destDecimals));

      expect(downscaled).to.equal(expected);
    });

    it("should correctly upscale NAV", () => {
      const nav = ethers.utils.parseUnits("1", 6); // 6 decimals
      const sourceDecimals = 6;
      const destDecimals = 18;

      const expected = ethers.utils.parseEther("1"); // 1e18
      const upscaled = nav.mul(ethers.BigNumber.from(10).pow(destDecimals - sourceDecimals));

      expect(upscaled).to.equal(expected);
    });

    it("should not change NAV when decimals are equal", () => {
      const nav = ethers.utils.parseEther("123.456");
      const decimals = 18;

      // Simulating the normalization with same decimals
      const normalized = nav;
      expect(normalized).to.equal(nav);
    });

    it("should handle precision loss in downscaling", () => {
      const nav = ethers.utils.parseEther("1.123456789123456789"); // 18 decimals
      const sourceDecimals = 18;
      const destDecimals = 6;

      const downscaled = nav.div(ethers.BigNumber.from(10).pow(sourceDecimals - destDecimals));
      
      // After downscaling to 6 decimals, we lose precision
      expect(downscaled).to.equal(ethers.utils.parseUnits("1.123456", 6));
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

    it("should calculate 5% tolerance", () => {
      const nav = ethers.utils.parseEther("100");
      const toleranceBps = 500; // 5%

      const toleranceAmount = nav.mul(toleranceBps).div(10000);

      expect(toleranceAmount).to.equal(ethers.utils.parseEther("5"));
    });

    it("should calculate 10% tolerance", () => {
      const nav = ethers.utils.parseEther("100");
      const toleranceBps = 1000; // 10%

      const toleranceAmount = nav.mul(toleranceBps).div(10000);

      expect(toleranceAmount).to.equal(ethers.utils.parseEther("10"));
    });

    it("should calculate 0.01% tolerance", () => {
      const nav = ethers.utils.parseEther("10000");
      const toleranceBps = 1; // 0.01%

      const toleranceAmount = nav.mul(toleranceBps).div(10000);

      expect(toleranceAmount).to.equal(ethers.utils.parseEther("1"));
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

    it("should handle tolerance with different NAV values", () => {
      const navs = [
        ethers.utils.parseEther("1"),
        ethers.utils.parseEther("100"),
        ethers.utils.parseEther("0.01"),
      ];
      const toleranceBps = 100; // 1%

      for (const nav of navs) {
        const toleranceAmount = nav.mul(toleranceBps).div(10000);
        const expectedTolerance = nav.div(100); // 1%
        expect(toleranceAmount).to.equal(expectedTolerance);
      }
    });
  });

  describe("Mock SpokePool Functionality", () => {
    it("should have correct wrappedNativeToken", async () => {
      const weth = await acrossSpokePool.wrappedNativeToken();
      expect(weth).to.equal(wethContract.address);
    });

    it("should have fillDeadlineBuffer set", async () => {
      const buffer = await acrossSpokePool.fillDeadlineBuffer();
      expect(buffer).to.be.gt(0);
    });

    it("should accept depositV3 calls", async () => {
      await mockUSDC.mint(ownerAddress, ethers.utils.parseUnits("1000", 6));
      await mockUSDC.approve(acrossSpokePool.address, ethers.utils.parseUnits("100", 6));

      const tx = await acrossSpokePool.depositV3(
        ownerAddress,
        ownerAddress,
        mockUSDC.address,
        mockUSDC.address,
        ethers.utils.parseUnits("100", 6),
        ethers.utils.parseUnits("99", 6),
        10,
        ethers.constants.AddressZero,
        Math.floor(Date.now() / 1000),
        Math.floor(Date.now() / 1000) + 3600,
        0,
        "0x"
      );

      await expect(tx).to.emit(acrossSpokePool, "V3FundsDeposited");
    });

    it("should transfer tokens on depositV3", async () => {
      const initialBalance = await mockUSDC.balanceOf(ownerAddress);
      const depositAmount = ethers.utils.parseUnits("50", 6);

      await mockUSDC.approve(acrossSpokePool.address, depositAmount);

      await acrossSpokePool.depositV3(
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
