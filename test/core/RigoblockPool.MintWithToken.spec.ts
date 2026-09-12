import { expect } from "chai";
import { network } from "hardhat";
import { parseEther, ZeroAddress } from "ethers";
import { DEADLINE, ZERO_ADDRESS } from "../shared/constants";
import { CommandType, RoutePlanner } from "../shared/planner";
import { timeTravel } from "../utils/utils";
import { connect, getFixedGasSigners } from "../shared/helper";
import { createFixture } from "../utils/fixtures";

describe("MintWithToken", async () => {
  const MAX_TICK_SPACING = 32767;

  const setupTests = createFixture(["tests-setup"], async ({ get }) => {
    const [user1, user2] = await getFixedGasSigners();
    const { ethers } = await network.getOrCreate();
    const factory = await ethers.getContractAt(
      "RigoblockPoolProxyFactory",
      (await get("RigoblockPoolProxyFactory")).address,
    );
    const authority = await ethers.getContractAt(
      "Authority",
      (await get("Authority")).address,
    );
    const grgToken = await ethers.getContractAt(
      "RigoToken",
      (await get("RigoToken")).address,
    );
    const poolAddress = (
      await factory.createPool.staticCall(
        "testpool",
        "TEST",
        await grgToken.getAddress(),
      )
    )[0];
    await factory.createPool("testpool", "TEST", await grgToken.getAddress());
    const pool = await ethers.getContractAt("SmartPool", poolAddress);
    const oracle = await ethers.getContractAt(
      "MockOracle",
      (await get("MockOracle")).address,
    );
    const weth = await ethers.getContractAt(
      "WETH9",
      (await get("WETH9")).address,
    );
    const univ4Posm = await ethers.getContractAt(
      "MockUniswapPosm",
      (await get("MockUniswapPosm")).address,
    );
    const uniRouter = await ethers.deployContract("MockUniUniversalRouter", [
      await univ4Posm.getAddress(),
    ]);
    const aUniswapRouter = await ethers.deployContract("AUniswapRouter", [
      await uniRouter.getAddress(),
      await univ4Posm.getAddress(),
      await weth.getAddress(),
    ]);
    await authority.setAdapter(await aUniswapRouter.getAddress(), true);
    // "3593564c": "execute(bytes calldata, bytes[] calldata, uint256)"
    await authority.addMethod("0x3593564c", await aUniswapRouter.getAddress());
    const tokenJar = await ethers.getContractAt(
      "MockTokenJar",
      (await get("MockTokenJar")).address,
    );

    return {
      factory,
      pool,
      oracle,
      grgToken,
      weth,
      tokenJar,
      user1,
      user2,
    };
  });

  describe("mintWithToken", async () => {
    it("should revert if token not active", async () => {
      const { pool, weth, grgToken, user1 } = await setupTests();
      const tokenAmount = parseEther("10");
      await grgToken.approve(await pool.getAddress(), tokenAmount);

      // weth is not in the active tokens set
      await expect(
        pool.mintWithToken(
          user1.address,
          tokenAmount,
          0,
          await weth.getAddress(),
        ),
      ).to.be.revertedWithCustomError(pool, "PoolMintTokenNotActive");
    });

    it("should revert it token is the same as pool base token", async () => {
      const { pool, oracle, grgToken, user1 } = await setupTests();
      const tokenAmount = parseEther("100");
      await grgToken.approve(await pool.getAddress(), tokenAmount);

      // grgToken is the same as pool base token
      await expect(
        pool.mintWithToken(
          user1.address,
          tokenAmount,
          0,
          await grgToken.getAddress(),
        ),
      ).to.be.revertedWithCustomError(pool, "PoolMintTokenNotActive");

      // check that base token is not activated
      const poolKey = {
        currency0: ZeroAddress,
        currency1: await grgToken.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(poolKey);
      await expect(
        pool.mintWithToken(
          user1.address,
          tokenAmount,
          0,
          await grgToken.getAddress(),
        ),
      ).to.be.revertedWithCustomError(pool, "PoolMintTokenNotActive");
    });

    it("should mint with alternative ERC20 token", async () => {
      const { pool, oracle, tokenJar, weth, grgToken, user1 } =
        await setupTests();
      const { ethers } = await network.getOrCreate();
      const tokenAmount = parseEther("100");
      await weth.deposit({ value: tokenAmount });
      await weth.approve(await pool.getAddress(), tokenAmount);

      // grgToken is the same as pool base token
      await expect(
        pool.mintWithToken(
          user1.address,
          tokenAmount,
          0,
          await weth.getAddress(),
        ),
      ).to.be.revertedWithCustomError(pool, "PoolMintTokenNotActive");

      // check that base token is not activated
      const poolKey = {
        currency0: ZeroAddress,
        currency1: await weth.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(poolKey);

      await expect(
        pool.mintWithToken(
          user1.address,
          tokenAmount,
          0,
          await weth.getAddress(),
        ),
      ).to.be.revertedWithCustomError(pool, "PoolMintTokenNotActive");

      // make sure pool has some eth balance
      await user1.sendTransaction({
        to: await pool.getAddress(),
        value: 1000,
      });

      // activate the token by wrapping some eth in the pool via AUniswapRouter call
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.WRAP_ETH, [await pool.getAddress(), 1000]);
      const { commands, inputs } = planner;
      const extPool = await ethers.getContractAt(
        "AUniswapRouter",
        await pool.getAddress(),
      );
      const encodedWrapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );
      await user1.sendTransaction({
        to: await extPool.getAddress(),
        value: 0,
        data: encodedWrapData,
      });

      await expect(
        pool.mintWithToken(
          user1.address,
          tokenAmount,
          0,
          await weth.getAddress(),
        ),
      ).to.be.revertedWithCustomError(pool, "PoolMintTokenNotActive");
      await pool.setAcceptableMintToken(await weth.getAddress(), true);

      // the token is active, but the base token price feed does not exist, so it should revert (we wouldn't be able to price the token otherwise)
      await expect(
        pool.mintWithToken(
          user1.address,
          tokenAmount,
          0,
          await weth.getAddress(),
        ),
      ).to.be.revertedWithCustomError(pool, "BaseTokenPriceFeedError");

      const grgPoolKey = {
        currency0: ZeroAddress,
        currency1: await grgToken.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(grgPoolKey);

      const { spread } = await pool.getPoolParams();
      const spreadAmount = (tokenAmount * spread) / 10000n;
      const tokenJarBalanceBefore = await weth.balanceOf(
        await tokenJar.getAddress(),
      );

      // travel time to avoid issues with oracle observations
      await timeTravel({ seconds: 600, mine: true }); // to ensure price feeds have enough data, so that twap does not change from simulation to actual tx

      const mintedAmount = await pool.mintWithToken.staticCall(
        user1.address,
        tokenAmount,
        0,
        await weth.getAddress(),
      );

      const tx = await pool.mintWithToken(
        user1.address,
        tokenAmount,
        0,
        await weth.getAddress(),
      );

      await expect(tx)
        .to.emit(pool, "Transfer")
        .withArgs(
          ZeroAddress,
          user1.address,
          parseEther("101.918011957404020383"),
        );
      await expect(tx)
        .to.emit(weth, "Transfer")
        .withArgs(user1.address, await pool.getAddress(), tokenAmount);
      await expect(tx)
        .to.emit(weth, "Transfer")
        .withArgs(
          await pool.getAddress(),
          await tokenJar.getAddress(),
          spreadAmount,
        );
      await expect(tx)
        .to.emit(pool, "NewNav")
        .withArgs(user1.address, await pool.getAddress(), parseEther("1"));
      expect(await pool.balanceOf(user1.address)).to.be.eq(
        parseEther("101.918011957404020383"),
      );
      expect(mintedAmount).to.be.eq(parseEther("101.918011957404020383"));

      const tokenJarBalanceAfter = await weth.balanceOf(
        await tokenJar.getAddress(),
      );
      expect(tokenJarBalanceAfter - tokenJarBalanceBefore).to.be.eq(
        spreadAmount,
      );
      // the user balance cannot be exactly tokenAmount - spreadAmount because the amountIn is not in base token
      expect(await pool.balanceOf(user1.address)).to.be.not.eq(
        tokenAmount - spreadAmount,
      );
    });

    it("should revert if token is not active", async () => {
      const { pool, oracle, grgToken, weth, user1 } = await setupTests();

      // Initialize price feeds for both tokens
      const grgPoolKey = {
        currency0: ZeroAddress,
        currency1: await grgToken.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(grgPoolKey);

      const wethPoolKey = {
        currency0: ZeroAddress,
        currency1: await weth.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(wethPoolKey);

      // Add weth to active tokens by minting some weth to the pool
      await weth.deposit({ value: parseEther("1") });
      await weth.transfer(await pool.getAddress(), parseEther("0.1"));

      const wethAmount = parseEther("10");
      await weth.deposit({ value: wethAmount });
      await weth.approve(await pool.getAddress(), wethAmount);

      await expect(
        pool.mintWithToken(
          user1.address,
          wethAmount,
          0,
          await weth.getAddress(),
        ),
      ).to.be.revertedWithCustomError(pool, "PoolMintTokenNotActive");
    });

    it("should apply spread and transfer to token jar contract", async () => {
      const { pool, oracle, grgToken, tokenJar, weth, user1 } =
        await setupTests();
      const { ethers } = await network.getOrCreate();
      const poolKey = {
        currency0: ZeroAddress,
        currency1: await grgToken.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(poolKey);

      await weth.deposit({ value: parseEther("1") });
      await weth.transfer(await pool.getAddress(), parseEther("0.1"));

      // activate the native token by unwrapping some weth in the pool via AUniswapRouter call
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.UNWRAP_WETH, [
        await pool.getAddress(),
        1000,
      ]);
      const { commands, inputs } = planner;
      const extPool = await ethers.getContractAt(
        "AUniswapRouter",
        await pool.getAddress(),
      );
      const encodedUnwrapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );
      await user1.sendTransaction({
        to: await extPool.getAddress(),
        value: 0,
        data: encodedUnwrapData,
      });

      const tokenAmount = parseEther("100");

      const { spread } = await pool.getPoolParams();
      const expectedSpread = (tokenAmount * spread) / 10000n;

      const tokenJarBalanceBefore = await ethers.provider.getBalance(
        await tokenJar.getAddress(),
      );

      await expect(
        pool.mintWithToken(user1.address, tokenAmount, 0, ZERO_ADDRESS, {
          value: tokenAmount,
        }),
      ).to.be.revertedWithCustomError(pool, "PoolMintTokenNotActive");
      await pool.setAcceptableMintToken(ZERO_ADDRESS, true);

      await pool.mintWithToken(user1.address, tokenAmount, 0, ZERO_ADDRESS, {
        value: tokenAmount,
      });

      const tokenJarBalanceAfter = await ethers.provider.getBalance(
        await tokenJar.getAddress(),
      );
      expect(tokenJarBalanceAfter - tokenJarBalanceBefore).to.be.eq(
        expectedSpread,
      );
    });

    it("should respect minimum output amount", async () => {
      const { pool, oracle, grgToken, weth, user1 } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const poolKey = {
        currency0: ZeroAddress,
        currency1: await grgToken.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(poolKey);

      await weth.deposit({ value: parseEther("1") });
      await weth.transfer(await pool.getAddress(), parseEther("0.1"));

      // activate the native token by unwrapping some weth in the pool via AUniswapRouter call
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.UNWRAP_WETH, [
        await pool.getAddress(),
        1000,
      ]);
      const { commands, inputs } = planner;
      const extPool = await ethers.getContractAt(
        "AUniswapRouter",
        await pool.getAddress(),
      );
      const encodedUnwrapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );
      await user1.sendTransaction({
        to: await extPool.getAddress(),
        value: 0,
        data: encodedUnwrapData,
      });

      const tokenAmount = parseEther("100");

      // travel time to avoid issues with oracle observations
      await timeTravel({ seconds: 600, mine: true }); // to ensure price feeds have enough data, so that twap does not change from simulation to actual tx

      await pool.setAcceptableMintToken(ZERO_ADDRESS, true);

      const expectedMintedAmount = await pool.mintWithToken.staticCall(
        user1.address,
        tokenAmount,
        0,
        ZERO_ADDRESS,
        { value: tokenAmount },
      );

      // Request more than will be minted
      await expect(
        pool.mintWithToken(
          user1.address,
          tokenAmount,
          expectedMintedAmount + 1n,
          ZERO_ADDRESS,
          { value: tokenAmount },
        ),
      ).to.be.revertedWithCustomError(pool, "PoolMintOutputAmount");
    });

    it("should work with user operator (different from pool operator)", async () => {
      const { pool, oracle, grgToken, user1, user2 } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const poolKey = {
        currency0: ZeroAddress,
        currency1: await grgToken.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(poolKey);

      // activate the native token by unwrapping some weth in the pool via AUniswapRouter call
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.UNWRAP_WETH, [
        await pool.getAddress(),
        1000,
      ]);
      const { commands, inputs } = planner;
      const extPool = await ethers.getContractAt(
        "AUniswapRouter",
        await pool.getAddress(),
      );
      const encodedUnwrapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );
      await user1.sendTransaction({
        to: await extPool.getAddress(),
        value: 0,
        data: encodedUnwrapData,
      });

      await grgToken.transfer(user2.address, parseEther("100"));

      const tokenAmount = parseEther("50");
      await connect(grgToken, user2).approve(
        await pool.getAddress(),
        tokenAmount,
      );
      await expect(
        pool.mintWithToken(user1.address, tokenAmount, 0, ZERO_ADDRESS, {
          value: tokenAmount,
        }),
      ).to.be.revertedWithCustomError(pool, "PoolMintTokenNotActive");
      await pool.setAcceptableMintToken(ZERO_ADDRESS, true);

      // Should fail without operator approval
      await expect(
        pool.mintWithToken(user2.address, tokenAmount, 0, ZERO_ADDRESS, {
          value: tokenAmount,
        }),
      ).to.be.revertedWithCustomError(pool, "InvalidOperator");

      // Set operator
      await connect(pool, user2).setOperator(user1.address, true);

      // Should work now
      await expect(
        pool.mintWithToken(user2.address, tokenAmount, 0, ZERO_ADDRESS, {
          value: tokenAmount,
        }),
      ).to.not.revert(ethers);

      expect(await pool.balanceOf(user2.address)).to.be.gt(0n);
    });

    it("should enforce KYC if provider is set", async () => {
      const { pool, factory, oracle, grgToken, user1 } = await setupTests();
      const { ethers } = await network.getOrCreate();

      // Set a KYC provider (any valid contract address will enforce the check)
      await pool.setKycProvider(await factory.getAddress());

      const poolKey = {
        currency0: ZeroAddress,
        currency1: await grgToken.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(poolKey);

      // activate the native token by unwrapping some weth in the pool via AUniswapRouter call
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.UNWRAP_WETH, [
        await pool.getAddress(),
        1000,
      ]);
      const { commands, inputs } = planner;
      const extPool = await ethers.getContractAt(
        "AUniswapRouter",
        await pool.getAddress(),
      );
      const encodedUnwrapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );
      await user1.sendTransaction({
        to: await extPool.getAddress(),
        value: 0,
        data: encodedUnwrapData,
      });

      const tokenAmount = parseEther("10");

      await expect(
        pool.mintWithToken(user1.address, tokenAmount, 0, ZERO_ADDRESS, {
          value: tokenAmount,
        }),
      ).to.be.revertedWithCustomError(pool, "PoolMintTokenNotActive");
      await pool.setAcceptableMintToken(ZERO_ADDRESS, true);

      // Should fail, but not with PoolCallerNotWhitelisted() error, because factory does not implement the expected interface
      // (in hardhat 3 the call reverts with empty return data instead of the old
      // "function selector was not recognized and there's no fallback function" reason)
      await expect(
        pool.mintWithToken(user1.address, tokenAmount, 0, ZERO_ADDRESS, {
          value: tokenAmount,
        }),
      ).to.be.revertedWithoutReason(ethers);
    });

    it("should enforce minimum amount", async () => {
      const { pool, oracle, grgToken, user1 } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const poolKey = {
        currency0: ZeroAddress,
        currency1: await grgToken.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(poolKey);

      // activate the native token by unwrapping some weth in the pool via AUniswapRouter call
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.UNWRAP_WETH, [
        await pool.getAddress(),
        1000,
      ]);
      const { commands, inputs } = planner;
      const extPool = await ethers.getContractAt(
        "AUniswapRouter",
        await pool.getAddress(),
      );
      const encodedUnwrapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );
      await user1.sendTransaction({
        to: await extPool.getAddress(),
        value: 0,
        data: encodedUnwrapData,
      });

      const decimals = await pool.decimals();
      const minimumAmount = 10n ** BigInt(decimals) / 1000n; // 0.001 pool tokens

      await expect(
        pool.mintWithToken(user1.address, minimumAmount - 1n, 0, ZERO_ADDRESS, {
          value: minimumAmount - 1n,
        }),
      ).to.be.revertedWithCustomError(pool, "PoolMintTokenNotActive");

      await pool.setAcceptableMintToken(ZERO_ADDRESS, true);

      // After the fix the minimum check is applied to the gross converted base amount,
      // not to the raw input token amount. Use an input that is clearly below the
      // minimum in base units even after oracle conversion.
      await expect(
        pool.mintWithToken(
          user1.address,
          minimumAmount / 1000n,
          0,
          ZERO_ADDRESS,
          {
            value: minimumAmount / 1000n,
          },
        ),
      )
        .to.be.revertedWithCustomError(pool, "PoolAmountSmallerThanMinimum")
        .withArgs(1000n);
    });
  });

  describe("setAcceptableMintToken", async () => {
    it("should set acceptable mint token", async () => {
      const { pool, weth } = await setupTests();
      const wethAddress = await weth.getAddress();

      let acceptedTokensBefore = await pool.getAcceptedMintTokens();
      expect(acceptedTokensBefore).to.not.include(wethAddress);

      await pool.setAcceptableMintToken(wethAddress, true);

      acceptedTokensBefore = await pool.getAcceptedMintTokens();
      expect(acceptedTokensBefore).to.include(wethAddress);

      await pool.setAcceptableMintToken(wethAddress, false);

      acceptedTokensBefore = await pool.getAcceptedMintTokens();
      expect(acceptedTokensBefore).to.not.include(wethAddress);
    });
  });

  it("should be owner restricted", async () => {
    const { pool, weth, user2 } = await setupTests();

    await expect(
      connect(pool, user2).setAcceptableMintToken(
        await weth.getAddress(),
        true,
      ),
    ).to.be.revertedWithCustomError(pool, "PoolCallerIsNotOwner");
  });

  describe("Security: Purge Attack Prevention", async () => {
    it("should prevent NAV manipulation via purge attack", async () => {
      const { pool, oracle, weth, grgToken, user1 } = await setupTests();

      // Setup oracle observations for base token (grgToken) first
      const grgPoolKey = {
        currency0: ZeroAddress,
        currency1: await grgToken.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(grgPoolKey);

      // Setup: Initialize pool with base token (grgToken) so NAV is established
      const initialMint = parseEther("100");
      await grgToken.approve(await pool.getAddress(), initialMint);
      await pool.mint(user1.address, initialMint, 0);

      // Get initial NAV
      await pool.updateUnitaryValue();
      const navBefore = (await pool.getPoolTokens()).unitaryValue;
      expect(navBefore).to.equal(parseEther("1")); // NAV should be 1.0

      // ATTACK SCENARIO:
      // 1. Pool operator sets WETH as acceptable mint token
      const poolKey = {
        currency0: ZeroAddress,
        currency1: await weth.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(poolKey);

      await pool.setAcceptableMintToken(await weth.getAddress(), true);

      // Verify WETH is in accepted tokens
      const acceptedTokens = await pool.getAcceptedMintTokens();
      expect(acceptedTokens).to.include(await weth.getAddress());

      // 2. No mintWithToken is executed (pool has 0 WETH balance)
      const wethBalance = await weth.balanceOf(await pool.getAddress());
      expect(wethBalance).to.equal(0n);

      // 3. Anyone calls purgeInactiveTokensAndApps (removes WETH from activeTokensSet because balance is 0)
      await pool.purgeInactiveTokensAndApps();

      // 4. Token is still in acceptedTokensSet but removed from activeTokensSet
      // This is the critical state where the vulnerability would exist

      // 5. User tries to mintWithToken with WETH
      const wethAmount = parseEther("10");
      await weth.deposit({ value: wethAmount });
      await weth.approve(await pool.getAddress(), wethAmount);

      // Travel time for oracle observations
      await timeTravel({ seconds: 600, mine: true });

      // BEFORE FIX: This would succeed but NAV would drop because WETH not in activeTokensSet
      // AFTER FIX: Token is added to activeTokensSet during _mint, NAV remains correct

      await expect(
        pool.mintWithToken(
          user1.address,
          wethAmount,
          0,
          await weth.getAddress(),
        ),
      )
        .to.emit(pool, "TokenStatusChanged")
        .withArgs(await weth.getAddress(), true);

      // Verify NAV is still correct (should be ~1.0, allowing for small precision changes)
      await pool.updateUnitaryValue();
      const navAfter = (await pool.getPoolTokens()).unitaryValue;

      // NAV should not have dropped significantly
      // Allow small tolerance for rounding (0.1%)
      const tolerance = navBefore / 1000n; // 0.1%
      expect(navAfter).to.be.gte(navBefore - tolerance);

      // Verify WETH is now in activeTokensSet (added during mint)
      const activeTokensResult = await pool.getActiveTokens();
      expect(activeTokensResult.activeTokens).to.include(
        await weth.getAddress(),
      );
    });

    it("should handle purge correctly after successful mint", async () => {
      const { pool, oracle, weth, grgToken, user1 } = await setupTests();

      // Setup oracle for base token first
      const grgPoolKey = {
        currency0: ZeroAddress,
        currency1: await grgToken.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(grgPoolKey);

      // Setup: Initialize pool with base token
      const initialMint = parseEther("100");
      await grgToken.approve(await pool.getAddress(), initialMint);
      await pool.mint(user1.address, initialMint, 0);

      // Setup oracle for WETH
      const poolKey = {
        currency0: ZeroAddress,
        currency1: await weth.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(poolKey);

      // 1. Set WETH as acceptable and mint with it
      await pool.setAcceptableMintToken(await weth.getAddress(), true);

      const wethAmount = parseEther("10");
      await weth.deposit({ value: wethAmount });
      await weth.approve(await pool.getAddress(), wethAmount);

      // Travel time for oracle
      await timeTravel({ seconds: 600, mine: true });

      await expect(
        pool.mintWithToken(
          user1.address,
          wethAmount,
          0,
          await weth.getAddress(),
        ),
      )
        .to.emit(pool, "TokenStatusChanged")
        .withArgs(await weth.getAddress(), true);

      // Verify WETH is in activeTokensSet
      let activeTokensResult = await pool.getActiveTokens();
      expect(activeTokensResult.activeTokens).to.include(
        await weth.getAddress(),
      );
      await pool.setAcceptableMintToken(await weth.getAddress(), false); // Make it not acceptable so we can simulate drain

      // 3. Purge should NOT remove WETH from activeTokensSet (balance > 1)
      await pool.purgeInactiveTokensAndApps();

      // Verify WETH is still in activeTokensSet (has balance)
      activeTokensResult = await pool.getActiveTokens();
      expect(activeTokensResult.activeTokens).to.include(
        await weth.getAddress(),
      );

      // This demonstrates that after our fix:
      // - Token is added to activeTokensSet during mint
      // - Token stays in activeTokensSet while it has a balance
      // - Purge correctly preserves tokens with balances
    });
  });
});
