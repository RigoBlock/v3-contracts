import { expect } from "chai";
import { network } from "hardhat";
import { MaxUint256, parseEther, toBeHex, ZeroAddress } from "ethers";
import {
  CONTRACT_BALANCE,
  DEADLINE,
  MAX_UINT128,
  MAX_UINT160,
} from "../shared/constants";
import { Actions, V4Planner } from "../shared/v4Planner";
import { CommandType, RoutePlanner } from "../shared/planner";
import {
  encodeMultihopExactInPath,
  encodeMultihopExactOutPath,
  encodePath,
  FeeAmount,
} from "../utils/path";
import { timeTravel } from "../utils/utils";
import { getFixedGasSigners } from "../shared/helper";
import { createFixture } from "../utils/fixtures";

const getExtPool = async (poolAddress: string) => {
  const { ethers } = await network.getOrCreate();
  return ethers.getContractAt("AUniswapRouter", poolAddress);
};

describe("AUniswapRouter", async () => {
  const MAX_TICK_SPACING = 32767;
  const DEFAULT_PAIR = {
    poolKey: {
      currency0: ZeroAddress,
      currency1: ZeroAddress,
      fee: 0,
      tickSpacing: MAX_TICK_SPACING,
      hooks: ZeroAddress,
    },
    price: "1282621508889261311518273674430423",
    tickLower: 193800,
    tickUpper: 193900,
  };

  const setupTests = createFixture(["tests-setup"], async ({ get }) => {
    const [user1, user2] = await getFixedGasSigners();
    const { ethers } = await network.getOrCreate();
    const factory = await ethers.getContractAt(
      "RigoblockPoolProxyFactory",
      (await get("RigoblockPoolProxyFactory")).address,
    );
    const grgToken = await ethers.getContractAt(
      "RigoToken",
      (await get("RigoToken")).address,
    );
    const authority = await ethers.getContractAt(
      "Authority",
      (await get("Authority")).address,
    );
    const createPoolResult = await factory.createPool.staticCall(
      "testpool",
      "TEST",
      ZeroAddress,
    );
    const newPoolAddress = createPoolResult[0];
    const poolId = createPoolResult[1];
    await factory.createPool("testpool", "TEST", ZeroAddress);
    const pool = await ethers.getContractAt("SmartPool", newPoolAddress);
    const uniswapV3Npm = await ethers.getContractAt(
      "MockUniswapNpm",
      (await get("MockUniswapNpm")).address,
    );
    const univ4Posm = await ethers.getContractAt(
      "MockUniswapPosm",
      (await get("MockUniswapPosm")).address,
    );
    const uniRouter = await ethers.deployContract("MockUniUniversalRouter", [
      await univ4Posm.getAddress(),
    ]);
    const wethAddress = await uniswapV3Npm.WETH9();
    const aUniswapRouter = await ethers.deployContract("AUniswapRouter", [
      await uniRouter.getAddress(),
      await univ4Posm.getAddress(),
      wethAddress,
    ]);
    await authority.setAdapter(await aUniswapRouter.getAddress(), true);
    // "3593564c": "execute(bytes calldata, bytes[] calldata, uint256)"
    // "24856bc3": "execute(bytes calldata, bytes[] calldata)"
    // "dd46508f": "modifyLiquidities(bytes calldata, uint256)"
    await authority.addMethod("0x3593564c", await aUniswapRouter.getAddress());
    await authority.addMethod("0x24856bc3", await aUniswapRouter.getAddress());
    await authority.addMethod("0xdd46508f", await aUniswapRouter.getAddress());
    const oracle = await ethers.getContractAt(
      "MockOracle",
      (await get("MockOracle")).address,
    );
    const permit2 = await ethers.getContractAt(
      "MockPermit2",
      (await get("MockPermit2")).address,
    );
    return {
      grgToken,
      grgTokenAddress: await grgToken.getAddress(),
      pool,
      newPoolAddress,
      poolId,
      univ4Posm,
      univ4PosmAddress: await univ4Posm.getAddress(),
      wethAddress,
      aUniswapRouter,
      aUniswapRouterAddress: await aUniswapRouter.getAddress(),
      uniRouter,
      uniRouterAddress: await uniRouter.getAddress(),
      hookAddress: (await get("MockOracle")).address,
      oracle,
      oracleAddress: await oracle.getAddress(),
      permit2,
      permit2Address: await permit2.getAddress(),
      user1,
      user2,
    };
  });

  // TODO: verify if should avoid direct calls to aUniswapRouter, or there are no side-effects (has write access to storage)
  describe("modifyLiquidities", async () => {
    it("should route to uniV4Posm", async () => {
      const {
        pool,
        newPoolAddress,
        univ4Posm,
        wethAddress,
        oracle,
        oracleAddress,
        user1,
      } = await setupTests();
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency0: ZeroAddress,
          currency1: wethAddress,
          fee: 0,
          tickSpacing: MAX_TICK_SPACING,
          hooks: oracleAddress,
        },
      };
      await oracle.initializeObservations(PAIR.poolKey);
      PAIR.poolKey.hooks = ZeroAddress;
      const v4Planner: V4Planner = new V4Planner();
      const nativeAmount = parseEther("1");
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower,
        PAIR.tickUpper,
        1, // liquidity
        nativeAmount,
        MAX_UINT128,
        newPoolAddress,
        "0x", // hookData
      ]);
      v4Planner.addAction(Actions.SETTLE_PAIR, [
        PAIR.poolKey.currency0,
        PAIR.poolKey.currency1,
      ]);
      // tokens are taken from the pool, so value is always 0
      const value = parseEther("0");
      // the mock posm does not move funds from the pool, so we can send before pool has balance
      const extPool = await getExtPool(newPoolAddress);
      await expect(
        extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value }),
      ).to.be.revertedWithCustomError(extPool, "InsufficientNativeBalance");
      const etherAmount = parseEther("12");
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount });
      await expect(
        extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value }),
      )
        .to.emit(pool, "TokenStatusChanged")
        .withArgs(wethAddress, true)
        .and.to.emit(extPool, "UniV4PositionAdded")
        .withArgs(1n);
      // first mint does not prompt nav calculations, so lp tokens are not included in active tokens
      let activeTokens = (await pool.getActiveTokens()).activeTokens;
      expect(activeTokens.length).to.be.eq(1);
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount });
      activeTokens = (await pool.getActiveTokens()).activeTokens;
      // second mint will prompt nav calculations, and lp tokens are not added to active tokens again
      expect(activeTokens.length).to.be.eq(1);
      expect(await univ4Posm.nextTokenId()).to.be.eq(2n);
      expect(await univ4Posm.balanceOf(newPoolAddress)).to.be.eq(1n);
      // will execute and not remove any token
      await pool.purgeInactiveTokensAndApps();
      activeTokens = (await pool.getActiveTokens()).activeTokens;
      // token is not removed, as it is returned by the posm
      expect(activeTokens.length).to.be.eq(1);
    });

    it("should mint 2 positions in the same call", async () => {
      const { newPoolAddress, univ4Posm, wethAddress, user1 } =
        await setupTests();
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency1: wethAddress,
        },
      };
      const v4Planner: V4Planner = new V4Planner();
      const maxAmountOut = parseEther("1");
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower,
        PAIR.tickUpper,
        1, // liquidity
        maxAmountOut,
        MAX_UINT128,
        newPoolAddress,
        "0x", // hookData
      ]);
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower + 1,
        PAIR.tickUpper - 1,
        1, // liquidity
        maxAmountOut,
        MAX_UINT128,
        newPoolAddress,
        "0x", // hookData
      ]);
      // tokens are taken from the pool, so value is always 0
      const value = parseEther("0");
      // the mock posm does not move funds from the pool, so we can send before pool has balance
      const extPool = await getExtPool(newPoolAddress);
      // minting 2 positions using eth as one of the tokens requires transferring eth to the uniswap router
      await user1.sendTransaction({
        to: newPoolAddress,
        value: parseEther("2"),
      });
      const tx = await extPool.modifyLiquidities(
        v4Planner.finalize(),
        MAX_UINT160,
        { value },
      );
      const receipt = await tx.wait();
      const addedEvents =
        receipt.logs?.filter(
          (e: any) => e.fragment?.name === "UniV4PositionAdded",
        ) ?? [];
      expect(addedEvents.length).to.be.eq(2);
      expect(addedEvents[0].args?.tokenId).to.be.eq(1n);
      expect(addedEvents[1].args?.tokenId).to.be.eq(2n);
      expect(await univ4Posm.nextTokenId()).to.be.eq(3n);
      expect(await univ4Posm.balanceOf(newPoolAddress)).to.be.eq(2n);
    });

    it("should revert if position recipient is not pool", async () => {
      const { newPoolAddress, wethAddress, user1 } = await setupTests();
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency1: wethAddress,
        },
      };
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower,
        PAIR.tickUpper,
        1, // liquidity
        MAX_UINT128,
        MAX_UINT128,
        user1.address,
        "0x", // hookData
      ]);
      // tokens are taken from the pool, so value is always 0
      const value = parseEther("0");
      // the mock posm does not move funds from the pool, so we can send before pool has balance
      const extPool = await getExtPool(newPoolAddress);
      await expect(
        extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value }),
      ).to.be.revertedWithCustomError(extPool, "RecipientNotSmartPoolOrRouter");
    });

    it("should revert mint if a token does not have a price feed", async () => {
      const {
        pool,
        newPoolAddress,
        grgTokenAddress,
        wethAddress,
        oracle,
        oracleAddress,
        user1,
      } = await setupTests();
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency0: grgTokenAddress,
          currency1: wethAddress,
          fee: 0,
          tickSpacing: MAX_TICK_SPACING,
          hooks: ZeroAddress,
        },
      };
      const etherAmount = parseEther("12");
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower,
        PAIR.tickUpper,
        1, // liquidity
        etherAmount,
        MAX_UINT128,
        newPoolAddress,
        "0x", // hookData
      ]);
      const value = parseEther("0");
      const extPool = await getExtPool(newPoolAddress);
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount });
      await expect(
        extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value }),
      )
        .to.be.revertedWithCustomError(extPool, "TokenPriceFeedDoesNotExist")
        .withArgs(grgTokenAddress);
      PAIR.poolKey.hooks = oracleAddress;
      PAIR.poolKey.currency0 = ZeroAddress;
      PAIR.poolKey.currency1 = grgTokenAddress;
      await oracle.initializeObservations(PAIR.poolKey);
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, {
        value,
      });
    });

    // Notice: the adapter uses the hook address's bitmask to check if the hook can access the liquidity deltas
    it("should revert if hook can access liquidity deltas", async () => {
      const { pool, newPoolAddress, wethAddress, user1 } = await setupTests();

      // Mock an address with Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG (0x08) and Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG (0x04)
      // Combined flags: 0x02 | 0x01 = 0x03 (binary: 00000011)
      const hookAddress = "0x0000000000000000000000000000000000000003";

      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency0: ZeroAddress,
          currency1: wethAddress,
          fee: 0,
          tickSpacing: MAX_TICK_SPACING,
          hooks: hookAddress,
        },
      };
      const etherAmount = parseEther("12");
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower,
        PAIR.tickUpper,
        1, // liquidity
        etherAmount,
        MAX_UINT128,
        newPoolAddress,
        "0x", // hookData
      ]);
      const value = parseEther("0");
      const extPool = await getExtPool(newPoolAddress);
      const { spread } = await pool.getPoolParams();
      const markup = (etherAmount * spread) / (10000n - spread);
      await pool.mint(user1.address, etherAmount + markup, 1, {
        value: etherAmount + markup,
      });
      await expect(
        extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value }),
      )
        .to.be.revertedWithCustomError(extPool, "LiquidityMintHookError")
        .withArgs(hookAddress);
    });

    it("should not be able to increase liquidity of non-owned position", async () => {
      const {
        pool,
        newPoolAddress,
        univ4Posm,
        wethAddress,
        oracle,
        oracleAddress,
        user1,
      } = await setupTests();
      const etherAmount = parseEther("12");
      const { spread } = await pool.getPoolParams();
      const markup = (etherAmount * spread) / (10000n - spread);
      await pool.mint(user1.address, etherAmount + markup, 1, {
        value: etherAmount + markup,
      });
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency0: ZeroAddress,
          currency1: wethAddress,
          fee: 0,
          tickSpacing: MAX_TICK_SPACING,
          hooks: oracleAddress,
        },
      };
      await oracle.initializeObservations(PAIR.poolKey);
      PAIR.poolKey.hooks = ZeroAddress;
      const expectedTokenId = await univ4Posm.nextTokenId();
      let v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower,
        PAIR.tickUpper,
        1, // liquidity
        etherAmount,
        MAX_UINT128,
        user1.address,
        "0x", // hookData
      ]);
      // mint the token from user1, so the pool is not the owner
      await univ4Posm.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, {
        value: 0,
      });
      v4Planner = new V4Planner();
      v4Planner.addAction(Actions.INCREASE_LIQUIDITY, [
        expectedTokenId,
        "6000000",
        etherAmount,
        MAX_UINT128,
        "0x",
      ]);
      // tokens are taken from the pool, so value is always 0
      const value = parseEther("0");
      // the mock posm does not move funds from the pool, so we can send before pool has balance
      const extPool = await getExtPool(newPoolAddress);
      // adding liquidity to a non-owned position reverts without error, just a simple assertion is implemented
      await expect(
        extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value }),
      ).to.be.revertedWithCustomError(extPool, "PositionOwner");
    });

    it("should not allow mint and increase liquidity in same call", async () => {
      const {
        pool,
        newPoolAddress,
        univ4Posm,
        wethAddress,
        oracle,
        oracleAddress,
        user1,
      } = await setupTests();
      const etherAmount = parseEther("12");
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount });
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency0: ZeroAddress,
          currency1: wethAddress,
          fee: 0,
          tickSpacing: MAX_TICK_SPACING,
          hooks: oracleAddress,
        },
      };
      await oracle.initializeObservations(PAIR.poolKey);
      PAIR.poolKey.hooks = ZeroAddress;
      const expectedTokenId = await univ4Posm.nextTokenId();
      let v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower,
        PAIR.tickUpper,
        10001, // liquidity
        etherAmount / 2n,
        MAX_UINT128,
        newPoolAddress,
        "0x", // hookData
      ]);
      v4Planner.addAction(Actions.INCREASE_LIQUIDITY, [
        expectedTokenId,
        "6000000",
        etherAmount / 2n,
        MAX_UINT128,
        "0x",
      ]);
      // tokens are taken from the pool, so value is always 0
      const value = parseEther("0");
      // the mock posm does not move funds from the pool, so we can send before pool has balance
      const extPool = await getExtPool(newPoolAddress);
      await expect(
        extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value }),
      ).to.be.revertedWithCustomError(extPool, "PositionDoesNotExist");
    });

    it("should increase liquidity", async () => {
      const {
        pool,
        newPoolAddress,
        univ4Posm,
        wethAddress,
        oracle,
        oracleAddress,
        user1,
      } = await setupTests();
      const etherAmount = parseEther("12");
      const { spread } = await pool.getPoolParams();
      const markup = (etherAmount * spread) / (10000n - spread);
      await pool.mint(user1.address, etherAmount + markup, 1, {
        value: etherAmount + markup,
      });
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency0: ZeroAddress,
          currency1: wethAddress,
          fee: 0,
          tickSpacing: MAX_TICK_SPACING,
          hooks: oracleAddress,
        },
      };
      await oracle.initializeObservations(PAIR.poolKey);
      PAIR.poolKey.hooks = ZeroAddress;
      const expectedTokenId = await univ4Posm.nextTokenId();
      let v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower,
        PAIR.tickUpper,
        10001, // liquidity
        etherAmount / 2n,
        MAX_UINT128,
        newPoolAddress,
        "0x", // hookData
      ]);
      // tokens are taken from the pool, so value is always 0
      const value = parseEther("0");
      // the mock posm does not move funds from the pool, so we can send before pool has balance
      const extPool = await getExtPool(newPoolAddress);
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, {
        value,
      });
      v4Planner = new V4Planner();
      v4Planner.addAction(Actions.INCREASE_LIQUIDITY, [
        expectedTokenId,
        "6000000",
        etherAmount / 2n,
        MAX_UINT128,
        "0x",
      ]);
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, {
        value,
      });
      expect(await univ4Posm.nextTokenId()).to.be.eq(2n);
      expect(await univ4Posm.balanceOf(newPoolAddress)).to.be.eq(1n);
      expect(await univ4Posm.ownerOf(expectedTokenId)).to.be.eq(newPoolAddress);
      expect(await univ4Posm.getPositionLiquidity(expectedTokenId)).to.be.eq(
        10001n + 6000000n,
      );
    });

    it("should remove liquidity", async () => {
      const {
        pool,
        newPoolAddress,
        univ4Posm,
        wethAddress,
        oracle,
        oracleAddress,
        user1,
      } = await setupTests();
      const etherAmount = parseEther("12");
      const { spread } = await pool.getPoolParams();
      const markup = (etherAmount * spread) / (10000n - spread);
      await pool.mint(user1.address, etherAmount + markup, 1, {
        value: etherAmount + markup,
      });
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency0: ZeroAddress,
          currency1: wethAddress,
          fee: 0,
          tickSpacing: MAX_TICK_SPACING,
          hooks: oracleAddress,
        },
      };
      await oracle.initializeObservations(PAIR.poolKey);
      PAIR.poolKey.hooks = ZeroAddress;
      const expectedTokenId = await univ4Posm.nextTokenId();
      let v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower,
        PAIR.tickUpper,
        10001, // liquidity
        etherAmount / 2n,
        MAX_UINT128,
        newPoolAddress,
        "0x", // hookData
      ]);
      const value = parseEther("0");
      const extPool = await getExtPool(newPoolAddress);
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, {
        value,
      });
      v4Planner = new V4Planner();
      v4Planner.addAction(Actions.INCREASE_LIQUIDITY, [
        expectedTokenId,
        "6000000",
        etherAmount / 2n,
        MAX_UINT128,
        "0x",
      ]);
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, {
        value,
      });
      // clear state for actions
      v4Planner = new V4Planner();
      v4Planner.addAction(Actions.DECREASE_LIQUIDITY, [
        expectedTokenId,
        "1200000",
        MAX_UINT128,
        MAX_UINT128,
        "0x",
      ]);
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, {
        value,
      });
      expect(await univ4Posm.getPositionLiquidity(expectedTokenId)).to.be.eq(
        10001n + 6000000n - 1200000n,
      );
    });

    it("should burn owned position", async () => {
      const {
        pool,
        newPoolAddress,
        univ4Posm,
        wethAddress,
        oracle,
        oracleAddress,
        user1,
      } = await setupTests();
      const etherAmount = parseEther("12");
      const { spread } = await pool.getPoolParams();
      const markup = (etherAmount * spread) / (10000n - spread);
      await pool.mint(user1.address, etherAmount + markup, 1, {
        value: etherAmount + markup,
      });
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency0: ZeroAddress,
          currency1: wethAddress,
          fee: 0,
          tickSpacing: MAX_TICK_SPACING,
          hooks: oracleAddress,
        },
      };
      await oracle.initializeObservations(PAIR.poolKey);
      PAIR.poolKey.hooks = ZeroAddress;
      const expectedTokenId = await univ4Posm.nextTokenId();
      let v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower,
        PAIR.tickUpper,
        10001, // liquidity
        etherAmount / 2n,
        MAX_UINT128,
        newPoolAddress,
        "0x", // hookData
      ]);
      const value = parseEther("0");
      const extPool = await getExtPool(newPoolAddress);
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, {
        value,
      });
      v4Planner = new V4Planner();
      v4Planner.addAction(Actions.INCREASE_LIQUIDITY, [
        expectedTokenId,
        "6000000",
        etherAmount / 2n,
        MAX_UINT128,
        "0x",
      ]);
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, {
        value,
      });
      const { ethers } = await network.getOrCreate();
      const positionPool = await ethers.getContractAt("EApps", newPoolAddress);
      expect((await positionPool.getUniV4TokenIds()).length).to.be.eq(1);
      // clear state for actions
      v4Planner = new V4Planner();
      // burn will remove any position liquidity in Posm
      v4Planner.addAction(Actions.BURN_POSITION, [
        expectedTokenId,
        MAX_UINT128,
        MAX_UINT128,
        "0x",
      ]);
      await expect(
        extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value }),
      )
        .to.emit(extPool, "UniV4PositionRemoved")
        .withArgs(expectedTokenId);
      expect(await univ4Posm.getPositionLiquidity(expectedTokenId)).to.be.eq(
        0n,
      );
      expect((await positionPool.getUniV4TokenIds()).length).to.be.eq(0);
    });

    it("should burn tokenId at a specific position", async () => {
      const {
        pool,
        newPoolAddress,
        univ4Posm,
        wethAddress,
        oracle,
        oracleAddress,
        user1,
      } = await setupTests();
      const etherAmount = parseEther("12");
      const { spread } = await pool.getPoolParams();
      const markup = (etherAmount * spread) / (10000n - spread);
      await pool.mint(user1.address, etherAmount + markup, 1, {
        value: etherAmount + markup,
      });
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency0: ZeroAddress,
          currency1: wethAddress,
          fee: 0,
          tickSpacing: MAX_TICK_SPACING,
          hooks: oracleAddress,
        },
      };
      await oracle.initializeObservations(PAIR.poolKey);
      PAIR.poolKey.hooks = ZeroAddress;
      const expectedTokenId = await univ4Posm.nextTokenId();
      let v4Planner: V4Planner = new V4Planner();
      let mintParams = [
        PAIR.poolKey,
        PAIR.tickLower,
        PAIR.tickUpper,
        10001,
        etherAmount / 3n,
        MAX_UINT128,
        newPoolAddress,
        "0x",
      ];
      v4Planner.addAction(Actions.MINT_POSITION, mintParams);
      mintParams = [
        PAIR.poolKey,
        PAIR.tickLower,
        PAIR.tickUpper - 1,
        10001,
        etherAmount / 3n,
        MAX_UINT128,
        newPoolAddress,
        "0x",
      ];
      v4Planner.addAction(Actions.MINT_POSITION, mintParams);
      mintParams = [
        PAIR.poolKey,
        PAIR.tickLower,
        PAIR.tickUpper - 2,
        10001,
        etherAmount / 3n,
        MAX_UINT128,
        newPoolAddress,
        "0x",
      ];
      v4Planner.addAction(Actions.MINT_POSITION, mintParams);
      const value = parseEther("0");
      const extPool = await getExtPool(newPoolAddress);
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, {
        value,
      });
      const { ethers } = await network.getOrCreate();
      const positionPool = await ethers.getContractAt("EApps", newPoolAddress);
      expect((await positionPool.getUniV4TokenIds()).length).to.be.eq(3);
      // clear state for actions
      v4Planner = new V4Planner();
      // burn will remove any position liquidity in Posm
      v4Planner.addAction(Actions.BURN_POSITION, [
        expectedTokenId,
        MAX_UINT128,
        MAX_UINT128,
        "0x",
      ]);
      await expect(
        extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value }),
      )
        .to.emit(extPool, "UniV4PositionRemoved")
        .withArgs(expectedTokenId);
      expect(await univ4Posm.getPositionLiquidity(expectedTokenId)).to.be.eq(
        0n,
      );
      const remainingIds = await positionPool.getUniV4TokenIds();
      expect(remainingIds.length).to.be.eq(2);

      // Verify remaining tokenIds are actual Uniswap position IDs (not corrupted array indices).
      // The burned position (expectedTokenId) was first in the array, so swap-and-pop should
      // move the last tokenId into its slot. Both remaining entries must be valid token IDs
      // (i.e. expectedTokenId+1 and expectedTokenId+2), not small index numbers.
      const expectedRemaining = [expectedTokenId + 2n, expectedTokenId + 1n];
      expect(remainingIds[0]).to.be.eq(expectedRemaining[0]);
      expect(remainingIds[1]).to.be.eq(expectedRemaining[1]);
    });

    it("position should be included in nav calculations", async () => {
      const {
        newPoolAddress,
        grgTokenAddress,
        pool,
        univ4Posm,
        wethAddress,
        oracle,
        oracleAddress,
        user1,
      } = await setupTests();
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency0: ZeroAddress,
          currency1: grgTokenAddress,
          fee: 0,
          tickSpacing: MAX_TICK_SPACING,
          hooks: oracleAddress,
        },
      };
      await oracle.initializeObservations(PAIR.poolKey);
      PAIR.poolKey = {
        currency0: ZeroAddress,
        currency1: wethAddress,
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: oracleAddress,
      };
      await oracle.initializeObservations(PAIR.poolKey);
      PAIR.poolKey.currency0 = grgTokenAddress;
      PAIR.poolKey.hooks = ZeroAddress;
      const expectedTokenId = await univ4Posm.nextTokenId();
      let v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower,
        PAIR.tickUpper,
        10001, // liquidity
        MAX_UINT128,
        MAX_UINT128,
        newPoolAddress,
        "0x", // hookData
      ]);
      const value = parseEther("0");
      const extPool = await getExtPool(newPoolAddress);
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, {
        value,
      });
      v4Planner = new V4Planner();
      // TODO: verify if it is correct that small numbers of liquidity are not affecting nav calculations
      // we must add enough liquidity, otherwise the position will be too small to affect nav calculations
      v4Planner.addAction(Actions.INCREASE_LIQUIDITY, [
        expectedTokenId,
        parseEther("2"),
        MAX_UINT128,
        MAX_UINT128,
        "0x",
      ]);
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, {
        value,
      });
      const { ethers } = await network.getOrCreate();
      const positionsPool = await ethers.getContractAt("EApps", newPoolAddress);
      expect((await positionsPool.getUniV4TokenIds()).length).to.be.eq(1);
      expect(await univ4Posm.nextTokenId()).to.be.eq(2n);
      const etherAmount = parseEther("12");
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount });
      const poolPriceBefore = (await pool.getPoolTokens()).unitaryValue;
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount });
      expect((await pool.getActiveTokens()).activeTokens.length).to.be.eq(2);
      // technically, this does not happen in real world, where pool tokens are used and should not inflate it. But we return mock values from the test posm.
      const poolPriceAfter = (await pool.getPoolTokens()).unitaryValue;
      expect(poolPriceAfter).to.be.gt(poolPriceBefore);
      expect(poolPriceAfter).to.be.eq(parseEther("1.000000050507717064"));
    });

    it("should decode payment methods", async () => {
      const {
        pool,
        newPoolAddress,
        grgTokenAddress,
        wethAddress,
        oracle,
        oracleAddress,
        user1,
      } = await setupTests();
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency0: ZeroAddress,
          currency1: grgTokenAddress,
          fee: 0,
          tickSpacing: MAX_TICK_SPACING,
          hooks: oracleAddress,
        },
      };
      await oracle.initializeObservations(PAIR.poolKey);
      PAIR.poolKey.currency1 = wethAddress;
      await oracle.initializeObservations(PAIR.poolKey);
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.SETTLE_PAIR, [grgTokenAddress, wethAddress]);
      v4Planner.addAction(Actions.TAKE_PAIR, [
        grgTokenAddress,
        wethAddress,
        newPoolAddress,
      ]);
      v4Planner.addAction(Actions.SETTLE, [
        grgTokenAddress,
        parseEther("12"),
        true,
      ]);
      v4Planner.addAction(Actions.SETTLE, [
        ZeroAddress,
        parseEther("12"),
        false,
      ]);
      v4Planner.addAction(Actions.SETTLE, [
        ZeroAddress,
        parseEther("0.1"),
        true,
      ]);
      v4Planner.addAction(Actions.TAKE, [
        wethAddress,
        newPoolAddress,
        parseEther("12"),
      ]);
      v4Planner.addAction(Actions.CLEAR_OR_TAKE, [grgTokenAddress, 0]);
      v4Planner.addAction(Actions.SWEEP, [wethAddress, newPoolAddress]);
      v4Planner.addAction(Actions.WRAP, [parseEther("1")]);
      v4Planner.addAction(Actions.UNWRAP, [parseEther("1")]);
      // tokens are taken from the pool, so value is always 0
      const value = parseEther("0");
      // the mock posm does not move funds from the pool, so we can send before pool has balance
      const extPool = await getExtPool(newPoolAddress);
      // ETH transfer fails with custom error when pool does not have enough balance
      await expect(
        extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value }),
      ).to.be.revertedWithCustomError(extPool, "InsufficientNativeBalance");
      const etherAmount = parseEther("13.1"); // settle 12 + 0.1 + 1 (wrap)
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount });
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, {
        value,
      });
    });

    it("should decode WRAP with CONTRACT_BALANCE flag without overflow", async () => {
      const { newPoolAddress, wethAddress, oracle, oracleAddress } =
        await setupTests();
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency0: ZeroAddress,
          currency1: wethAddress,
          fee: 0,
          tickSpacing: MAX_TICK_SPACING,
          hooks: oracleAddress,
        },
      };
      await oracle.initializeObservations(PAIR.poolKey);
      // WRAP with CONTRACT_BALANCE sentinel should not add to params.value (resolved at execution time)
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.WRAP, [CONTRACT_BALANCE]);
      const extPool = await getExtPool(newPoolAddress);
      // Should succeed with value=0 since CONTRACT_BALANCE is skipped in value computation
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, {
        value: 0,
      });
    });

    it("should revert when calling unsupported methods", async () => {
      const { newPoolAddress } = await setupTests();
      let v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.INCREASE_LIQUIDITY_FROM_DELTAS, [
        0,
        0,
        0,
        "0x",
      ]);
      const extPool = await getExtPool(newPoolAddress);
      await expect(
        extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, {
          value: 0,
        }),
      )
        .to.be.revertedWithCustomError(extPool, "UnsupportedAction")
        .withArgs(BigInt(Actions.INCREASE_LIQUIDITY_FROM_DELTAS));
      v4Planner = new V4Planner();
      v4Planner.addAction(Actions.MINT_POSITION_FROM_DELTAS, [
        [ZeroAddress, ZeroAddress, 0, 0, ZeroAddress],
        0,
        0,
        0,
        0,
        ZeroAddress,
        "0x",
      ]);
      await expect(
        extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, {
          value: 0,
        }),
      )
        .to.be.revertedWithCustomError(extPool, "UnsupportedAction")
        .withArgs(BigInt(Actions.MINT_POSITION_FROM_DELTAS));
    });

    it("should decode CLOSE_CURRENCY action", async () => {
      const {
        newPoolAddress,
        wethAddress,
        grgTokenAddress,
        oracle,
        oracleAddress,
      } = await setupTests();
      // Initialize price feed so the token used in CLOSE_CURRENCY passes oracle validation
      const PAIR = { ...DEFAULT_PAIR };
      PAIR.poolKey = {
        currency0: ZeroAddress,
        currency1: wethAddress,
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: oracleAddress,
      };
      await oracle.initializeObservations(PAIR.poolKey);
      const extPool = await getExtPool(newPoolAddress);
      // CLOSE_CURRENCY is supported — decoded and forwarded to POSM. Test with a non-native token
      // to verify oracle validation works for any currency (not just base token).
      let v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.CLOSE_CURRENCY, [wethAddress]);
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, {
        value: 0,
      });
      // also verify native ETH works (always has price feed as base token)
      v4Planner = new V4Planner();
      v4Planner.addAction(Actions.CLOSE_CURRENCY, [ZeroAddress]);
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, {
        value: 0,
      });
      // token without price feed should revert
      v4Planner = new V4Planner();
      v4Planner.addAction(Actions.CLOSE_CURRENCY, [grgTokenAddress]);
      await expect(
        extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, {
          value: 0,
        }),
      )
        .to.be.revertedWithCustomError(extPool, "TokenPriceFeedDoesNotExist")
        .withArgs(grgTokenAddress);
    });

    it("should propagate string error from posm", async () => {
      const { newPoolAddress, wethAddress, oracle, oracleAddress, univ4Posm } =
        await setupTests();
      const PAIR = { ...DEFAULT_PAIR };
      PAIR.poolKey = {
        currency0: ZeroAddress,
        currency1: wethAddress,
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: oracleAddress,
      };
      await oracle.initializeObservations(PAIR.poolKey);
      const extPool = await getExtPool(newPoolAddress);
      // use CLOSE_CURRENCY with no native value to avoid InsufficientNativeBalance check
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.CLOSE_CURRENCY, [wethAddress]);
      // set mock to revert with string error
      await univ4Posm.setRevertMode(1);
      await expect(
        extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, {
          value: 0,
        }),
      ).to.be.revertedWith("MockPosmStringError");
      // reset revert mode
      await univ4Posm.setRevertMode(0);
    });

    it("should propagate custom error from posm", async () => {
      const { newPoolAddress, wethAddress, oracle, oracleAddress, univ4Posm } =
        await setupTests();
      const PAIR = { ...DEFAULT_PAIR };
      PAIR.poolKey = {
        currency0: ZeroAddress,
        currency1: wethAddress,
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: oracleAddress,
      };
      await oracle.initializeObservations(PAIR.poolKey);
      const extPool = await getExtPool(newPoolAddress);
      // use CLOSE_CURRENCY with no native value to avoid InsufficientNativeBalance check
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.CLOSE_CURRENCY, [wethAddress]);
      // set mock to revert with custom error
      await univ4Posm.setRevertMode(2);
      await expect(
        extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, {
          value: 0,
        }),
      )
        .to.be.revertedWithCustomError(univ4Posm, "MockCustomError")
        .withArgs("MockPosmCustomError");
      // reset revert mode
      await univ4Posm.setRevertMode(0);
    });

    it("returns gas cost for eth pool mint with 1 uni v4 liquidity position", async () => {
      const {
        pool,
        newPoolAddress,
        univ4Posm,
        wethAddress,
        grgTokenAddress,
        oracle,
        oracleAddress,
        user1,
      } = await setupTests();
      const etherAmount = parseEther("12");
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency0: ZeroAddress,
          currency1: wethAddress,
          fee: 0,
          tickSpacing: MAX_TICK_SPACING,
          hooks: oracleAddress,
        },
      };
      await oracle.initializeObservations(PAIR.poolKey);
      // reset hook to default state
      PAIR.poolKey.hooks = ZeroAddress;
      PAIR.poolKey.currency1 = wethAddress;
      const expectedTokenId = await univ4Posm.nextTokenId();
      let v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower,
        PAIR.tickUpper,
        10001, // liquidity
        etherAmount / 2n,
        MAX_UINT128,
        newPoolAddress,
        "0x", // hookData
      ]);
      const value = parseEther("0");
      const extPool = await getExtPool(newPoolAddress);
      await expect(
        extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value }),
      ).to.be.revertedWithCustomError(extPool, "InsufficientNativeBalance");
      let txReceipt = await pool.mint(user1.address, etherAmount, 1, {
        value: etherAmount,
      });
      let result = await txReceipt.wait();
      let gasCost = Number(result.cumulativeGasUsed);
      console.log(gasCost, "first mint gas cost");
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, {
        value,
      });
      v4Planner = new V4Planner();
      v4Planner.addAction(Actions.INCREASE_LIQUIDITY, [
        expectedTokenId,
        parseEther("2"),
        etherAmount / 2n,
        MAX_UINT128,
        "0x",
      ]);
      txReceipt = await pool.mint(user1.address, etherAmount, 1, {
        value: etherAmount,
      });
      result = await txReceipt.wait();
      gasCost = Number(result.cumulativeGasUsed);
      console.log(gasCost, "second mint gas cost, with no position");
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, {
        value,
      });
      txReceipt = await pool.mint(user1.address, etherAmount, 1, {
        value: etherAmount,
      });
      result = await txReceipt.wait();
      gasCost = Number(result.cumulativeGasUsed);
      console.log(gasCost, "third mint gas cost, with 1 position");
      txReceipt = await pool.mint(user1.address, etherAmount, 1, {
        value: etherAmount,
      });
      result = await txReceipt.wait();
      gasCost = Number(result.cumulativeGasUsed);
      console.log(gasCost, "fourth mint gas cost, with 1 position");
      v4Planner = new V4Planner();
      // mint a different tokenIds with same tokens
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower - 500,
        PAIR.tickUpper - 500,
        10001, // liquidity
        etherAmount / 2n,
        MAX_UINT128,
        newPoolAddress,
        "0x", // hookData
      ]);
      v4Planner.addAction(Actions.INCREASE_LIQUIDITY, [
        expectedTokenId,
        parseEther("2"),
        etherAmount / 2n,
        MAX_UINT128,
        "0x",
      ]);
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, {
        value,
      });
      txReceipt = await pool.mint(user1.address, etherAmount, 1, {
        value: etherAmount,
      });
      result = await txReceipt.wait();
      gasCost = Number(result.cumulativeGasUsed);
      console.log(gasCost, "5th mint gas cost, with 2 positions");
      txReceipt = await pool.mint(user1.address, etherAmount, 1, {
        value: etherAmount,
      });
      result = await txReceipt.wait();
      gasCost = Number(result.cumulativeGasUsed);
      console.log(gasCost, "6th mint gas cost, with 2 positions");
      await timeTravel({ days: 30 });
      txReceipt = await pool.burn(etherAmount, 1);
      result = await txReceipt.wait();
      gasCost = Number(result.cumulativeGasUsed);
      console.log(gasCost, "burn gas cost, with 2 positions");
      v4Planner = new V4Planner();
      // we add a new token on top of a new position
      PAIR.poolKey.currency1 = grgTokenAddress;
      await oracle.initializeObservations(PAIR.poolKey);
      // mint a different tokenIds with same tokens
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower + 500,
        PAIR.tickUpper + 500,
        10001, // liquidity
        etherAmount / 2n,
        MAX_UINT128,
        newPoolAddress,
        "0x", // hookData
      ]);
      // need to take currency1 to activate token in storage
      v4Planner.addAction(Actions.TAKE, [
        PAIR.poolKey.currency1,
        newPoolAddress,
        parseEther("12"),
      ]);
      txReceipt = await pool.mint(user1.address, etherAmount, 1, {
        value: etherAmount,
      });
      result = await txReceipt.wait();
      gasCost = Number(result.cumulativeGasUsed);
      // TODO: gas cost has not increased, but it should, as we have a new position and 1 more token
      console.log(
        gasCost,
        "7th mint gas cost, with 3 positions and an additional token",
      );
    });
  });

  describe("execute", async () => {
    it("should execute a v4 swap", async () => {
      const { pool, newPoolAddress, wethAddress, user1 } = await setupTests();
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency0: ZeroAddress,
          currency1: wethAddress,
        },
      };
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.SWAP_EXACT_IN_SINGLE, [
        {
          poolKey: PAIR.poolKey,
          zeroForOne: true,
          amountIn: parseEther("12"),
          amountOutMinimum: parseEther("22"),
          hookData: "0x",
        },
      ]);
      v4Planner.addAction(Actions.SETTLE, [
        PAIR.poolKey.currency0,
        parseEther("12"),
        true,
      ]);
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.V4_SWAP, [
        v4Planner.actions,
        v4Planner.params,
      ]);
      const { commands, inputs } = planner;
      const extPool = await getExtPool(newPoolAddress);
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        }),
      ).to.be.revertedWithCustomError(extPool, "InsufficientNativeBalance");
      // mint more that the swap amount because the spread tokens are sent to the burn contract
      const tokenAmount = parseEther("12");
      const { spread } = await pool.getPoolParams();
      const markup = (tokenAmount * spread) / (10000n - spread);
      await pool.mint(user1.address, tokenAmount + markup, 1, {
        value: tokenAmount + markup,
      });
      try {
        await user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        });
      } catch (error: any) {
        const customError =
          error.error?.reason || error.reason || error.message;
        throw new Error(`${customError}`);
      }
    });

    it("should revert if deadline past", async () => {
      const { newPoolAddress, wethAddress, user1 } = await setupTests();
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency1: wethAddress,
        },
      };
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.SWAP_EXACT_IN_SINGLE, [
        {
          poolKey: PAIR.poolKey,
          zeroForOne: true,
          amountIn: parseEther("12"),
          amountOutMinimum: parseEther("22"),
          hookData: "0x",
        },
      ]);
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.V4_SWAP, [
        v4Planner.actions,
        v4Planner.params,
      ]);
      const { commands, inputs } = planner;
      const extPool = await getExtPool(newPoolAddress);
      await timeTravel({ seconds: DEADLINE + 1, mine: true });
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        }),
      ).to.be.revertedWithCustomError(extPool, "TransactionDeadlinePassed");
    });

    it("should set approval with settle action", async () => {
      const {
        grgToken,
        newPoolAddress,
        grgTokenAddress,
        permit2,
        permit2Address,
        uniRouterAddress,
        user1,
      } = await setupTests();
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency0: grgTokenAddress,
        },
      };
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.SWAP_EXACT_IN_SINGLE, [
        {
          poolKey: PAIR.poolKey,
          zeroForOne: true,
          amountIn: parseEther("12"),
          amountOutMinimum: parseEther("22"),
          hookData: "0x",
        },
      ]);
      v4Planner.addAction(Actions.SETTLE, [
        PAIR.poolKey.currency0,
        parseEther("12"),
        true,
      ]);
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.V4_SWAP, [
        v4Planner.actions,
        v4Planner.params,
      ]);
      const { commands, inputs } = planner;
      const extPool = await getExtPool(newPoolAddress);
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );
      expect(await grgToken.allowance(newPoolAddress, permit2Address)).to.be.eq(
        0n,
      );
      const tx = await user1.sendTransaction({
        to: newPoolAddress,
        value: 0,
        data: encodedSwapData,
      });
      const receipt = await tx.wait();
      if (receipt === null) throw new Error("transaction receipt is null");
      const { ethers } = await network.getOrCreate();
      const block = await ethers.provider.getBlock(receipt.blockNumber);
      // rigoblock sets max approval to permit2, then sets permit2 approval with expity = 0, so approval is valid only for duration of transaction
      expect(await grgToken.allowance(newPoolAddress, permit2Address)).to.be.eq(
        MaxUint256,
      );
      const permit2Allowace = await permit2.allowance(
        newPoolAddress,
        grgTokenAddress,
        uniRouterAddress,
      );
      // Define uint160 max: 2^160 - 1
      const maxUint160 = 1461501637330902918203684832716283019655932542975n;
      expect(permit2Allowace.amount).to.be.eq(maxUint160);
      expect(permit2Allowace.expiration).to.be.eq(BigInt(block!.timestamp));
      expect(permit2Allowace.nonce).to.be.eq(0);
      // NOTE: we must reset the currency0 to the default value, as the next test otherwise will revert (even though it should be reset, but for some reason it is not)
      PAIR.poolKey.currency0 = ZeroAddress;
    });

    it("should transfer eth to universal router with exactInSingle", async () => {
      const { pool, newPoolAddress, grgTokenAddress, uniRouterAddress, user1 } =
        await setupTests();
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency1: grgTokenAddress,
        },
      };
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.SWAP_EXACT_IN_SINGLE, [
        {
          poolKey: PAIR.poolKey,
          zeroForOne: true,
          amountIn: parseEther("12"),
          amountOutMinimum: parseEther("22"),
          hookData: "0x",
        },
      ]);
      // as SETTLE may be used with flag amount instead of actual amount, value is transferred with exactIn action
      //v4Planner.addAction(Actions.SETTLE, [PAIR.poolKey.currency0, parseEther("12"), true])
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.V4_SWAP, [
        v4Planner.actions,
        v4Planner.params,
      ]);
      const { commands, inputs } = planner;
      const extPool = await getExtPool(newPoolAddress);
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );
      const { ethers } = await network.getOrCreate();
      expect(await ethers.provider.getBalance(uniRouterAddress)).to.be.eq(
        parseEther("0"),
      );
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        }),
      ).to.be.revertedWithCustomError(extPool, "InsufficientNativeBalance");
      const tokenAmount = parseEther("12");
      const { spread } = await pool.getPoolParams();
      const markup = (tokenAmount * spread) / (10000n - spread);
      await pool.mint(user1.address, tokenAmount + markup, 1, {
        value: tokenAmount + markup,
      });
      try {
        await user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        });
      } catch (error: any) {
        const customError =
          error.error?.reason || error.reason || error.message;
        throw new Error(`${customError}`);
      }
      // expect universal router to have received eth
      expect(await ethers.provider.getBalance(uniRouterAddress)).to.be.eq(
        parseEther("12"),
      );
    });

    it("should transfer eth to universal router with exactIn", async () => {
      const { pool, newPoolAddress, grgTokenAddress, uniRouterAddress, user1 } =
        await setupTests();
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency1: grgTokenAddress,
        },
      };
      const currencyIn = PAIR.poolKey.currency0;
      const amountInNative = parseEther("12");
      const minAmountOutToken = parseEther("22");
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.SWAP_EXACT_IN, [
        {
          currencyIn,
          path: encodeMultihopExactInPath([PAIR.poolKey], currencyIn),
          amountIn: amountInNative,
          amountOutMinimum: minAmountOutToken,
        },
      ]);
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.V4_SWAP, [
        v4Planner.actions,
        v4Planner.params,
      ]);
      const { commands, inputs } = planner;
      const extPool = await getExtPool(newPoolAddress);
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );
      const { ethers } = await network.getOrCreate();
      expect(await ethers.provider.getBalance(uniRouterAddress)).to.be.eq(
        parseEther("0"),
      );
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        }),
      ).to.be.revertedWithCustomError(extPool, "InsufficientNativeBalance");
      const { spread } = await pool.getPoolParams();
      const markup = (amountInNative * spread) / (10000n - spread);
      await pool.mint(user1.address, amountInNative + markup, 1, {
        value: amountInNative + markup,
      });
      try {
        await user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        });
      } catch (error: any) {
        const customError =
          error.error?.reason || error.reason || error.message;
        throw new Error(`${customError}`);
      }
      // expect universal router to have received eth
      expect(await ethers.provider.getBalance(uniRouterAddress)).to.be.eq(
        parseEther("12"),
      );
    });

    it("should not transfer eth to universal router with exactIn when selling token for native", async () => {
      const { newPoolAddress, grgTokenAddress, uniRouterAddress, user1 } =
        await setupTests();
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency1: grgTokenAddress,
        },
      };
      const currencyIn = PAIR.poolKey.currency1;
      const amountInNative = parseEther("12");
      const minAmountOutToken = parseEther("22");
      const v4Planner: V4Planner = new V4Planner();
      // the following swap would revert in uniswap, as pair.poolKey.currency0 has not been inverted, but we want to make sure ETH is not transferred
      v4Planner.addAction(Actions.SWAP_EXACT_IN, [
        {
          currencyIn,
          path: encodeMultihopExactInPath([PAIR.poolKey], currencyIn),
          amountIn: amountInNative,
          amountOutMinimum: minAmountOutToken,
        },
      ]);
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.V4_SWAP, [
        v4Planner.actions,
        v4Planner.params,
      ]);
      const { commands, inputs } = planner;
      const extPool = await getExtPool(newPoolAddress);
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );
      const { ethers } = await network.getOrCreate();
      expect(await ethers.provider.getBalance(uniRouterAddress)).to.be.eq(
        parseEther("0"),
      );
      try {
        await user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        });
      } catch (error: any) {
        const customError =
          error.error?.reason || error.reason || error.message;
        throw new Error(`${customError}`);
      }
      // expect universal router to have received eth
      expect(await ethers.provider.getBalance(uniRouterAddress)).to.be.eq(
        parseEther("0"),
      );
    });

    it("should transfer eth to universal router with exactOutSingle", async () => {
      const { pool, newPoolAddress, grgTokenAddress, uniRouterAddress, user1 } =
        await setupTests();
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency1: grgTokenAddress,
        },
      };
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.SWAP_EXACT_OUT_SINGLE, [
        {
          poolKey: PAIR.poolKey,
          zeroForOne: true,
          amountOut: parseEther("12"),
          amountInMaximum: parseEther("22"),
          hookData: "0x",
        },
      ]);
      // as SETTLE may be used with flag amount instead of actual amount, value is transferred with exactOut action
      //v4Planner.addAction(Actions.SETTLE, [PAIR.poolKey.currency0, parseEther("12"), true])
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.V4_SWAP, [
        v4Planner.actions,
        v4Planner.params,
      ]);
      const { commands, inputs } = planner;
      const extPool = await getExtPool(newPoolAddress);
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );
      const { ethers } = await network.getOrCreate();
      expect(await ethers.provider.getBalance(uniRouterAddress)).to.be.eq(
        parseEther("0"),
      );
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        }),
      ).to.be.revertedWithCustomError(extPool, "InsufficientNativeBalance");
      // markup must be applied to the amount transferred
      const etherAmount = parseEther("22");
      const { spread } = await pool.getPoolParams();
      const markup = (etherAmount * spread) / (10000n - spread);
      await pool.mint(user1.address, etherAmount + markup, 1, {
        value: etherAmount + markup,
      });
      try {
        await user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        });
      } catch (error: any) {
        const customError =
          error.error?.reason || error.reason || error.message;
        throw new Error(`${customError}`);
      }
      // expect universal router to have received eth
      expect(await ethers.provider.getBalance(uniRouterAddress)).to.be.eq(
        parseEther("22"),
      );
    });

    it("should not transfer eth to universal router with exactOutSingle if currencyOut is native", async () => {
      const { newPoolAddress, grgTokenAddress, uniRouterAddress, user1 } =
        await setupTests();
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency1: grgTokenAddress,
        },
      };
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.SWAP_EXACT_OUT_SINGLE, [
        {
          poolKey: PAIR.poolKey,
          zeroForOne: false,
          amountOut: parseEther("12"),
          amountInMaximum: parseEther("22"),
          hookData: "0x",
        },
      ]);
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.V4_SWAP, [
        v4Planner.actions,
        v4Planner.params,
      ]);
      const { commands, inputs } = planner;
      const extPool = await getExtPool(newPoolAddress);
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );
      const { ethers } = await network.getOrCreate();
      expect(await ethers.provider.getBalance(uniRouterAddress)).to.be.eq(
        parseEther("0"),
      );
      try {
        await user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        });
      } catch (error: any) {
        const customError =
          error.error?.reason || error.reason || error.message;
        throw new Error(`${customError}`);
      }
      expect(await ethers.provider.getBalance(uniRouterAddress)).to.be.eq(
        parseEther("0"),
      );
    });

    it("should transfer eth to universal router with exactOut", async () => {
      const { pool, newPoolAddress, grgTokenAddress, uniRouterAddress, user1 } =
        await setupTests();
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency1: grgTokenAddress,
        },
      };
      const currencyOut = PAIR.poolKey.currency1;
      const amountOutToken = parseEther("12");
      const maxAmountInNative = parseEther("22");
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.SWAP_EXACT_OUT, [
        {
          currencyOut,
          path: encodeMultihopExactOutPath([PAIR.poolKey], currencyOut),
          amountOut: amountOutToken,
          amountInMaximum: maxAmountInNative,
        },
      ]);
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.V4_SWAP, [
        v4Planner.actions,
        v4Planner.params,
      ]);
      const { commands, inputs } = planner;
      const extPool = await getExtPool(newPoolAddress);
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );
      const { ethers } = await network.getOrCreate();
      expect(await ethers.provider.getBalance(uniRouterAddress)).to.be.eq(
        parseEther("0"),
      );
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        }),
      ).to.be.revertedWithCustomError(extPool, "InsufficientNativeBalance");
      // markup must be applied to the amount transferred
      const { spread } = await pool.getPoolParams();
      const markup = (maxAmountInNative * spread) / (10000n - spread);
      const transferAmount = maxAmountInNative + markup;
      await pool.mint(user1.address, transferAmount, 1, {
        value: transferAmount,
      });
      try {
        await user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        });
      } catch (error: any) {
        const customError =
          error.error?.reason || error.reason || error.message;
        throw new Error(`${customError}`);
      }
      // expect universal router to have received eth
      expect(await ethers.provider.getBalance(uniRouterAddress)).to.be.eq(
        parseEther("22"),
      );
    });

    it("should not transfer eth to universal router with exactOut if currencyOut is native", async () => {
      const { newPoolAddress, grgTokenAddress, uniRouterAddress, user1 } =
        await setupTests();
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency1: grgTokenAddress,
        },
      };
      const currencyOut = PAIR.poolKey.currency0;
      const amountOutNative = parseEther("12");
      const maxAmountInToken = parseEther("22");
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.SWAP_EXACT_OUT, [
        {
          currencyOut,
          path: encodeMultihopExactOutPath([PAIR.poolKey], currencyOut),
          amountOut: amountOutNative,
          amountInMaximum: maxAmountInToken,
        },
      ]);
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.V4_SWAP, [
        v4Planner.actions,
        v4Planner.params,
      ]);
      const { commands, inputs } = planner;
      const extPool = await getExtPool(newPoolAddress);
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );
      const { ethers } = await network.getOrCreate();
      expect(await ethers.provider.getBalance(uniRouterAddress)).to.be.eq(
        parseEther("0"),
      );
      try {
        await user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        });
      } catch (error: any) {
        const customError =
          error.error?.reason || error.reason || error.message;
        throw new Error(`${customError}`);
      }
      expect(await ethers.provider.getBalance(uniRouterAddress)).to.be.eq(
        parseEther("0"),
      );
    });

    it("should revert if recipient is not pool", async () => {
      const { newPoolAddress, grgTokenAddress, user1, user2 } =
        await setupTests();
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency1: grgTokenAddress,
        },
      };
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.TAKE, [
        PAIR.poolKey.currency0,
        user2.address,
        parseEther("12"),
      ]);
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.V4_SWAP, [
        v4Planner.actions,
        v4Planner.params,
      ]);
      const { commands, inputs } = planner;
      const extPool = await getExtPool(newPoolAddress);
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        }),
      ).to.be.revertedWithCustomError(extPool, "RecipientNotSmartPoolOrRouter");
    });

    it("should revert settle if tokenOut does not have a price feed", async () => {
      const { newPoolAddress, grgTokenAddress, oracle, oracleAddress, user1 } =
        await setupTests();
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency0: ZeroAddress,
          currency1: grgTokenAddress,
          fee: 0,
          tickSpacing: MAX_TICK_SPACING,
          hooks: oracleAddress,
        },
      };
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.TAKE, [
        PAIR.poolKey.currency1,
        newPoolAddress,
        parseEther("12"),
      ]);
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.V4_SWAP, [
        v4Planner.actions,
        v4Planner.params,
      ]);
      const { commands, inputs } = planner;
      const extPool = await getExtPool(newPoolAddress);
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        }),
      )
        .to.be.revertedWithCustomError(extPool, "TokenPriceFeedDoesNotExist")
        .withArgs(grgTokenAddress);
      await oracle.initializeObservations(PAIR.poolKey);
      try {
        await user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        });
      } catch (error: any) {
        const customError =
          error.error?.reason || error.reason || error.message;
        throw new Error(`${customError}`);
      }
    });

    it("should take a currency", async () => {
      const { newPoolAddress, grgTokenAddress, user1 } = await setupTests();
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency1: grgTokenAddress,
        },
      };
      PAIR.poolKey.currency1 = grgTokenAddress;
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.TAKE, [
        PAIR.poolKey.currency0,
        newPoolAddress,
        parseEther("12"),
      ]);
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.V4_SWAP, [
        v4Planner.actions,
        v4Planner.params,
      ]);
      const { commands, inputs } = planner;
      const extPool = await getExtPool(newPoolAddress);
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );
      try {
        await user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        });
      } catch (error: any) {
        const customError =
          error.error?.reason || error.reason || error.message;
        throw new Error(`${customError}`);
      }
    });

    it("should decode v4 payment methods", async () => {
      const {
        pool,
        newPoolAddress,
        grgTokenAddress,
        wethAddress,
        oracle,
        oracleAddress,
        user1,
      } = await setupTests();
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency0: ZeroAddress,
          currency1: wethAddress,
          fee: 0,
          tickSpacing: MAX_TICK_SPACING,
          hooks: oracleAddress,
        },
      };
      await oracle.initializeObservations(PAIR.poolKey);
      PAIR.poolKey = {
        currency0: ZeroAddress,
        currency1: grgTokenAddress,
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: oracleAddress,
      };
      await oracle.initializeObservations(PAIR.poolKey);
      const v4Planner: V4Planner = new V4Planner();
      // same as base token, won't be added to active tokens
      v4Planner.addAction(Actions.TAKE, [
        PAIR.poolKey.currency0,
        newPoolAddress,
        parseEther("12"),
      ]);
      // this will add a new token to the returned tokensOut array
      v4Planner.addAction(Actions.TAKE, [
        PAIR.poolKey.currency1,
        newPoolAddress,
        parseEther("12"),
      ]);
      // new token, will be added to active tokens
      v4Planner.addAction(Actions.TAKE, [
        wethAddress,
        newPoolAddress,
        parseEther("1"),
      ]);
      // TODO: add positive value and make sure pool has eth
      v4Planner.addAction(Actions.SETTLE_ALL, [PAIR.poolKey.currency0, 0]);
      v4Planner.addAction(Actions.TAKE_ALL, [
        PAIR.poolKey.currency0,
        parseEther("12"),
      ]);
      v4Planner.addAction(Actions.TAKE_PORTION, [
        PAIR.poolKey.currency0,
        newPoolAddress,
        0,
      ]);
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.V4_SWAP, [
        v4Planner.actions,
        v4Planner.params,
      ]);
      const { commands, inputs } = planner;
      const extPool = await getExtPool(newPoolAddress);
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );
      try {
        await user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        });
      } catch (error: any) {
        const customError =
          error.error?.reason || error.reason || error.message;
        throw new Error(`${customError}`);
      }
      const activeTokens = await pool.getActiveTokens();
      expect(activeTokens.activeTokens.length).to.be.eq(2);
      expect(activeTokens.activeTokens[0]).to.be.eq(grgTokenAddress);
      expect(activeTokens.activeTokens[1]).to.be.eq(wethAddress);
    });

    it("should wrap/unwrap native", async () => {
      const { pool, newPoolAddress, grgTokenAddress, user1 } =
        await setupTests();
      const planner: RoutePlanner = new RoutePlanner();
      // will revert if pool does not have enough eth
      await pool.mint(user1.address, parseEther("0.1"), 1, {
        value: parseEther("0.1"),
      });
      planner.addCommand(CommandType.WRAP_ETH, [newPoolAddress, 1000]);
      planner.addCommand(CommandType.UNWRAP_WETH, [newPoolAddress, 0]);
      planner.addCommand(CommandType.BALANCE_CHECK_ERC20, [
        newPoolAddress,
        grgTokenAddress,
        1,
      ]);
      const { commands, inputs } = planner;
      const extPool = await getExtPool(newPoolAddress);
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );
      try {
        await user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        });
      } catch (error: any) {
        const customError =
          error.error?.reason || error.reason || error.message;
        throw new Error(`${customError}`);
      }
    });

    it("should decode WRAP_ETH with CONTRACT_BALANCE flag without overflow", async () => {
      const {
        newPoolAddress,
        grgTokenAddress,
        wethAddress,
        oracle,
        oracleAddress,
        user1,
      } = await setupTests();
      const PAIR = {
        ...DEFAULT_PAIR,
        poolKey: {
          ...DEFAULT_PAIR.poolKey,
          currency0: ZeroAddress,
          currency1: wethAddress,
          fee: 0,
          tickSpacing: MAX_TICK_SPACING,
          hooks: oracleAddress,
        },
      };
      await oracle.initializeObservations(PAIR.poolKey);
      const planner: RoutePlanner = new RoutePlanner();
      // WRAP_ETH with CONTRACT_BALANCE sentinel should not add to params.value
      planner.addCommand(CommandType.WRAP_ETH, [
        newPoolAddress,
        CONTRACT_BALANCE,
      ]);
      planner.addCommand(CommandType.BALANCE_CHECK_ERC20, [
        newPoolAddress,
        grgTokenAddress,
        1,
      ]);
      const { commands, inputs } = planner;
      const extPool = await getExtPool(newPoolAddress);
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );
      // Should succeed with value=0 since CONTRACT_BALANCE is skipped in value computation
      try {
        await user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        });
      } catch (error: any) {
        const customError =
          error.error?.reason || error.reason || error.message;
        throw new Error(`${customError}`);
      }
    });

    it("a direct call should revert", async () => {
      const { newPoolAddress, grgTokenAddress, aUniswapRouterAddress, user1 } =
        await setupTests();
      const PAIR = { ...DEFAULT_PAIR };
      PAIR.poolKey.currency1 = grgTokenAddress;
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.TAKE, [
        PAIR.poolKey.currency0,
        newPoolAddress,
        parseEther("12"),
      ]);
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.V4_SWAP, [
        v4Planner.actions,
        v4Planner.params,
      ]);
      const { commands, inputs } = planner;
      const extPool = await getExtPool(newPoolAddress);
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );
      await expect(
        user1.sendTransaction({
          to: aUniswapRouterAddress,
          value: 0,
          data: encodedSwapData,
        }),
      ).to.be.revertedWithCustomError(extPool, "DirectCallNotAllowed");
    });

    it("should propagate string error from universal router", async () => {
      const { newPoolAddress, wethAddress, uniRouter } = await setupTests();
      const PAIR = { ...DEFAULT_PAIR };
      PAIR.poolKey.currency1 = wethAddress;
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.TAKE, [
        PAIR.poolKey.currency0,
        newPoolAddress,
        parseEther("12"),
      ]);
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.V4_SWAP, [
        v4Planner.actions,
        v4Planner.params,
      ]);
      const { commands, inputs } = planner;
      const extPool = await getExtPool(newPoolAddress);
      // set mock to revert with string error
      await uniRouter.setRevertMode(1);
      await expect(
        extPool.getFunction("execute(bytes,bytes[])")(commands, inputs),
      ).to.be.revertedWith("MockRouterStringError");
      await uniRouter.setRevertMode(0);
    });

    it("should propagate custom error from universal router", async () => {
      const { newPoolAddress, wethAddress, uniRouter } = await setupTests();
      const PAIR = { ...DEFAULT_PAIR };
      PAIR.poolKey.currency1 = wethAddress;
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.TAKE, [
        PAIR.poolKey.currency0,
        newPoolAddress,
        parseEther("12"),
      ]);
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.V4_SWAP, [
        v4Planner.actions,
        v4Planner.params,
      ]);
      const { commands, inputs } = planner;
      const extPool = await getExtPool(newPoolAddress);
      // set mock to revert with custom error
      await uniRouter.setRevertMode(2);
      await expect(
        extPool.getFunction("execute(bytes,bytes[])")(commands, inputs),
      )
        .to.be.revertedWithCustomError(uniRouter, "MockCustomError")
        .withArgs("MockRouterCustomError");
      await uniRouter.setRevertMode(0);
    });

    it("should execute a subplan", async () => {
      const { newPoolAddress, grgTokenAddress, user1 } = await setupTests();
      const PAIR = { ...DEFAULT_PAIR };
      PAIR.poolKey.currency1 = grgTokenAddress;
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.TAKE, [
        PAIR.poolKey.currency0,
        newPoolAddress,
        parseEther("12"),
      ]);
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.V4_SWAP, [
        v4Planner.actions,
        v4Planner.params,
      ]);
      const subPlanner: RoutePlanner = new RoutePlanner();
      subPlanner.addCommand(CommandType.EXECUTE_SUB_PLAN, [
        planner.commands,
        planner.inputs,
      ]);
      const extPool = await getExtPool(newPoolAddress);
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [subPlanner.commands, subPlanner.inputs, DEADLINE],
      );
      try {
        await user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        });
      } catch (error: any) {
        const customError =
          error.error?.reason || error.reason || error.message;
        throw new Error(`${customError}`);
      }
    });

    // TODO: can move this to new file EApps.spec.ts
    it("should remove 1 token from active tokens", async () => {
      const {
        newPoolAddress,
        pool,
        grgToken,
        grgTokenAddress,
        wethAddress,
        oracle,
        oracleAddress,
        user1,
      } = await setupTests();
      const PAIR = { ...DEFAULT_PAIR };
      PAIR.poolKey = {
        currency0: ZeroAddress,
        currency1: wethAddress,
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: oracleAddress,
      };
      await oracle.initializeObservations(PAIR.poolKey);
      PAIR.poolKey = {
        currency0: ZeroAddress,
        currency1: grgTokenAddress,
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: oracleAddress,
      };
      await oracle.initializeObservations(PAIR.poolKey);
      PAIR.poolKey.currency0 = wethAddress;
      PAIR.poolKey.currency1 = grgTokenAddress;
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.TAKE, [
        PAIR.poolKey.currency0,
        newPoolAddress,
        parseEther("12"),
      ]);
      v4Planner.addAction(Actions.TAKE, [
        PAIR.poolKey.currency1,
        newPoolAddress,
        parseEther("12"),
      ]);
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.V4_SWAP, [
        v4Planner.actions,
        v4Planner.params,
      ]);
      const extPool = await getExtPool(newPoolAddress);
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [planner.commands, planner.inputs, DEADLINE],
      );
      try {
        await user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        });
      } catch (error: any) {
        const customError =
          error.error?.reason || error.reason || error.message;
        throw new Error(`${customError}`);
      }
      expect((await pool.getActiveTokens()).activeTokens.length).to.be.eq(2);
      // transfer grg to pool, so it cannot be purged, while weth will be, as its balance is 0
      await grgToken.transfer(newPoolAddress, parseEther("12"));
      await pool.purgeInactiveTokensAndApps();
      expect((await pool.getActiveTokens()).activeTokens.length).to.be.eq(1);
    });

    it("should process v3 exactIn swap", async function () {
      const {
        newPoolAddress,
        grgTokenAddress,
        wethAddress,
        oracle,
        oracleAddress,
        user1,
      } = await setupTests();
      const PAIR = { ...DEFAULT_PAIR };
      PAIR.poolKey = {
        currency0: ZeroAddress,
        currency1: grgTokenAddress,
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: oracleAddress,
      };
      await oracle.initializeObservations(PAIR.poolKey);
      const path = encodePath(
        [wethAddress, grgTokenAddress],
        [FeeAmount.MEDIUM],
      );
      const planner: RoutePlanner = new RoutePlanner();
      // recipient, amountIn, amountOutMin, path, payerIsUser
      planner.addCommand(CommandType.V3_SWAP_EXACT_IN, [
        newPoolAddress,
        100,
        1,
        path,
        true,
      ]);
      const extPool = await getExtPool(newPoolAddress);
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [planner.commands, planner.inputs, DEADLINE],
      );
      try {
        await user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        });
      } catch (error: any) {
        const customError =
          error.error?.reason || error.reason || error.message;
        throw new Error(`${customError}`);
      }
    });

    it("should process v3 exactIn swap by passing sender as receipient flag", async function () {
      const {
        newPoolAddress,
        grgTokenAddress,
        wethAddress,
        oracle,
        oracleAddress,
        user1,
      } = await setupTests();
      const PAIR = { ...DEFAULT_PAIR };
      PAIR.poolKey = {
        currency0: ZeroAddress,
        currency1: grgTokenAddress,
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: oracleAddress,
      };
      await oracle.initializeObservations(PAIR.poolKey);
      const path = encodePath(
        [wethAddress, grgTokenAddress],
        [FeeAmount.MEDIUM],
      );
      // from uniswap v4 periphery constants definition
      const SENDER_AS_RECIPIENT = "0x0000000000000000000000000000000000000001";
      const planner: RoutePlanner = new RoutePlanner();
      // recipient, amountIn, amountOutMin, path, payerIsUser
      planner.addCommand(CommandType.V3_SWAP_EXACT_IN, [
        SENDER_AS_RECIPIENT,
        100,
        1,
        path,
        true,
      ]);
      const extPool = await getExtPool(newPoolAddress);
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [planner.commands, planner.inputs, DEADLINE],
      );
      try {
        await user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        });
      } catch (error: any) {
        const customError =
          error.error?.reason || error.reason || error.message;
        throw new Error(`${customError}`);
      }
    });

    it("should process v3 exactIn swap and unwrap", async function () {
      const { newPoolAddress, grgTokenAddress, wethAddress, user1 } =
        await setupTests();
      const path = encodePath(
        [grgTokenAddress, wethAddress],
        [FeeAmount.MEDIUM],
      );
      const planner: RoutePlanner = new RoutePlanner();
      // from uniswap v4 periphery constants definition. router must be WETH recipient, to be able to unwrap
      const ROUTER_AS_RECIPIENT = "0x0000000000000000000000000000000000000002";
      // recipient, amountIn, amountOutMin, path, payerIsUser
      planner.addCommand(CommandType.V3_SWAP_EXACT_IN, [
        ROUTER_AS_RECIPIENT,
        100,
        1,
        path,
        true,
      ]);
      planner.addCommand(CommandType.UNWRAP_WETH, [newPoolAddress, 100]);
      const extPool = await getExtPool(newPoolAddress);
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [planner.commands, planner.inputs, DEADLINE],
      );
      // our mock router contract does not handle transaction logic, so cannot assert that ETH was sent to smart pool
      await user1.sendTransaction({
        to: newPoolAddress,
        value: 0,
        data: encodedSwapData,
      });
    });

    it("should process v3 exactOut", async function () {
      const {
        newPoolAddress,
        grgTokenAddress,
        wethAddress,
        oracle,
        oracleAddress,
        user1,
      } = await setupTests();
      const PAIR = { ...DEFAULT_PAIR };
      PAIR.poolKey = {
        currency0: ZeroAddress,
        currency1: wethAddress,
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: oracleAddress,
      };
      await oracle.initializeObservations(PAIR.poolKey);
      const path = encodePath(
        [wethAddress, grgTokenAddress],
        [FeeAmount.MEDIUM],
      );
      const planner: RoutePlanner = new RoutePlanner();
      // recipient, amountOut, amountInMax, path, payerIsUser
      planner.addCommand(CommandType.V3_SWAP_EXACT_OUT, [
        newPoolAddress,
        100,
        1,
        path,
        true,
      ]);
      const extPool = await getExtPool(newPoolAddress);
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [planner.commands, planner.inputs, DEADLINE],
      );
      try {
        await user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        });
      } catch (error: any) {
        const customError =
          error.error?.reason || error.reason || error.message;
        throw new Error(`${customError}`);
      }
    });

    it("should process v2 swap", async function () {
      const {
        pool,
        newPoolAddress,
        grgTokenAddress,
        wethAddress,
        oracle,
        oracleAddress,
        user1,
      } = await setupTests();
      const PAIR = { ...DEFAULT_PAIR };
      // we must add a price feed for both tokens, as we use both exactIn and exactOut methods
      PAIR.poolKey = {
        currency0: ZeroAddress,
        currency1: grgTokenAddress,
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: oracleAddress,
      };
      await oracle.initializeObservations(PAIR.poolKey);
      PAIR.poolKey = {
        currency0: ZeroAddress,
        currency1: wethAddress,
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: oracleAddress,
      };
      await oracle.initializeObservations(PAIR.poolKey);
      let path = [wethAddress, grgTokenAddress];
      const planner: RoutePlanner = new RoutePlanner();
      // recipient, amountOut, amountInMax, path, payerIsUser
      planner.addCommand(CommandType.V2_SWAP_EXACT_IN, [
        newPoolAddress,
        100,
        1,
        path,
        true,
      ]);
      planner.addCommand(CommandType.V2_SWAP_EXACT_OUT, [
        newPoolAddress,
        100,
        1,
        path,
        true,
      ]);
      const extPool = await getExtPool(newPoolAddress);
      let encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [planner.commands, planner.inputs, DEADLINE],
      );
      try {
        await user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        });
      } catch (error: any) {
        const customError =
          error.error?.reason || error.reason || error.message;
        throw new Error(`${customError}`);
      }
      path = [ZeroAddress, grgTokenAddress];
      planner.addCommand(CommandType.V2_SWAP_EXACT_IN, [
        newPoolAddress,
        100,
        1,
        path,
        true,
      ]);
      encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [planner.commands, planner.inputs, DEADLINE],
      );
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        }),
      ).to.be.revertedWithCustomError(extPool, "InsufficientNativeBalance");
      await pool.mint(user1.address, parseEther("0.1"), 1, {
        value: parseEther("0.1"),
      });
      try {
        await user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        });
      } catch (error: any) {
        const customError =
          error.error?.reason || error.reason || error.message;
        throw new Error(`${customError}`);
      }
      planner.addCommand(CommandType.V2_SWAP_EXACT_IN, [
        user1.address,
        100,
        1,
        path,
        true,
      ]);
      encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [planner.commands, planner.inputs, DEADLINE],
      );
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        }),
      ).to.be.revertedWithCustomError(extPool, "RecipientNotSmartPoolOrRouter");
    });

    it("should revert V2_SWAP_EXACT_OUT with native ETH path", async function () {
      const { newPoolAddress, grgTokenAddress, oracle, oracleAddress, user1 } =
        await setupTests();
      const PAIR = { ...DEFAULT_PAIR };
      PAIR.poolKey = {
        currency0: ZeroAddress,
        currency1: grgTokenAddress,
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: oracleAddress,
      };
      await oracle.initializeObservations(PAIR.poolKey);
      const path = [ZeroAddress, grgTokenAddress];
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.V2_SWAP_EXACT_OUT, [
        newPoolAddress,
        100,
        1,
        path,
        true,
      ]);
      const extPool = await getExtPool(newPoolAddress);
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [planner.commands, planner.inputs, DEADLINE],
      );
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        }),
      )
        .to.be.revertedWithCustomError(extPool, "InvalidCommandType")
        .withArgs(9n);
    });

    it("should process sweep, transfer and pay v3 payment methods", async function () {
      const {
        newPoolAddress,
        grgTokenAddress,
        wethAddress,
        oracle,
        oracleAddress,
        user1,
      } = await setupTests();
      const PAIR = { ...DEFAULT_PAIR };
      PAIR.poolKey = {
        currency0: ZeroAddress,
        currency1: grgTokenAddress,
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: oracleAddress,
      };
      await oracle.initializeObservations(PAIR.poolKey);
      const path = encodePath(
        [wethAddress, grgTokenAddress],
        [FeeAmount.MEDIUM],
      );
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.SWEEP, [
        grgTokenAddress,
        newPoolAddress,
        1,
      ]);
      planner.addCommand(CommandType.TRANSFER, [
        grgTokenAddress,
        newPoolAddress,
        1,
      ]);
      planner.addCommand(CommandType.PAY_PORTION, [
        grgTokenAddress,
        newPoolAddress,
        1,
      ]);
      const extPool = await getExtPool(newPoolAddress);
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [planner.commands, planner.inputs, DEADLINE],
      );
      try {
        await user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        });
      } catch (error: any) {
        const customError =
          error.error?.reason || error.reason || error.message;
        throw new Error(`${customError}`);
      }
    });

    it("should revert when calling unsupported methods", async () => {
      const { newPoolAddress, grgTokenAddress, user1 } = await setupTests();
      const PAIR = { ...DEFAULT_PAIR };
      PAIR.poolKey.currency1 = grgTokenAddress;
      let planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.PERMIT2_TRANSFER_FROM, [
        PAIR.poolKey.currency0,
        newPoolAddress,
        parseEther("12"),
      ]);
      const extPool = await getExtPool(newPoolAddress);
      let encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [planner.commands, planner.inputs, DEADLINE],
      );
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        }),
      )
        .to.be.revertedWithCustomError(extPool, "InvalidCommandType")
        .withArgs(BigInt(CommandType.PERMIT2_TRANSFER_FROM));
      planner = new RoutePlanner();
      planner.addCommand(CommandType.PERMIT2_PERMIT_BATCH, [
        {
          details: [
            { token: grgTokenAddress, amount: 0, expiration: 0, nonce: 0 },
          ],
          spender: grgTokenAddress,
          sigDeadline: 0,
        },
        "0x",
      ]);
      encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [planner.commands, planner.inputs, DEADLINE],
      );
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        }),
      )
        .to.be.revertedWithCustomError(extPool, "InvalidCommandType")
        .withArgs(BigInt(CommandType.PERMIT2_PERMIT_BATCH));
      planner = new RoutePlanner();
      planner.addCommand(CommandType.PERMIT2_PERMIT, [
        {
          details: {
            token: grgTokenAddress,
            amount: 0,
            expiration: 0,
            nonce: 0,
          },
          spender: grgTokenAddress,
          sigDeadline: 0,
        },
        "0x",
      ]);
      encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [planner.commands, planner.inputs, DEADLINE],
      );
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        }),
      )
        .to.be.revertedWithCustomError(extPool, "InvalidCommandType")
        .withArgs(BigInt(CommandType.PERMIT2_PERMIT));
      planner = new RoutePlanner();
      planner.addCommand(CommandType.PERMIT2_TRANSFER_FROM_BATCH, [
        [
          {
            from: newPoolAddress,
            to: newPoolAddress,
            amount: 1,
            token: newPoolAddress,
          },
        ],
      ]);
      encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [planner.commands, planner.inputs, DEADLINE],
      );
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        }),
      )
        .to.be.revertedWithCustomError(extPool, "InvalidCommandType")
        .withArgs(BigInt(CommandType.PERMIT2_TRANSFER_FROM_BATCH));
      planner = new RoutePlanner();
      planner.addCommand(CommandType.V3_POSITION_MANAGER_PERMIT, [
        encodedSwapData,
      ]);
      encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [planner.commands, planner.inputs, DEADLINE],
      );
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        }),
      )
        .to.be.revertedWithCustomError(extPool, "InvalidCommandType")
        .withArgs(BigInt(CommandType.V3_POSITION_MANAGER_PERMIT));
      planner = new RoutePlanner();
      planner.addCommand(CommandType.V3_POSITION_MANAGER_CALL, [
        encodedSwapData,
      ]);
      encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [planner.commands, planner.inputs, DEADLINE],
      );
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        }),
      )
        .to.be.revertedWithCustomError(extPool, "InvalidCommandType")
        .withArgs(BigInt(CommandType.V3_POSITION_MANAGER_CALL));
      planner = new RoutePlanner();
      planner.addCommand(CommandType.V4_POSITION_MANAGER_CALL, [
        encodedSwapData,
      ]);
      encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [planner.commands, planner.inputs, DEADLINE],
      );
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        }),
      )
        .to.be.revertedWithCustomError(extPool, "InvalidCommandType")
        .withArgs(BigInt(CommandType.V4_POSITION_MANAGER_CALL));

      let rogueCommand = CommandType.EXECUTE_SUB_PLAN + 1;
      encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [toBeHex(rogueCommand), [toBeHex(0)], DEADLINE],
      );
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        }),
      )
        .to.be.revertedWithCustomError(extPool, "InvalidCommandType")
        .withArgs(BigInt(rogueCommand));
      rogueCommand = CommandType.V2_SWAP_EXACT_IN - 1;
      encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [toBeHex(rogueCommand), [toBeHex(0)], DEADLINE],
      );
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        }),
      )
        .to.be.revertedWithCustomError(extPool, "InvalidCommandType")
        .withArgs(BigInt(rogueCommand));
      rogueCommand = CommandType.V4_SWAP - 1;
      encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [toBeHex(rogueCommand), [toBeHex(0)], DEADLINE],
      );
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        }),
      )
        .to.be.revertedWithCustomError(extPool, "InvalidCommandType")
        .withArgs(BigInt(rogueCommand));
      rogueCommand = CommandType.EXECUTE_SUB_PLAN - 1;
      encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [toBeHex(rogueCommand), [toBeHex(0)], DEADLINE],
      );
      await expect(
        user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        }),
      )
        .to.be.revertedWithCustomError(extPool, "InvalidCommandType")
        .withArgs(BigInt(rogueCommand));
      PAIR.poolKey.currency1 = grgTokenAddress;
    });

    it("logs gas costs for mint when pool has null balance of active tokens", async () => {
      const {
        pool,
        newPoolAddress,
        wethAddress,
        grgTokenAddress,
        oracle,
        oracleAddress,
        user1,
      } = await setupTests();
      const PAIR = { ...DEFAULT_PAIR };
      PAIR.poolKey = {
        currency0: ZeroAddress,
        currency1: wethAddress,
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: oracleAddress,
      };
      await oracle.initializeObservations(PAIR.poolKey);
      let v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.TAKE, [
        PAIR.poolKey.currency1,
        newPoolAddress,
        parseEther("12"),
      ]);
      let planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.V4_SWAP, [
        v4Planner.actions,
        v4Planner.params,
      ]);
      const { commands, inputs } = planner;
      const extPool = await getExtPool(newPoolAddress);
      let encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );
      try {
        await user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        });
      } catch (error: any) {
        const customError =
          error.error?.reason || error.reason || error.message;
        throw new Error(`${customError}`);
      }
      // add first 2 mint
      let txReceipt = await pool.mint(user1.address, parseEther("12"), 1, {
        value: parseEther("12"),
      });
      let result = await txReceipt.wait();
      let gasCost = Number(result.cumulativeGasUsed);
      console.log(
        gasCost,
        "1st mint gas cost, with 1 active token (stores initial value)",
      );
      txReceipt = await pool.mint(user1.address, parseEther("12"), 1, {
        value: parseEther("12"),
      });
      result = await txReceipt.wait();
      gasCost = Number(result.cumulativeGasUsed);
      console.log(
        gasCost,
        "2nd mint gas cost, with 1 active token (calculates nav)",
      );
      PAIR.poolKey.currency1 = grgTokenAddress;
      await oracle.initializeObservations(PAIR.poolKey);
      v4Planner = new V4Planner();
      v4Planner.addAction(Actions.TAKE, [
        PAIR.poolKey.currency1,
        newPoolAddress,
        parseEther("12"),
      ]);
      planner = new RoutePlanner();
      planner.addCommand(CommandType.V4_SWAP, [
        v4Planner.actions,
        v4Planner.params,
      ]);
      const { commands: newCommands, inputs: newInputs } = planner;
      encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [newCommands, newInputs, DEADLINE],
      );
      try {
        await user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        });
      } catch (error: any) {
        const customError =
          error.error?.reason || error.reason || error.message;
        throw new Error(`${customError}`);
      }
      txReceipt = await pool.mint(user1.address, parseEther("12"), 1, {
        value: parseEther("12"),
      });
      result = await txReceipt.wait();
      gasCost = Number(result.cumulativeGasUsed);
      console.log(
        gasCost,
        "3rd mint gas cost, with 2 active tokens (calculates nav)",
      );
      expect((await pool.getActiveTokens()).activeTokens.length).to.be.eq(2);
    });

    // we could also have both tokens' positive balances by initiatin WETH instance and transferring, however WETH is early-converted to ETH
    it("logs gas costs for mint when pool holds positive GRG balance", async () => {
      const {
        pool,
        newPoolAddress,
        wethAddress,
        grgToken,
        oracle,
        oracleAddress,
        user1,
      } = await setupTests();
      await grgToken.transfer(newPoolAddress, parseEther("12"));
      const PAIR = { ...DEFAULT_PAIR };
      PAIR.poolKey = {
        currency0: ZeroAddress,
        currency1: wethAddress,
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: oracleAddress,
      };
      await oracle.initializeObservations(PAIR.poolKey);
      let v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.TAKE, [
        PAIR.poolKey.currency1,
        newPoolAddress,
        parseEther("12"),
      ]);
      let planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.V4_SWAP, [
        v4Planner.actions,
        v4Planner.params,
      ]);
      const { commands, inputs } = planner;
      const extPool = await getExtPool(newPoolAddress);
      let encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );
      try {
        await user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        });
      } catch (error: any) {
        const customError =
          error.error?.reason || error.reason || error.message;
        throw new Error(`${customError}`);
      }
      // add first 2 mint
      let txReceipt = await pool.mint(user1.address, parseEther("12"), 1, {
        value: parseEther("12"),
      });
      let result = await txReceipt.wait();
      let gasCost = Number(result.cumulativeGasUsed);
      console.log(
        gasCost,
        "1st mint gas cost, with 1 active token (stores initial value)",
      );
      txReceipt = await pool.mint(user1.address, parseEther("12"), 1, {
        value: parseEther("12"),
      });
      result = await txReceipt.wait();
      gasCost = Number(result.cumulativeGasUsed);
      console.log(
        gasCost,
        "2nd mint gas cost, with 1 active token (calculates nav)",
      );
      PAIR.poolKey.currency1 = await grgToken.getAddress();
      v4Planner = new V4Planner();
      v4Planner.addAction(Actions.TAKE, [
        PAIR.poolKey.currency1,
        newPoolAddress,
        parseEther("12"),
      ]);
      planner = new RoutePlanner();
      planner.addCommand(CommandType.V4_SWAP, [
        v4Planner.actions,
        v4Planner.params,
      ]);
      const { commands: newCommands, inputs: newInputs } = planner;
      encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [newCommands, newInputs, DEADLINE],
      );
      await oracle.initializeObservations(PAIR.poolKey);
      try {
        await user1.sendTransaction({
          to: newPoolAddress,
          value: 0,
          data: encodedSwapData,
        });
      } catch (error: any) {
        const customError =
          error.error?.reason || error.reason || error.message;
        throw new Error(`${customError}`);
      }
      txReceipt = await pool.mint(user1.address, parseEther("12"), 1, {
        value: parseEther("12"),
      });
      result = await txReceipt.wait();
      gasCost = Number(result.cumulativeGasUsed);
      console.log(
        gasCost,
        "3rd mint gas cost, with 2 active tokens (calculates nav)",
      );
      expect((await pool.getActiveTokens()).activeTokens.length).to.be.eq(2);
      txReceipt = await pool.mint(user1.address, parseEther("12"), 1, {
        value: parseEther("12"),
      });
      result = await txReceipt.wait();
      gasCost = Number(result.cumulativeGasUsed);
      console.log(
        gasCost,
        "4th mint gas cost, with 2 active tokens (calculates nav but does not update storage)",
      );
      expect((await pool.getActiveTokens()).activeTokens.length).to.be.eq(2);
    });
  });
});
