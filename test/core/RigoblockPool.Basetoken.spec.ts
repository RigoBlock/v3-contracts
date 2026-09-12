import { expect } from "chai";
import { network } from "hardhat";
import { ethers as ethersLib, parseEther } from "ethers";
import { DEADLINE } from "../shared/constants";
import { CommandType, RoutePlanner } from "../shared/planner";
import { Actions, V4Planner } from "../shared/v4Planner";
import { deployContract, timeTravel } from "../utils/utils";
import { connect, getFixedGasSigners } from "../shared/helper";
import { createFixture } from "../utils/fixtures";

describe("BaseTokenProxy", async () => {
  const MAX_TICK_SPACING = 32767;
  const DEFAULT_PAIR = {
    poolKey: {
      currency0: ethersLib.ZeroAddress,
      currency1: ethersLib.ZeroAddress,
      fee: 0,
      tickSpacing: MAX_TICK_SPACING,
      hooks: ethersLib.ZeroAddress,
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
    const poolAddress = (
      await factory.createPool.staticCall(
        "testpool",
        "TEST",
        await grgToken.getAddress(),
      )
    )[0];
    await factory.createPool("testpool", "TEST", await grgToken.getAddress());
    const pool = await ethers.getContractAt("SmartPool", poolAddress);
    const uniswapV3Npm = await ethers.getContractAt(
      "MockUniswapNpm",
      (await get("MockUniswapNpm")).address,
    );
    const univ4Posm = await ethers.getContractAt(
      "MockUniswapPosm",
      (await get("MockUniswapPosm")).address,
    );
    const authority = await ethers.getContractAt(
      "Authority",
      (await get("Authority")).address,
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
    await authority.addMethod("0x3593564c", await aUniswapRouter.getAddress());
    const oracle = await ethers.getContractAt(
      "MockOracle",
      (await get("MockOracle")).address,
    );
    return {
      pool,
      factory,
      grgToken,
      univ4Posm,
      weth: await ethers.getContractAt("WETH9", wethAddress),
      oracle,
      authorityAddress: (await get("Authority")).address,
      user1,
      user2,
    };
  });

  describe("poolStorage", async () => {
    it("should return pool implementation immutables", async () => {
      const { pool, authorityAddress } = await setupTests();
      expect(await pool.authority()).to.be.eq(authorityAddress);
      // This assertion must stay in sync with VERSION in MixinConstants.sol.
      // See AGENTS.md "Version Bump" for when and how to update it.
      expect(await pool.VERSION()).to.be.eq("4.4.4");
    });
  });

  describe("getPool", async () => {
    it("should return pool immutable parameters", async () => {
      const { pool, grgToken, user1 } = await setupTests();
      const poolData = await pool.getPool();
      //expect(poolData.name).to.be.eq('testpool')
      expect(poolData.symbol).to.be.eq("TEST");
      expect(poolData.decimals).to.be.eq(18n);
      expect(poolData.decimals).to.be.eq(await grgToken.decimals());
      expect(poolData.owner).to.be.eq(user1.address);
      expect(poolData.baseToken).to.be.eq(await grgToken.getAddress());
      expect(await pool.name()).to.be.eq(poolData.name);
      expect(await pool.symbol()).to.be.eq(poolData.symbol);
      expect(await pool.decimals()).to.be.eq(poolData.decimals);
      expect(await pool.owner()).to.be.eq(poolData.owner);
    });
  });

  describe("getPoolParams", async () => {
    it("should return pool parameters", async () => {
      const { pool, user1 } = await setupTests();
      const poolData = await pool.getPoolParams();
      // 30 days default minimum period
      expect(poolData.minPeriod).to.be.eq(2592000n);
      // 5% default spread
      expect(poolData.spread).to.be.eq(10n);
      expect(poolData.transactionFee).to.be.eq(0n);
      // pool operator default fee collector
      expect(poolData.feeCollector).to.be.eq(user1.address);
      expect(poolData.kycProvider).to.be.eq(ethersLib.ZeroAddress);
    });
  });

  describe("getPoolTokens", async () => {
    it("should return pool tokens struct", async () => {
      const { pool, grgToken, oracle, user1, user2 } = await setupTests();
      let poolData = await pool.getPoolTokens();
      expect(poolData.unitaryValue).to.be.eq(parseEther("1"));
      expect(poolData.totalSupply).to.be.eq(0n);
      const TEN_ETHER = parseEther("10");
      await grgToken.approve(await pool.getAddress(), parseEther("20"));
      // on mint (or any op that requires nav calculation), the base token price feed existance is asserted
      await expect(
        pool.mint(user1.address, TEN_ETHER, 0),
      ).to.be.revertedWithCustomError(pool, "BaseTokenPriceFeedError");
      const poolKey = {
        currency0: ethersLib.ZeroAddress,
        currency1: await grgToken.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(poolKey);
      await pool.mint(user1.address, TEN_ETHER, 0);
      poolData = await pool.getPoolParams();
      const spread = poolData.spread;
      const markup = (TEN_ETHER * spread) / 10000n;
      // spread is 5% by default
      expect(markup).to.be.eq((TEN_ETHER * 10n) / 10000n);
      // spread is applied on mint regardless of number of holders, total supply is net of spread to offset price impact
      poolData = await pool.getPoolTokens();
      expect(poolData.totalSupply).to.be.eq(TEN_ETHER - markup);
      await expect(
        pool.mint(user2.address, TEN_ETHER, 0),
      ).to.be.revertedWithCustomError(pool, "InvalidOperator");
      await connect(pool, user2).setOperator(user1.address, true);
      await pool.mint(user2.address, TEN_ETHER, 0);
      poolData = await pool.getPoolTokens();
      // spread is applied on mint
      expect(poolData.totalSupply).to.be.eq((TEN_ETHER - markup) * 2n);
      const updated = await pool.updateUnitaryValue.staticCall();
      await pool.updateUnitaryValue();
      poolData = await pool.getPoolTokens();
      expect(poolData.unitaryValue).to.be.eq(parseEther("1"));
      expect(updated[0]).to.be.eq(poolData.unitaryValue);
    });
  });

  describe("getPoolStorage", async () => {
    it("should return pool init params", async () => {
      const { pool, grgToken, user1 } = await setupTests();
      const poolData = await pool.getPoolStorage();
      expect(poolData.poolInitParams.name).to.be.eq("testpool");
      expect(poolData.poolInitParams.symbol).to.be.eq("TEST");
      expect(poolData.poolInitParams.decimals).to.be.eq(18n);
      expect(poolData.poolInitParams.owner).to.be.eq(user1.address);
      expect(poolData.poolInitParams.baseToken).to.be.eq(
        await grgToken.getAddress(),
      );
    });

    it("should return pool params", async () => {
      const { pool, user1 } = await setupTests();
      const poolData = await pool.getPoolStorage();
      // 30 days default minimum period
      expect(poolData.poolVariables.minPeriod).to.be.eq(2592000n);
      expect(poolData.poolVariables.spread).to.be.eq(10n);
      expect(poolData.poolVariables.transactionFee).to.be.eq(0n);
      expect(poolData.poolVariables.feeCollector).to.be.eq(user1.address);
      expect(poolData.poolVariables.kycProvider).to.be.eq(
        ethersLib.ZeroAddress,
      );
    });

    it("should return pool tokens struct", async () => {
      // this test should always return 18 with any token but special tokens (i.e. 6 decimals tokens)
      const { pool, grgToken, oracle, user1 } = await setupTests();
      let poolData = await pool.getPoolStorage();
      expect(poolData.poolTokensInfo.unitaryValue).to.be.eq(parseEther("1"));
      expect(poolData.poolTokensInfo.totalSupply).to.be.eq(0n);
      await grgToken.approve(await pool.getAddress(), parseEther("10"));
      const poolKey = {
        currency0: ethersLib.ZeroAddress,
        currency1: await grgToken.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(poolKey);
      await pool.mint(user1.address, parseEther("10"), 0);
      // TODO: storage should be updated after mint, this is probably not necessary. However, this one
      // goes through nav calculations, while first mint simply stores initial value
      await pool.updateUnitaryValue();
      poolData = await pool.getPoolStorage();
      expect(poolData.poolTokensInfo.unitaryValue).to.be.eq(parseEther("1"));
      // default spread is 0.1%, so total supply is net of spread applied on mint
      expect(poolData.poolTokensInfo.totalSupply).to.be.eq(parseEther("9.99"));
    });
  });

  describe("getUserAccount", async () => {
    it("should return UserAccount struct", async () => {
      const { pool, grgToken, oracle, user1 } = await setupTests();
      const { ethers } = await network.getOrCreate();
      let poolData = await pool.getUserAccount(user1.address);
      expect(poolData.userBalance).to.be.eq(0n);
      expect(poolData.activation).to.be.eq(0n);
      await grgToken.approve(await pool.getAddress(), parseEther("10"));
      const poolKey = {
        currency0: ethersLib.ZeroAddress,
        currency1: await grgToken.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(poolKey);
      const receipt = await (
        await pool.mint(user1.address, parseEther("10"), 0)
      ).wait();
      const block = await ethers.provider.getBlock(receipt!.blockNumber);
      poolData = await pool.getUserAccount(user1.address);
      expect(poolData.activation).to.be.eq(BigInt(block!.timestamp) + 2592000n);
      // default spread is 0.1%, and applied regardless of number of existing holders
      expect(poolData.userBalance).to.be.eq(parseEther("9.99"));
    });
  });

  describe("mint", async () => {
    it("should not allow minting if base token does not have a price feed", async () => {
      const { pool, grgToken, oracle, user1 } = await setupTests();
      const tokenAmountIn = parseEther("1");
      expect(await pool.decimals()).to.be.eq(18n);
      await expect(
        pool.mint(user1.address, tokenAmountIn, 0),
      ).to.be.revertedWithCustomError(pool, "BaseTokenPriceFeedError");
      const poolKey = {
        currency0: ethersLib.ZeroAddress,
        currency1: await grgToken.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(poolKey);
      await expect(
        pool.mint(user1.address, tokenAmountIn, tokenAmountIn),
      ).to.not.be.revertedWithCustomError(pool, "BaseTokenPriceFeedError");
    });

    it("should create new tokens with input tokens", async () => {
      const { pool, grgToken, oracle, user1 } = await setupTests();
      expect(await pool.totalSupply()).to.be.eq(0n);
      expect(await grgToken.balanceOf(await pool.getAddress())).to.be.eq(0n);
      // must create a price feed for base token before minting
      const poolKey = {
        currency0: ethersLib.ZeroAddress,
        currency1: await grgToken.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(poolKey);
      const dustAmount = parseEther("0.000999");
      expect(await pool.decimals()).to.be.eq(18n);
      await grgToken.approve(await pool.getAddress(), dustAmount);
      await expect(pool.mint(user1.address, dustAmount, 0))
        .to.be.revertedWithCustomError(pool, "PoolAmountSmallerThanMinimum")
        .withArgs(1000n);
      const tokenAmountIn = parseEther("1");
      await expect(
        pool.mint(user1.address, tokenAmountIn, 0),
      ).to.be.revertedWithCustomError(pool, "TokenTransferFromFailed");
      await grgToken.approve(await pool.getAddress(), tokenAmountIn);
      expect(
        await grgToken.allowance(user1.address, await pool.getAddress()),
      ).to.be.eq(tokenAmountIn);
      await expect(
        pool.mint(user1.address, tokenAmountIn, tokenAmountIn - 1n),
      ).to.be.revertedWithCustomError(pool, "PoolMintOutputAmount");
      const { spread } = await pool.getPoolParams();
      const markup = (tokenAmountIn * spread) / 10000n;
      await expect(
        pool.mint(user1.address, tokenAmountIn, tokenAmountIn - markup),
      ).to.not.be.revertedWithCustomError(pool, "PoolMintOutputAmount");
      // prev mint did not revert, so we need to approve again
      await grgToken.approve(await pool.getAddress(), tokenAmountIn);
      // first mint uses initial value, which is 1, so user tokens are equal to grg transferred to pool
      const userTokens = await pool.mint.staticCall(
        user1.address,
        tokenAmountIn,
        tokenAmountIn - markup,
      );
      await expect(pool.mint(user1.address, tokenAmountIn, 0))
        .to.emit(pool, "Transfer")
        .withArgs(ethersLib.ZeroAddress, user1.address, userTokens);
      expect(await pool.totalSupply()).to.be.not.eq(0n);
      let poolGrgBalance;
      poolGrgBalance = await grgToken.balanceOf(await pool.getAddress());
      // we executed 2 mints, so pool balance is double the first mint net of spread
      // TODO: verify why slight difference in last digits. Seems the mint results in slight difference due to spread rounding
      expect(poolGrgBalance).to.be.eq((tokenAmountIn - markup) * 2n);
      const userPoolBalance = await pool.balanceOf(user1.address);
      expect(userPoolBalance).to.be.eq(userTokens * 2n);
      // with 0 fees and without changing price, total supply will be equal to userbalance
      expect(userPoolBalance).to.be.eq(await pool.totalSupply());
      // with initial price 1, user tokens are equal to grg transferred to pool
      expect(userPoolBalance).to.be.eq(poolGrgBalance);
    });
  });

  describe("burn", async () => {
    it("should burn tokens with input tokens", async () => {
      const { pool, grgToken, oracle, user1 } = await setupTests();
      const tokenAmountIn = parseEther("1");
      await grgToken.approve(await pool.getAddress(), tokenAmountIn);
      const poolKey = {
        currency0: ethersLib.ZeroAddress,
        currency1: await grgToken.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(poolKey);
      const userTokens = await pool.mint.staticCall(
        user1.address,
        tokenAmountIn,
        0,
      );
      expect((await pool.getPoolParams()).minPeriod).to.be.eq(2592000n);
      await pool.mint(user1.address, tokenAmountIn, 0);
      expect(await pool.totalSupply()).to.be.not.eq(0n);
      expect(await pool.balanceOf(user1.address)).to.be.eq(userTokens);
      await expect(pool.burn(0, 0)).to.be.revertedWithCustomError(
        pool,
        "PoolBurnNullAmount",
      );
      let userPoolBalance = await pool.balanceOf(user1.address);
      // initial price is 1, so user balance is same as tokenAmountIn as long as no spread is applied
      const { spread } = await pool.getPoolParams();
      let markup = (tokenAmountIn * spread) / 10000n;
      expect(userPoolBalance).to.be.eq(tokenAmountIn - markup);
      await expect(
        pool.burn(userPoolBalance + 1n, 0),
      ).to.be.revertedWithCustomError(pool, "PoolBurnNotEnough");
      await expect(pool.burn(userPoolBalance, 0)).to.be.revertedWithCustomError(
        pool,
        "PoolMinimumPeriodNotEnough",
      );
      // previous assertions result in 1 second time travel per assertion
      await timeTravel({ seconds: 2592000 - 4, mine: false });
      await expect(
        pool.burn(userPoolBalance, tokenAmountIn + 1n),
      ).to.be.revertedWithCustomError(pool, "PoolMinimumPeriodNotEnough");
      await timeTravel({ seconds: 1, mine: false });
      await expect(
        pool.burn(userPoolBalance, userPoolBalance + 1n),
      ).to.be.revertedWithCustomError(pool, "PoolBurnOutputAmount");

      // when spread is applied, also requesting tokenAmountIn as minimum will revert
      await expect(
        pool.burn(userPoolBalance, userPoolBalance),
      ).to.be.revertedWithCustomError(pool, "PoolBurnOutputAmount");
      const netRevenue = await pool.burn.staticCall(userPoolBalance, 0);
      // the following is true with fee set as 0
      await expect(pool.burn(userPoolBalance, 1))
        .to.emit(grgToken, "Transfer")
        .withArgs(await pool.getAddress(), user1.address, netRevenue);
      const poolTotalSupply = await pool.totalSupply();
      expect(poolTotalSupply).to.be.eq(0n);
      expect(await pool.balanceOf(user1.address)).to.be.eq(0n);
      markup = (BigInt(userPoolBalance) * BigInt(spread)) / 10000n;
      // as long as price is 1, userPoolBalance - spread should be equal to netRevenue
      expect(userPoolBalance - markup).to.be.eq(netRevenue);
      const tokenDelta = tokenAmountIn - netRevenue;
      // 0.1% applied on tokenIn, plus 0.1% applied on the smaller tokenOut amount due to spread
      expect(tokenDelta).to.be.eq(parseEther("0.001999"));
      const poolGrgBalance = await grgToken.balanceOf(await pool.getAddress());
      expect(poolGrgBalance).to.be.not.eq(tokenDelta);
      // all spread tokens have gone to the fee collector, so pool balance is 0
      expect(poolGrgBalance).to.be.eq(0n);
      // if fee != 0 and caller not fee recipient, supply will not be 0
      const { unitaryValue } = await pool.getPoolTokens();
      userPoolBalance = userPoolBalance - markup;
      const decimals = await pool.decimals();
      // we need to multiply by fraction as js cannot handle the full product
      const revenue = (unitaryValue / 10n ** decimals) * userPoolBalance;
      expect(userPoolBalance - revenue).to.be.eq(0n);
      expect(netRevenue).to.be.eq(revenue);
    });

    it("should apply spread if user not only holder", async () => {
      const { pool, grgToken, oracle, user1, user2 } = await setupTests();
      await grgToken.approve(await pool.getAddress(), parseEther("20"));
      const poolKey = {
        currency0: ethersLib.ZeroAddress,
        currency1: await grgToken.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(poolKey);
      await pool.mint(user1.address, parseEther("10"), 0);
      await expect(
        pool.mint(user2.address, parseEther("5"), 0),
      ).to.be.revertedWithCustomError(pool, "InvalidOperator");
      await connect(pool, user2).setOperator(user1.address, true);
      await pool.mint(user2.address, parseEther("5"), 0);
      const { unitaryValue } = await pool.getPoolTokens();
      // unitary value unaffected by spread on first mint
      expect(unitaryValue).to.be.eq(parseEther("1"));
      await timeTravel({ seconds: 2592000, mine: true });

      const tx = await pool.burn(parseEther("1"), 0);
      await expect(tx)
        .to.emit(pool, "Transfer")
        .withArgs(user1.address, ethersLib.ZeroAddress, parseEther("1"));
      // 0.1% spread is applied on burn
      await expect(tx)
        .to.emit(grgToken, "Transfer")
        .withArgs(await pool.getAddress(), user1.address, parseEther("0.999"));
      await expect(tx).not.to.emit(pool, "NewNav");
      // unitary value changes after nav calculation due to spread applied
      expect((await pool.getPoolTokens()).unitaryValue - unitaryValue).to.be.lt(
        10n,
      );
    });
  });

  describe("burn 6-decimals pool", async () => {
    it("should burn tokens with 6-decimal base token", async () => {
      const { pool, factory, oracle, user1, user2 } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const source = `
            contract USDC {
                uint256 public totalSupply = 1e16;
                uint8 public decimals = 6;
                mapping(address => uint256) balances;
                function init() public { balances[msg.sender] = totalSupply; }
                function transfer(address to,uint amount) public { transferFrom(msg.sender,to,amount); }
                function transferFrom(address from,address to,uint256 amount) public {
                    balances[to] += amount; balances[from] -= amount;
                }
                function balanceOf(address _who) external view returns (uint256) {
                    return balances[_who];
                }
            }`;
      const usdc = await deployContract(user1 as any, source);
      await usdc.init();
      const newPool = await factory.createPool.staticCall(
        "USDC pool",
        "USDP",
        await usdc.getAddress(),
      );
      await factory.createPool("USDC pool", "USDP", await usdc.getAddress());
      const poolUsdc = await ethers.getContractAt(
        "SmartPool",
        newPool.newPoolAddress ?? newPool[0],
      );
      expect(await poolUsdc.decimals()).to.be.eq(6n);
      await usdc.transfer(user2.address, 10000000n);
      const poolKey = {
        currency0: ethersLib.ZeroAddress,
        currency1: await usdc.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(poolKey);
      const unit = 1000000n;
      const spread = (await poolUsdc.getPoolParams()).spread;
      const markup = (unit * spread) / 10000n;
      // first mint will store initial value in storage
      await expect(connect(poolUsdc, user2).mint(user2.address, unit, 1))
        .to.emit(poolUsdc, "Transfer")
        .and.to.emit(poolUsdc, "NewNav")
        .withArgs(user2.address, await poolUsdc.getAddress(), unit); // true as long as pool has initial price 1
      // second mint will calculate new value and store it in storage only if different
      await expect(connect(poolUsdc, user2).mint(user2.address, unit, 0))
        .to.emit(poolUsdc, "Transfer")
        .withArgs(ethersLib.ZeroAddress, user2.address, unit - markup)
        .and.to.not.emit(poolUsdc, "NewNav");
      await expect(
        connect(poolUsdc, user2).mint(user2.address, 999n, 0),
      ).to.be.revertedWithCustomError(poolUsdc, "NonFractionable");
      // TODO: verify setting minimum period to 2 will set to 10?
      await timeTravel({ seconds: 2592000, mine: true });
      const burnAmount = 6000n;
      await expect(connect(poolUsdc, user2).burn(burnAmount, 1))
        .to.emit(poolUsdc, "Transfer")
        .withArgs(user2.address, ethersLib.ZeroAddress, burnAmount)
        .and.to.not.emit(poolUsdc, "NewNav");
    });
  });

  describe("initializePool", async () => {
    it("should revert when already initialized", async () => {
      const { pool } = await setupTests();
      let symbol = ethersLib.encodeBytes32String("TEST");
      symbol = ethersLib.dataSlice(symbol, 0, 8);
      void symbol;
      await expect(pool.initializePool()).to.be.revertedWithCustomError(
        pool,
        "PoolAlreadyInitialized",
      );
    });
  });

  describe("burnForToken", async () => {
    it("should revert when token is not active", async () => {
      const { pool, grgToken, oracle, user1 } = await setupTests();
      await grgToken.approve(await pool.getAddress(), parseEther("10"));
      const poolKey = {
        currency0: ethersLib.ZeroAddress,
        currency1: await grgToken.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(poolKey);
      await pool.mint(user1.address, parseEther("10"), 0);
      await expect(
        pool.burnForToken(parseEther("10"), 0, ethersLib.ZeroAddress),
      ).to.be.revertedWithCustomError(pool, "PoolTokenNotActive");
    });

    it("should burn if token is active and base token balance small enough", async () => {
      const { pool, grgToken, oracle, user1 } = await setupTests();
      const { ethers } = await network.getOrCreate();
      await grgToken.approve(await pool.getAddress(), parseEther("20"));
      // nav calculations will sync uni v4 positions, but if (accidentally) a token does not have a price feed, the liquidity amount will be 0
      await expect(
        pool.mint(user1.address, parseEther("10"), 0),
      ).to.be.revertedWithCustomError(pool, "BaseTokenPriceFeedError");

      // re-deploy weth, as otherwise transaction won't revert (weth is converted 1-1 to ETH)
      const weth = await ethers.deployContract("WETH9");

      let poolKey = {
        currency0: ethersLib.ZeroAddress,
        currency1: await grgToken.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(poolKey);
      // as the new token (new weth) does not have a price feed, the token is not activated by minting
      await pool.mint(user1.address, parseEther("10"), 0);
      await expect(
        pool.burnForToken(0, 0, await weth.getAddress()),
      ).to.be.revertedWithCustomError(pool, "PoolTokenNotActive");

      // also a second mint, which performs nav calculations, will not activate the token
      await pool.mint(user1.address, parseEther("10"), 0);
      await expect(
        pool.burnForToken(0, 0, await weth.getAddress()),
      ).to.be.revertedWithCustomError(pool, "PoolTokenNotActive");

      // using a supported app is the only way to activate a token
      const PAIR = DEFAULT_PAIR;
      PAIR.poolKey = {
        currency0: ethersLib.ZeroAddress,
        currency1: await weth.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.TAKE, [
        PAIR.poolKey.currency1,
        await pool.getAddress(),
        parseEther("12"),
      ]);
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.V4_SWAP, [
        v4Planner.actions,
        v4Planner.params,
      ]);
      const { commands, inputs } = planner;
      const extPool = await ethers.getContractAt(
        "AUniswapRouter",
        await pool.getAddress(),
      );
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );
      await expect(
        user1.sendTransaction({
          to: await extPool.getAddress(),
          value: 0,
          data: encodedSwapData,
        }),
      ).to.be.revertedWithCustomError(pool, "TokenPriceFeedDoesNotExist");
      poolKey = {
        currency0: ethersLib.ZeroAddress,
        currency1: await weth.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(poolKey);
      // this call will activate the token
      await user1.sendTransaction({
        to: await extPool.getAddress(),
        value: 0,
        data: encodedSwapData,
      });
      await expect(
        pool.burnForToken(0, 0, await weth.getAddress()),
      ).to.be.revertedWithCustomError(pool, "PoolBurnNullAmount");
      await expect(
        pool.burnForToken(parseEther("1"), 0, await weth.getAddress()),
      ).to.be.revertedWithCustomError(pool, "PoolMinimumPeriodNotEnough");
      await timeTravel({ seconds: 2592000, mine: true });
      // need to deposit a bigger amount, as otherwise won't be able to reproduce case where target token is transferred
      await weth.deposit({ value: parseEther("100") });
      await weth.transfer(await pool.getAddress(), parseEther("100"));
      // Notice: if weth amount is smaller, the amounts will need to be adjusted
      // pool has enough tokens to pay with base token
      // update and verify the pool unitary value before the burn
      const updated = await pool.updateUnitaryValue.staticCall();
      await pool.updateUnitaryValue();
      const { unitaryValue } = await pool.getPoolTokens();
      // TODO: what is affecting unitary value calculation here?
      expect(unitaryValue).to.be.eq(parseEther("6.005005005005005005"));
      expect(updated[0]).to.be.eq(unitaryValue);
      // Notice: sometimes, changing order of tx affects twaps, and the amount needed to revert this must be adjusted
      await expect(
        pool.burnForToken(parseEther("16.7"), 0, await weth.getAddress()),
      ).to.be.revertedWithCustomError(pool, "TokenTransferFailed");
      const wethBalanceBefore = await weth.balanceOf(user1.address);
      const tx = await pool.burnForToken(
        parseEther("16.6"),
        0,
        await weth.getAddress(),
      );
      const wethBalanceAfter = await weth.balanceOf(user1.address);
      const wethReceived = wethBalanceAfter - wethBalanceBefore;
      expect(wethReceived).to.be.eq(parseEther("99.583400000000000000"));
      // as nav is higher (transferred 100 weth), the pool will not have enough base token to pay
      await expect(tx)
        .to.emit(pool, "Transfer")
        .withArgs(user1.address, ethersLib.ZeroAddress, parseEther("16.6"))
        .and.to.emit(weth, "Transfer")
        .withArgs(await pool.getAddress(), user1.address, wethReceived);
      await expect(tx).not.to.emit(grgToken, "Transfer");
    });

    it("should burn if ETH is input token", async () => {
      const { pool, grgToken, oracle, user1 } = await setupTests();
      const { ethers } = await network.getOrCreate();
      await grgToken.approve(await pool.getAddress(), parseEther("20"));
      const poolKey = {
        currency0: ethersLib.ZeroAddress,
        currency1: await grgToken.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(poolKey);
      await pool.mint(user1.address, parseEther("10"), 0);
      await expect(
        pool.burnForToken(0, 0, ethersLib.ZeroAddress),
      ).to.be.revertedWithCustomError(pool, "PoolTokenNotActive");
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.TAKE, [
        ethersLib.ZeroAddress,
        await pool.getAddress(),
        parseEther("12"),
      ]);
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.V4_SWAP, [
        v4Planner.actions,
        v4Planner.params,
      ]);
      const { commands, inputs } = planner;
      const extPool = await ethers.getContractAt(
        "AUniswapRouter",
        await pool.getAddress(),
      );
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );

      // this call will activate the token
      await user1.sendTransaction({
        to: await extPool.getAddress(),
        value: 0,
        data: encodedSwapData,
      });
      // verify native token has been activated
      const activeTokens = (await pool.getActiveTokens()).activeTokens;
      expect(activeTokens[0]).to.be.eq(ethersLib.ZeroAddress);
      expect(activeTokens.length).to.be.eq(1);
      await expect(
        pool.burnForToken(0, 0, ethersLib.ZeroAddress),
      ).to.be.revertedWithCustomError(pool, "PoolBurnNullAmount");
      await expect(
        pool.burnForToken(parseEther("1"), 0, ethersLib.ZeroAddress),
      ).to.be.revertedWithCustomError(pool, "PoolMinimumPeriodNotEnough");
      await timeTravel({ seconds: 2592000, mine: true });
      await expect(
        pool.burnForToken(parseEther("1"), 0, ethersLib.ZeroAddress),
      ).to.be.revertedWithCustomError(pool, "BaseTokenBalance");
      await user1.sendTransaction({
        to: await pool.getAddress(),
        value: parseEther("98"),
      });
      await pool.updateUnitaryValue();
      const { unitaryValue } = await pool.getPoolTokens();
      // TODO: what is affecting unitary value calculation here?
      expect(unitaryValue).to.be.eq(parseEther("11.007971106066621173"));
      await expect(
        pool.burnForToken(parseEther("0.08"), 0, ethersLib.ZeroAddress),
      ).to.be.revertedWithCustomError(pool, "BaseTokenBalance");
      await expect(
        pool.burnForToken(parseEther("9.1"), 0, ethersLib.ZeroAddress),
      ).to.be.revertedWithCustomError(pool, "NativeTransferFailed");
      await expect(pool.burnForToken(parseEther("8"), 0, ethersLib.ZeroAddress))
        .to.emit(pool, "Transfer")
        .withArgs(user1.address, ethersLib.ZeroAddress, parseEther("8"))
        .and.to.not.emit(grgToken, "Transfer");
    });

    it("should apply spread if user not only holder", async () => {
      const { pool, grgToken, weth, oracle, user1, user2 } = await setupTests();
      const { ethers } = await network.getOrCreate();
      // need to deposit a bigger amount, as otherwise won't be able to reproduce case where target token is transferred
      await weth.deposit({ value: parseEther("100") });
      await weth.transfer(await pool.getAddress(), parseEther("100"));
      await grgToken.approve(await pool.getAddress(), parseEther("20"));
      // we only need to create price feed for grg, as weth is converted 1-1 to eth
      const poolKey = {
        currency0: ethersLib.ZeroAddress,
        currency1: await grgToken.getAddress(),
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(poolKey);
      await pool.mint(user1.address, parseEther("10"), 0);
      // activate token via app
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.TAKE, [
        await weth.getAddress(),
        await pool.getAddress(),
        parseEther("12"),
      ]);
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.V4_SWAP, [
        v4Planner.actions,
        v4Planner.params,
      ]);
      const { commands, inputs } = planner;
      const extPool = await ethers.getContractAt(
        "AUniswapRouter",
        await pool.getAddress(),
      );
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );

      // this call will activate the token
      await user1.sendTransaction({
        to: await extPool.getAddress(),
        value: 0,
        data: encodedSwapData,
      });
      // minting again to activate token via nav calculations
      await expect(
        pool.mint(user2.address, parseEther("10"), 0),
      ).to.be.revertedWithCustomError(pool, "InvalidOperator");
      await connect(pool, user2).setOperator(user1.address, true);
      await pool.mint(user2.address, parseEther("5"), 0);
      // unitary value does not include spread to pool, but includes weth balance
      const { unitaryValue } = await pool.getPoolTokens();
      // @notice protocol uses a twap, which changes according to how the previous transactions are mined (changing their order will affect the twap)
      expect(unitaryValue).to.be.eq(parseEther("11.212215414353695074"));
      await timeTravel({ seconds: 2592000, mine: true });
      const wethBalanceBefore = await weth.balanceOf(user1.address);
      const tx = await pool.burnForToken(
        parseEther("8"),
        0,
        await weth.getAddress(),
      );
      const wethBalanceAfter = await weth.balanceOf(user1.address);
      const wethReceived = wethBalanceAfter - wethBalanceBefore;
      // 5% spread applied on burn
      expect(wethReceived).to.be.eq(parseEther("87.833755630297091111"));
      await expect(tx)
        .to.emit(pool, "Transfer")
        .withArgs(user1.address, ethersLib.ZeroAddress, parseEther("8"))
        .and.to.emit(weth, "Transfer")
        .withArgs(await pool.getAddress(), user1.address, wethReceived);
      await expect(tx).not.to.emit(grgToken, "Transfer");
      // twap has not changed, so unitary value is not updated
      // TODO: verify that unitary value changes slightly due to spread
      await expect(tx).to.emit(pool, "NewNav"); // spread will result in slight unitary value change
      // unitary value does not change until next nav calculation
      expect((await pool.getPoolTokens()).unitaryValue - unitaryValue).to.be.lt(
        10n,
      );
    });
  });
});
