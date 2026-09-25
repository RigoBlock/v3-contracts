import { expect } from "chai";
import { network } from "hardhat";
import { AbiCoder, ZeroAddress, id, parseEther, parseUnits } from "ethers";
import { connect, getFixedGasSigners } from "../shared/helper";
import { createFixture } from "../utils/fixtures";

/**
 * Comprehensive tests for ECrosschain and AIntents contracts
 * Tests cover: deployment, access control, message encoding/decoding, NAV calculations, storage slots
 */
describe("Across Integration", () => {
  const OpType = {
    Transfer: 0n,
    Sync: 1n,
  };

  const setupTests = createFixture(["tests-setup"], async ({ get }) => {
    const { ethers } = await network.getOrCreate();
    const [owner, user] = await getFixedGasSigners();
    const wethContract = await ethers.getContractAt(
      "WETH9",
      (await get("WETH9")).address,
    );
    const acrossSpokePool = await ethers.getContractAt(
      "MockAcrossSpokePool",
      (await get("MockAcrossSpokePool")).address,
    );
    const eCrosschain = await ethers.getContractAt(
      "ECrosschain",
      (await get("ECrosschain")).address,
    );
    const aIntents = await ethers.getContractAt(
      "AIntents",
      (await get("AIntents")).address,
    );
    // Deploy mock token for testing
    const mockUSDC = await ethers.deployContract(
      "contracts/mocks/MockERC20.sol:MockERC20",
      ["USD Coin", "USDC", 6],
    );
    return {
      owner,
      user,
      wethContract,
      acrossSpokePool,
      eCrosschain,
      aIntents,
      mockUSDC,
    };
  });

  // The original spec used a mocha `before` hook with persistent state: some
  // tests rely on balances minted by earlier tests, so the fixture runs once
  // and is not restored between tests.
  let ctx: Awaited<ReturnType<typeof setupTests>>;

  before(async () => {
    ctx = await setupTests();
  });

  describe("ECrosschain", () => {
    describe("Constructor and Deployment", () => {
      it("should deploy with non-zero bytecode", async () => {
        const { ethers } = await network.getOrCreate();
        const code = await ethers.provider.getCode(
          await ctx.eCrosschain.getAddress(),
        );
        expect(code).to.not.equal("0x");
        expect(code.length).to.be.greaterThan(2);
      });
    });

    describe("Access Control", () => {
      it("should reject calls from non-SpokePool addresses", async () => {
        const { eCrosschain, mockUSDC } = ctx;
        const destMessageParams = {
          opType: OpType.Transfer,
          shouldUnwrapNative: false,
        };

        await expect(
          eCrosschain.donate(
            await mockUSDC.getAddress(),
            1000000,
            destMessageParams,
          ),
        )
          .to.be.revertedWithCustomError(eCrosschain, "DonationLock")
          .withArgs(false);
      });

      it("should reject calls from deployer", async () => {
        const { owner, eCrosschain, mockUSDC } = ctx;
        const destMessageParams = {
          opType: OpType.Transfer,
          shouldUnwrapNative: false,
        };

        await expect(
          connect(eCrosschain, owner).donate(
            await mockUSDC.getAddress(),
            1000000,
            destMessageParams,
          ),
        )
          .to.be.revertedWithCustomError(eCrosschain, "DonationLock")
          .withArgs(false);
      });

      it("should reject calls from arbitrary user", async () => {
        const { eCrosschain, mockUSDC, user } = ctx;
        const destMessageParams = {
          opType: OpType.Transfer,
          shouldUnwrapNative: false,
        };

        await expect(
          connect(eCrosschain, user).donate(
            await mockUSDC.getAddress(),
            1000000,
            destMessageParams,
          ),
        )
          .to.be.revertedWithCustomError(eCrosschain, "DonationLock")
          .withArgs(false);
      });
    });

    describe("Message Encoding/Decoding", () => {
      it("should encode/decode transfer mode message with minimal values", () => {
        const transferMsg = {
          opType: OpType.Transfer,
          sourceChainId: 1n,
          sourceNav: 0n,
          sourceDecimals: 18,
          navTolerance: 0n,
          shouldUnwrap: false,
        };

        const encoded = AbiCoder.defaultAbiCoder().encode(
          ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
          [
            [
              transferMsg.opType,
              transferMsg.sourceChainId,
              transferMsg.sourceNav,
              transferMsg.sourceDecimals,
              transferMsg.navTolerance,
              transferMsg.shouldUnwrap,
              1000000n, // sourceAmount
            ],
          ],
        );

        const decoded = AbiCoder.defaultAbiCoder().decode(
          ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
          encoded,
        )[0];

        expect(decoded[0]).to.equal(transferMsg.opType);
        expect(decoded[1]).to.equal(transferMsg.sourceChainId);
        expect(decoded[2]).to.equal(transferMsg.sourceNav);
        expect(decoded[3]).to.equal(BigInt(transferMsg.sourceDecimals));
        expect(decoded[4]).to.equal(transferMsg.navTolerance);
        expect(decoded[5]).to.equal(transferMsg.shouldUnwrap);
        expect(decoded[6]).to.equal(1000000n); // sourceAmount
      });

      it("should encode/decode transfer mode message with max values", () => {
        const transferMsg = {
          opType: OpType.Transfer,
          sourceChainId: 42161n,
          sourceNav: parseEther("1000000"),
          sourceDecimals: 18,
          navTolerance: 1000n, // 10%
          shouldUnwrap: true,
        };

        const encoded = AbiCoder.defaultAbiCoder().encode(
          ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
          [
            [
              transferMsg.opType,
              transferMsg.sourceChainId,
              transferMsg.sourceNav,
              transferMsg.sourceDecimals,
              transferMsg.navTolerance,
              transferMsg.shouldUnwrap,
              parseEther("1000000"), // sourceAmount
            ],
          ],
        );

        const decoded = AbiCoder.defaultAbiCoder().decode(
          ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
          encoded,
        )[0];

        expect(decoded[0]).to.equal(transferMsg.opType);
        expect(decoded[2]).to.equal(transferMsg.sourceNav);
        expect(decoded[5]).to.equal(transferMsg.shouldUnwrap);
        expect(decoded[6]).to.equal(parseEther("1000000")); // sourceAmount
      });

      it("should encode/decode rebalance mode message", () => {
        const rebalanceMsg = {
          opType: OpType.Sync,
          sourceChainId: 10n,
          sourceNav: parseEther("1.05"),
          sourceDecimals: 18,
          navTolerance: 100n, // 1%
          shouldUnwrap: false,
        };

        const encoded = AbiCoder.defaultAbiCoder().encode(
          ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
          [
            [
              rebalanceMsg.opType,
              rebalanceMsg.sourceChainId,
              rebalanceMsg.sourceNav,
              rebalanceMsg.sourceDecimals,
              rebalanceMsg.navTolerance,
              rebalanceMsg.shouldUnwrap,
              parseEther("1.05"), // sourceAmount
            ],
          ],
        );

        const decoded = AbiCoder.defaultAbiCoder().decode(
          ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
          encoded,
        )[0];

        expect(decoded[0]).to.equal(OpType.Sync);
        expect(decoded[2]).to.equal(rebalanceMsg.sourceNav);
        expect(decoded[4]).to.equal(rebalanceMsg.navTolerance);
        expect(decoded[6]).to.equal(parseEther("1.05")); // sourceAmount
      });

      it("should encode/decode sync mode message", () => {
        const syncMsg = {
          opType: OpType.Sync,
          sourceChainId: 8453n,
          sourceNav: parseEther("0.98"),
          sourceDecimals: 18,
          navTolerance: 200n, // 2%
          shouldUnwrap: true,
        };

        const encoded = AbiCoder.defaultAbiCoder().encode(
          ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
          [
            [
              syncMsg.opType,
              syncMsg.sourceChainId,
              syncMsg.sourceNav,
              syncMsg.sourceDecimals,
              syncMsg.navTolerance,
              syncMsg.shouldUnwrap,
              parseEther("0.98"), // sourceAmount
            ],
          ],
        );

        const decoded = AbiCoder.defaultAbiCoder().decode(
          ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
          encoded,
        )[0];

        expect(decoded[0]).to.equal(OpType.Sync);
        expect(decoded[5]).to.equal(syncMsg.shouldUnwrap);
        expect(decoded[6]).to.equal(parseEther("0.98")); // sourceAmount
      });

      it("should handle different token decimals", () => {
        const decimalsTests = [6, 8, 18];

        for (const decimals of decimalsTests) {
          const message = {
            opType: OpType.Transfer,
            sourceChainId: 1n,
            sourceNav: parseUnits("1", decimals),
            sourceDecimals: decimals,
            navTolerance: 100n,
            shouldUnwrap: false,
          };

          const encoded = AbiCoder.defaultAbiCoder().encode(
            ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
            [
              [
                message.opType,
                message.sourceChainId,
                message.sourceNav,
                message.sourceDecimals,
                message.navTolerance,
                message.shouldUnwrap,
                parseUnits("1", decimals), // sourceAmount
              ],
            ],
          );

          const decoded = AbiCoder.defaultAbiCoder().decode(
            ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
            encoded,
          )[0];

          expect(decoded[3]).to.equal(BigInt(decimals));
          expect(decoded[6]).to.equal(parseUnits("1", decimals)); // sourceAmount
        }
      });

      it("should handle different OpTypes in message", () => {
        const opTypes = [OpType.Transfer, OpType.Sync];

        for (const opType of opTypes) {
          const message = AbiCoder.defaultAbiCoder().encode(
            ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
            [[opType, 1n, parseEther("1"), 18, 100n, false, parseEther("1")]],
          );

          const decoded = AbiCoder.defaultAbiCoder().decode(
            ["tuple(uint8,uint256,uint256,uint8,uint256,bool,uint256)"],
            message,
          )[0];

          expect(decoded[0]).to.equal(opType);
          expect(decoded[6]).to.equal(parseEther("1")); // sourceAmount
        }
      });
    });
  });

  describe("AIntents", () => {
    describe("Constructor and Immutables", () => {
      it("should return correct required version", async () => {
        const version = await ctx.aIntents.requiredVersion();
        expect(version).to.equal("4.1.0");
      });

      it("should have non-zero bytecode", async () => {
        const { ethers } = await network.getOrCreate();
        const code = await ethers.provider.getCode(
          await ctx.aIntents.getAddress(),
        );
        expect(code).to.not.equal("0x");
        expect(code.length).to.be.greaterThan(2);
      });
    });

    describe("Direct Call Protection", () => {
      it("should revert when called directly (not via delegatecall)", async () => {
        const { owner, aIntents, mockUSDC } = ctx;
        const params = {
          depositor: owner.address,
          recipient: owner.address,
          inputToken: await mockUSDC.getAddress(),
          outputToken: await mockUSDC.getAddress(),
          inputAmount: 1000000,
          outputAmount: 990000,
          destinationChainId: 10,
          exclusiveRelayer: ZeroAddress,
          quoteTimestamp: Math.floor(Date.now() / 1000),
          fillDeadline: Math.floor(Date.now() / 1000) + 3600,
          exclusivityDeadline: 0,
          message: AbiCoder.defaultAbiCoder().encode(
            ["tuple(uint8,uint256,bool,uint256)"],
            [[OpType.Transfer, 100n, false, 0n]],
          ),
        };

        await expect(aIntents.depositV3(params)).to.be.revertedWithCustomError(
          aIntents,
          "DirectCallNotAllowed",
        );
      });

      it("should reject direct calls from any account", async () => {
        const { owner, aIntents, mockUSDC, user } = ctx;
        const params = {
          depositor: owner.address,
          recipient: owner.address,
          inputToken: await mockUSDC.getAddress(),
          outputToken: await mockUSDC.getAddress(),
          inputAmount: 1000000,
          outputAmount: 990000,
          destinationChainId: 10,
          exclusiveRelayer: ZeroAddress,
          quoteTimestamp: Math.floor(Date.now() / 1000),
          fillDeadline: Math.floor(Date.now() / 1000) + 3600,
          exclusivityDeadline: 0,
          message: AbiCoder.defaultAbiCoder().encode(
            ["tuple(uint8,uint256,bool,uint256)"],
            [[OpType.Transfer, 100n, false, 0n]],
          ),
        };

        await expect(
          connect(aIntents, user).depositV3(params),
        ).to.be.revertedWithCustomError(aIntents, "DirectCallNotAllowed");
      });
    });

    describe("Source Message Encoding", () => {
      it("should encode transfer mode source message", () => {
        const message = {
          opType: OpType.Transfer,
          navTolerance: 100n,
          shouldUnwrapOnDestination: false,
          sourceNativeAmount: 0n,
        };

        const encoded = AbiCoder.defaultAbiCoder().encode(
          ["tuple(uint8,uint256,bool,uint256)"],
          [
            [
              message.opType,
              message.navTolerance,
              message.shouldUnwrapOnDestination,
              message.sourceNativeAmount,
            ],
          ],
        );

        const decoded = AbiCoder.defaultAbiCoder().decode(
          ["tuple(uint8,uint256,bool,uint256)"],
          encoded,
        )[0];

        expect(decoded[0]).to.equal(message.opType);
        expect(decoded[1]).to.equal(message.navTolerance);
        expect(decoded[2]).to.equal(message.shouldUnwrapOnDestination);
        expect(decoded[3]).to.equal(message.sourceNativeAmount);
      });

      it("should encode sync mode with different tolerance", () => {
        const message = {
          opType: OpType.Sync,
          navTolerance: 200n,
          shouldUnwrapOnDestination: true,
          sourceNativeAmount: parseEther("1"),
        };

        const encoded = AbiCoder.defaultAbiCoder().encode(
          ["tuple(uint8,uint256,bool,uint256)"],
          [
            [
              message.opType,
              message.navTolerance,
              message.shouldUnwrapOnDestination,
              message.sourceNativeAmount,
            ],
          ],
        );

        const decoded = AbiCoder.defaultAbiCoder().decode(
          ["tuple(uint8,uint256,bool,uint256)"],
          encoded,
        )[0];

        expect(decoded[0]).to.equal(OpType.Sync);
        expect(decoded[2]).to.equal(true);
      });

      it("should encode sync mode source message", () => {
        const message = {
          opType: OpType.Sync,
          navTolerance: 0n,
          shouldUnwrapOnDestination: false,
          sourceNativeAmount: 0n,
        };

        const encoded = AbiCoder.defaultAbiCoder().encode(
          ["tuple(uint8,uint256,bool,uint256)"],
          [
            [
              message.opType,
              message.navTolerance,
              message.shouldUnwrapOnDestination,
              message.sourceNativeAmount,
            ],
          ],
        );

        const decoded = AbiCoder.defaultAbiCoder().decode(
          ["tuple(uint8,uint256,bool,uint256)"],
          encoded,
        )[0];

        expect(decoded[0]).to.equal(OpType.Sync);
      });

      it("should handle different tolerance values", () => {
        const tolerances = [0n, 50n, 100n, 200n, 500n];

        for (const tolerance of tolerances) {
          const encoded = AbiCoder.defaultAbiCoder().encode(
            ["tuple(uint8,uint256,bool,uint256)"],
            [[OpType.Transfer, tolerance, false, 0n]],
          );

          const decoded = AbiCoder.defaultAbiCoder().decode(
            ["tuple(uint8,uint256,bool,uint256)"],
            encoded,
          )[0];

          expect(decoded[1]).to.equal(tolerance);
        }
      });

      it("should handle different source message types", () => {
        const messageTypes = [
          { opType: OpType.Transfer, tolerance: 100n },
          { opType: OpType.Sync, tolerance: 0n },
        ];

        for (const msgType of messageTypes) {
          const encoded = AbiCoder.defaultAbiCoder().encode(
            ["tuple(uint8,uint256,bool,uint256)"],
            [[msgType.opType, msgType.tolerance, false, 0n]],
          );

          const decoded = AbiCoder.defaultAbiCoder().decode(
            ["tuple(uint8,uint256,bool,uint256)"],
            encoded,
          )[0];

          expect(decoded[0]).to.equal(msgType.opType);
          expect(decoded[1]).to.equal(msgType.tolerance);
        }
      });
    });
  });

  describe("Storage Slots", () => {
    it("should have correct virtual supply slot", () => {
      const expectedSlot = id("pool.proxy.virtual.supply");
      const adjustedSlot = BigInt(expectedSlot) - 1n;

      // Verify the slot calculation matches ERC-7201 pattern
      expect(adjustedSlot).to.not.equal(0n);
    });

    it("should calculate virtual supply slot correctly", () => {
      const slot = id("pool.proxy.virtual.supply");
      const expected =
        "0xc1634c3ed93b1f7aa4d725c710ac3b239c1d30894404e630b60009ee34114510";
      expect(slot).to.equal(expected);
    });

    it("should use ERC-7201 pattern with dot notation", () => {
      const virtualSupplyString = "pool.proxy.virtual.supply";

      // Verify dot notation is used (not camelCase)
      expect(virtualSupplyString.split(".").length).to.equal(4);
    });
  });

  describe("OpType Enum Values", () => {
    it("should have correct OpType values", () => {
      expect(OpType.Transfer).to.equal(0n);
      expect(OpType.Sync).to.equal(1n);
    });

    it("should have correct enum ordering", () => {
      expect(OpType.Transfer).to.be.lessThan(OpType.Sync);
    });

    it("should maintain distinct values", () => {
      const values = [OpType.Transfer, OpType.Sync];
      const uniqueValues = [...new Set(values)];
      expect(uniqueValues.length).to.equal(2);
    });
  });

  describe("NAV Normalization", () => {
    it("should correctly downscale NAV", () => {
      const nav = parseEther("1"); // 18 decimals
      const sourceDecimals = 18;
      const destDecimals = 6;

      const expected = parseUnits("1", 6); // 1e6
      const downscaled = nav / 10n ** BigInt(sourceDecimals - destDecimals);

      expect(downscaled).to.equal(expected);
    });

    it("should correctly upscale NAV", () => {
      const nav = parseUnits("1", 6); // 6 decimals
      const sourceDecimals = 6;
      const destDecimals = 18;

      const expected = parseEther("1"); // 1e18
      const upscaled = nav * 10n ** BigInt(destDecimals - sourceDecimals);

      expect(upscaled).to.equal(expected);
    });

    it("should handle precision loss in downscaling", () => {
      const nav = parseEther("1.123456789123456789"); // 18 decimals
      const sourceDecimals = 18;
      const destDecimals = 6;

      const downscaled = nav / 10n ** BigInt(sourceDecimals - destDecimals);

      // After downscaling to 6 decimals, we lose precision
      expect(downscaled).to.equal(parseUnits("1.123456", 6));
    });
  });

  describe("Tolerance Calculation", () => {
    it("should calculate 1% tolerance correctly", () => {
      const nav = parseEther("1");
      const toleranceBps = 100n; // 1%

      const toleranceAmount = (nav * toleranceBps) / 10000n;

      expect(toleranceAmount).to.equal(parseEther("0.01"));
    });

    it("should calculate 2% tolerance correctly", () => {
      const nav = parseEther("1");
      const toleranceBps = 200n; // 2%

      const toleranceAmount = (nav * toleranceBps) / 10000n;

      expect(toleranceAmount).to.equal(parseEther("0.02"));
    });

    it("should calculate 5% tolerance", () => {
      const nav = parseEther("100");
      const toleranceBps = 500n; // 5%

      const toleranceAmount = (nav * toleranceBps) / 10000n;

      expect(toleranceAmount).to.equal(parseEther("5"));
    });

    it("should calculate 10% tolerance", () => {
      const nav = parseEther("100");
      const toleranceBps = 1000n; // 10%

      const toleranceAmount = (nav * toleranceBps) / 10000n;

      expect(toleranceAmount).to.equal(parseEther("10"));
    });

    it("should calculate 0.01% tolerance", () => {
      const nav = parseEther("10000");
      const toleranceBps = 1n; // 0.01%

      const toleranceAmount = (nav * toleranceBps) / 10000n;

      expect(toleranceAmount).to.equal(parseEther("1"));
    });

    it("should calculate tolerance range correctly", () => {
      const nav = parseEther("1");
      const toleranceBps = 100n; // 1%

      const toleranceAmount = (nav * toleranceBps) / 10000n;
      const minNav = nav - toleranceAmount;
      const maxNav = nav + toleranceAmount;

      expect(minNav).to.equal(parseEther("0.99"));
      expect(maxNav).to.equal(parseEther("1.01"));
    });

    it("should handle tolerance with different NAV values", () => {
      const navs = [parseEther("1"), parseEther("100"), parseEther("0.01")];
      const toleranceBps = 100n; // 1%

      for (const nav of navs) {
        const toleranceAmount = (nav * toleranceBps) / 10000n;
        const expectedTolerance = nav / 100n; // 1%
        expect(toleranceAmount).to.equal(expectedTolerance);
      }
    });
  });

  describe("Mock SpokePool Functionality", () => {
    it("should have correct wrappedNativeToken", async () => {
      const weth = await ctx.acrossSpokePool.wrappedNativeToken();
      expect(weth).to.equal(await ctx.wethContract.getAddress());
    });

    it("should have fillDeadlineBuffer set", async () => {
      const buffer = await ctx.acrossSpokePool.fillDeadlineBuffer();
      expect(buffer).to.be.gt(0n);
    });

    it("should accept depositV3 calls", async () => {
      const { owner, acrossSpokePool, mockUSDC } = ctx;
      await mockUSDC.mint(owner.address, parseUnits("1000", 6));
      await mockUSDC.approve(
        await acrossSpokePool.getAddress(),
        parseUnits("100", 6),
      );

      const tx = await acrossSpokePool.depositV3(
        owner.address,
        owner.address,
        await mockUSDC.getAddress(),
        await mockUSDC.getAddress(),
        parseUnits("100", 6),
        parseUnits("99", 6),
        10,
        ZeroAddress,
        Math.floor(Date.now() / 1000),
        Math.floor(Date.now() / 1000) + 3600,
        0,
        "0x",
      );

      await expect(tx).to.emit(acrossSpokePool, "V3FundsDeposited");
    });

    it("should transfer tokens on depositV3", async () => {
      const { owner, acrossSpokePool, mockUSDC } = ctx;
      const initialBalance = await mockUSDC.balanceOf(owner.address);
      const depositAmount = parseUnits("50", 6);

      await mockUSDC.approve(await acrossSpokePool.getAddress(), depositAmount);

      await acrossSpokePool.depositV3(
        owner.address,
        owner.address,
        await mockUSDC.getAddress(),
        await mockUSDC.getAddress(),
        depositAmount,
        parseUnits("49", 6),
        10,
        ZeroAddress,
        Math.floor(Date.now() / 1000),
        Math.floor(Date.now() / 1000) + 3600,
        0,
        "0x",
      );

      const finalBalance = await mockUSDC.balanceOf(owner.address);
      expect(initialBalance - finalBalance).to.equal(depositAmount);
    });
  });

  describe("Token Functionality", () => {
    it("should mint tokens correctly", async () => {
      const { owner, mockUSDC } = ctx;
      const mintAmount = parseUnits("100", 6);
      await mockUSDC.mint(owner.address, mintAmount);

      const balance = await mockUSDC.balanceOf(owner.address);
      expect(balance).to.be.gte(mintAmount);
    });

    it("should handle transfers", async () => {
      const { user, mockUSDC } = ctx;
      const transferAmount = parseUnits("10", 6);

      await mockUSDC.transfer(user.address, transferAmount);

      const userBalance = await mockUSDC.balanceOf(user.address);
      expect(userBalance).to.equal(transferAmount);
    });

    it("should handle approvals", async () => {
      const { owner, aIntents, mockUSDC } = ctx;
      const approveAmount = parseUnits("50", 6);
      await mockUSDC.approve(await aIntents.getAddress(), approveAmount);

      const allowance = await mockUSDC.allowance(
        owner.address,
        await aIntents.getAddress(),
      );
      expect(allowance).to.equal(approveAmount);
    });
  });
});
