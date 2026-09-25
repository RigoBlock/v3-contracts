import { expect } from "chai";
import { network } from "hardhat";
import { ethers as ethersLib, parseEther } from "ethers";
import { DEADLINE } from "../shared/constants";
import { CommandType, RoutePlanner } from "../shared/planner";
import { Actions, V4Planner } from "../shared/v4Planner";
import { deployContract, timeTravel } from "../utils/utils";
import { connect, getFixedGasSigners } from "../shared/helper";
import { createFixture } from "../utils/fixtures";

describe("Proxy", async () => {
  const MAX_TICK_SPACING = 32767;

  const setupTests = createFixture(["tests-setup"], async ({ get }) => {
    const [user1, user2, user3] = await getFixedGasSigners();
    const { ethers } = await network.getOrCreate();
    const factory = await ethers.getContractAt(
      "RigoblockPoolProxyFactory",
      (await get("RigoblockPoolProxyFactory")).address,
    );
    const authority = await ethers.getContractAt(
      "Authority",
      (await get("Authority")).address,
    );
    const uniswapV3Npm = await ethers.getContractAt(
      "MockUniswapNpm",
      (await get("MockUniswapNpm")).address,
    );
    const uniswapV4PosmAddress = (await get("MockUniswapPosm")).address;
    const poolAddress = (
      await factory.createPool.staticCall(
        "testpool",
        "TEST",
        ethersLib.ZeroAddress,
      )
    )[0];
    await factory.createPool("testpool", "TEST", ethersLib.ZeroAddress);
    const pool = await ethers.getContractAt("SmartPool", poolAddress);
    // the disabled ERC20 methods are served by the EERC20 extension via fallback
    const poolAsErc20 = await ethers.getContractAt("EERC20", poolAddress);
    const uniRouter = await ethers.deployContract("MockUniUniversalRouter", [
      uniswapV4PosmAddress,
    ]);
    const wethAddress = await uniswapV3Npm.WETH9();
    const aUniswapRouter = await ethers.deployContract("AUniswapRouter", [
      await uniRouter.getAddress(),
      uniswapV4PosmAddress,
      wethAddress,
    ]);
    await authority.setAdapter(await aUniswapRouter.getAddress(), true);
    // "3593564c": "execute(bytes calldata, bytes[] calldata, uint256)"
    await authority.addMethod("0x3593564c", await aUniswapRouter.getAddress());
    return {
      authority,
      factory,
      pool,
      poolAsErc20,
      uniswapV3Npm,
      uniswapV4Posm: await ethers.getContractAt(
        "MockUniswapPosm",
        uniswapV4PosmAddress,
      ),
      oracle: await ethers.getContractAt(
        "MockOracle",
        (await get("MockOracle")).address,
      ),
      weth: await ethers.getContractAt("WETH9", wethAddress),
      user1,
      user2,
      user3,
    };
  });

  describe("receive", async () => {
    it("should revert if direct call to implementation", async () => {
      const { factory, user1 } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const etherAmount = parseEther("5");
      const implementation = await factory.implementation();
      const implementationContract = await ethers.getContractAt(
        "SmartPool",
        implementation,
      );
      await expect(
        user1.sendTransaction({ to: implementation, value: etherAmount }),
      ).to.be.revertedWithCustomError(
        implementationContract,
        "PoolImplementationDirectCallNotAllowed",
      );
    });

    it("should receive ether", async () => {
      const { pool, user1 } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const etherAmount = parseEther("5");
      const poolAddress = await pool.getAddress();
      await user1.sendTransaction({ to: poolAddress, value: etherAmount });
      expect(await ethers.provider.getBalance(poolAddress)).to.be.deep.eq(
        etherAmount,
      );
    });
  });

  describe("poolStorage", async () => {
    it("should return pool name from new pool", async () => {
      const { pool } = await setupTests();
      const poolData = await pool.getPool();
      expect(poolData.name).to.be.eq("testpool");
    });

    it("should return pool owner", async () => {
      const { pool, user1 } = await setupTests();
      expect(await pool.owner()).to.be.eq(user1.address);
    });
  });

  describe("erc20", async () => {
    it("should revert on transfer", async () => {
      const { pool, poolAsErc20, user1, user2 } = await setupTests();
      const etherAmount = parseEther("1");
      await pool.mint(user1.address, etherAmount, 0, { value: etherAmount });
      await expect(
        poolAsErc20.transfer(
          user2.address,
          await pool.balanceOf(user1.address),
        ),
      ).to.be.revertedWithCustomError(
        poolAsErc20,
        "PoolTokenOperationNotAllowed",
      );
    });

    it("should revert on transferFrom", async () => {
      const { pool, poolAsErc20, user1, user2 } = await setupTests();
      const etherAmount = parseEther("1");
      await pool.mint(user1.address, etherAmount, 0, { value: etherAmount });
      await expect(
        poolAsErc20.transferFrom(
          user1.address,
          user2.address,
          await pool.balanceOf(user1.address),
        ),
      ).to.be.revertedWithCustomError(
        poolAsErc20,
        "PoolTokenOperationNotAllowed",
      );
    });

    it("should revert on approve", async () => {
      const { poolAsErc20, user2 } = await setupTests();
      await expect(
        poolAsErc20.approve(user2.address, parseEther("1")),
      ).to.be.revertedWithCustomError(
        poolAsErc20,
        "PoolTokenOperationNotAllowed",
      );
    });

    it("should return zero allowance", async () => {
      const { poolAsErc20, user1, user2 } = await setupTests();
      expect(
        await poolAsErc20.allowance(user1.address, user2.address),
      ).to.be.eq(0n);
    });
  });

  describe("setTransactionFee", async () => {
    it("should set the transaction fee", async () => {
      const { pool } = await setupTests();
      await pool.setTransactionFee(2);
      const poolData = await pool.getPoolParams();
      expect(poolData.transactionFee).to.be.eq(2n);
    });

    it("should not set fee if caller not owner", async () => {
      const { pool, user2 } = await setupTests();
      await pool.setOwner(user2.address);
      await expect(pool.setTransactionFee(2)).to.be.revertedWithCustomError(
        pool,
        "PoolCallerIsNotOwner",
      );
    });

    it("should not set fee higher than 1 percent", async () => {
      const { pool } = await setupTests();
      await expect(pool.setTransactionFee(101))
        .to.be.revertedWithCustomError(pool, "PoolFeeBiggerThanMax")
        .withArgs(100n);
    });
  });

  describe("setOwner", async () => {
    it("should revert if caller not owner", async () => {
      const { pool, user2 } = await setupTests();
      await expect(
        connect(pool, user2).setOwner(user2.address),
      ).to.be.revertedWithCustomError(pool, "PoolCallerIsNotOwner");
    });

    it("should revert if new owner null address", async () => {
      const { pool } = await setupTests();
      await expect(
        pool.setOwner(ethersLib.ZeroAddress),
      ).to.be.revertedWithCustomError(pool, "PoolNullOwnerInput");
    });

    it("should set owner", async () => {
      const { pool, user1, user2 } = await setupTests();
      const owner = await pool.owner();
      expect(owner).to.be.eq(user1.address);
      const newOwner = user2.address;
      await expect(pool.setOwner(newOwner))
        .to.emit(pool, "NewOwner")
        .withArgs(owner, newOwner);
    });
  });

  describe("mint", async () => {
    it("should create new tokens", async () => {
      const { pool, user1 } = await setupTests();
      expect(await pool.totalSupply()).to.be.eq(0n);
      const etherAmount = parseEther("0.95");
      const amount = await pool.mint.staticCall(user1.address, etherAmount, 0, {
        value: etherAmount,
      });
      void amount;
      await expect(
        pool.mint(user1.address, parseEther("2"), 0, { value: etherAmount }),
      ).to.be.revertedWithCustomError(pool, "PoolMintAmountIn");
      const { spread } = await pool.getPoolParams();
      expect(spread).to.be.eq(10n); // default spread is 0.1%
      const expectedMintedAmount =
        etherAmount - (etherAmount * spread) / 10000n;
      await expect(
        pool.mint(user1.address, etherAmount, 0, { value: etherAmount }),
      )
        .to.emit(pool, "Transfer")
        .withArgs(ethersLib.ZeroAddress, user1.address, expectedMintedAmount);
      expect(await pool.totalSupply()).to.be.not.eq(0n);
      const userBalance = await pool.balanceOf(user1.address);
      expect(userBalance).to.be.eq(expectedMintedAmount);
      expect(userBalance.toString()).to.be.eq(expectedMintedAmount.toString());
    });

    it("should revert with invalid recipient", async () => {
      const { pool } = await setupTests();
      const etherAmount = parseEther("0.00012");
      await expect(
        pool.mint(ethersLib.ZeroAddress, etherAmount, 0, {
          value: etherAmount,
        }),
      ).to.be.revertedWithCustomError(pool, "PoolMintInvalidRecipient");
    });

    it("should revert with order below minimum", async () => {
      const { pool, user1 } = await setupTests();
      const etherAmount = parseEther("0.00012");
      await expect(
        pool.mint(user1.address, etherAmount, 0, { value: etherAmount }),
      )
        .to.be.revertedWithCustomError(pool, "PoolAmountSmallerThanMinimum")
        .withArgs(1000n);
    });

    it("should revert if user not whitelisted when whitelist enabled", async () => {
      const { pool, user1 } = await setupTests();
      const etherAmount = parseEther("1");
      const source = `
            contract Kyc {
                mapping(address => bool) whitelisted;
                function whitelistUser(address user) public { whitelisted[user] = true; }
                function isWhitelistedUser(address user) public view returns (bool) { return whitelisted[user] == true; }
            }`;
      const kyc = await deployContract(user1 as any, source);
      const kycAddress = await kyc.getAddress();
      await pool.setKycProvider(kycAddress);
      const recipient = user1.address;
      // TODO: verify we are reverting when recipient is not whitelisted, vs when caller is not whitelisted
      await expect(
        pool.mint(recipient, etherAmount, 0, { value: etherAmount }),
      ).to.be.revertedWithCustomError(pool, "PoolCallerNotWhitelisted");
      await kyc.whitelistUser(recipient);
      const mintedAmount = await pool.mint.staticCall(
        recipient,
        etherAmount,
        0,
        {
          value: etherAmount,
        },
      );
      await expect(pool.mint(recipient, etherAmount, 0, { value: etherAmount }))
        .to.emit(pool, "Transfer")
        .withArgs(ethersLib.ZeroAddress, recipient, mintedAmount);
    });

    it("should allocate fee tokens to fee recipient", async () => {
      const { pool, user1, user2, user3 } = await setupTests();
      const etherAmount = parseEther("1");
      const transactionFee = 50n;
      await pool.setTransactionFee(transactionFee);
      let feeCollector = (await pool.getPoolParams()).feeCollector;
      expect(await pool.owner()).to.be.eq(feeCollector);
      // when fee collector is mint recipient, fee collector receives full amount
      let mintedAmount = await pool.mint.staticCall(
        user1.address,
        etherAmount,
        0,
        {
          value: etherAmount,
        },
      );
      await expect(
        pool.mint(user1.address, etherAmount, 0, { value: etherAmount }),
      )
        .to.emit(pool, "Transfer")
        .withArgs(ethersLib.ZeroAddress, feeCollector, mintedAmount);
      // when fee collector not same as recipient, fee gets allocated to fee recipient
      mintedAmount = await connect(pool, user2).mint.staticCall(
        user2.address,
        etherAmount,
        0,
        {
          value: etherAmount,
        },
      );
      // minted amount changes as second holder is charged the spread
      const fee = (mintedAmount / 10000n) * transactionFee;
      void fee;
      // TODO: verify why we cannot get the correct log arguments
      await expect(
        pool.mint(user2.address, parseEther("10"), 0),
      ).to.be.revertedWithCustomError(pool, "InvalidOperator");
      await connect(pool, user2).setOperator(user1.address, true);
      await expect(
        pool.mint(user2.address, etherAmount, 0, { value: etherAmount }),
      ).to.emit(pool, "Transfer"); //.withArgs(ZeroAddress, feeCollector, fee)
      //.and.to.emit(pool, "Transfer").withArgs(ZeroAddress, user2.address, mintedAmount)
      // fee collector must approve receiving fees
      await connect(pool, user3).setOperator(user1.address, true);
      await pool.changeFeeCollector(user3.address);
      feeCollector = (await pool.getPoolParams()).feeCollector;
      expect(feeCollector).to.be.eq(user3.address);
      // this time, user1 is charged the spread, which will be same as user2's minted amount spread
      await pool.mint(user1.address, etherAmount, 0, { value: etherAmount });
      // TODO: verify why we have a ≃ 1.2% difference in the following comparison
      //expect(await pool.balanceOf(user3.address)).to.be.eq(fee)
    });

    it("should read from storage with previously burnt supply", async () => {
      const { pool, user1 } = await setupTests();
      const { ethers } = await network.getOrCreate();
      let etherAmount = parseEther("0.1");
      const poolAddress = await pool.getAddress();
      // we forward some ether to the pool, so we can test edge case where nav would be affected
      await user1.sendTransaction({ to: poolAddress, value: etherAmount * 4n });
      expect((await pool.getPoolTokens()).unitaryValue).to.be.eq(
        parseEther("1"),
      );
      // the fist mint will use the initial nav, or the previously stored one (in case of mint after total burn)
      await pool.mint(user1.address, etherAmount, 0, { value: etherAmount });
      const { spread } = await pool.getPoolParams();
      const expectedMintedAmount =
        etherAmount - (etherAmount * spread) / 10000n;
      expect(await pool.totalSupply()).to.be.eq(expectedMintedAmount);
      expect((await pool.getPoolTokens()).unitaryValue).to.be.eq(
        parseEther("1"),
      );
      let ethBalance = await ethers.provider.getBalance(poolAddress);
      expect(ethBalance).to.be.eq(
        etherAmount * 5n - (spread * etherAmount) / 10000n,
      );
      await timeTravel({ seconds: 2592000, mine: true });
      // initially minted pool tokens are same as ether amount minus spread
      await pool.burn(expectedMintedAmount, 1);
      ethBalance = await ethers.provider.getBalance(poolAddress);
      expect(ethBalance).to.be.eq(1n); // leftover wei due to spread calculation rounding
      expect(await pool.totalSupply()).to.be.eq(0n);
      expect((await pool.getPoolTokens()).unitaryValue).to.be.eq(
        parseEther("5.004004004004004004"),
      );
      await pool.mint(user1.address, etherAmount, 0, { value: etherAmount });
      ethBalance = await ethers.provider.getBalance(poolAddress);
      expect(ethBalance).to.be.eq(expectedMintedAmount + 1n); // leftover wei due to spread calculation rounding
      // a higher unitary value results in a lower amount of pool tokens
      expect(await pool.totalSupply()).to.be.eq(
        parseEther("0.019964012802560512"),
      );
      expect((await pool.getPoolTokens()).unitaryValue).to.be.eq(
        parseEther("5.004004004004004004"),
      );
    });

    it("should not include univ3npm position tokens", async () => {
      const { pool, uniswapV3Npm, user1 } = await setupTests();
      const poolAddress = await pool.getAddress();
      expect(await uniswapV3Npm.balanceOf(poolAddress)).to.be.eq(0n);
      // mint univ3 position from user1, as univ3 will add tokenId to recipient. MockUniswapNpm does not use input params
      // other than the recipient, and will return weth balance which will return 0 in oracle, as won't be able to find price feed?
      // TODO: we could use mint params in mockuniv3npm
      const mintParams = {
        token0: ethersLib.ZeroAddress,
        token1: ethersLib.ZeroAddress,
        fee: 1,
        tickLower: 1,
        tickUpper: 1,
        amount0Desired: 1,
        amount1Desired: 1,
        amount0Min: 1,
        amount1Min: 1,
        recipient: poolAddress,
        deadline: 1,
      };
      await uniswapV3Npm.mint(mintParams);
      expect(await uniswapV3Npm.balanceOf(poolAddress)).to.be.eq(1n);
      const etherAmount = parseEther("11");
      const { spread } = await pool.getPoolParams();
      const expectedMintedAmount =
        etherAmount - (etherAmount * spread) / 10000n;
      // first mint will only update storage with inintial value and not include the univ3 position tokens
      // pools from versions before v4 will already have a stored value, so will include univ3 position tokens
      await expect(
        pool.mint(user1.address, etherAmount, 1, { value: etherAmount }),
      )
        .to.emit(pool, "Transfer")
        .withArgs(ethersLib.ZeroAddress, user1.address, expectedMintedAmount);
      // first mint will update storage with initial value and will use that one to calculate minted tokens
      expect(await pool.totalSupply()).to.be.eq(expectedMintedAmount);
      // TODO: could calculate the value from positions(id) and verify new nav
      // TODO: should also test with very small values returned (as previously was 1.00000000000000001)

      // updating nav will prompt going through position tokens, updating active tokens in storage, making a call to oracle extension
      await expect(pool.updateUnitaryValue()).to.not.emit(pool, "NewNav");
      expect((await pool.getPoolTokens()).unitaryValue).to.be.deep.eq(
        parseEther("1"),
      );
      await expect(
        pool.mint(user1.address, etherAmount, 1, { value: etherAmount }),
      )
        .to.emit(pool, "Transfer")
        .withArgs(ethersLib.ZeroAddress, user1.address, expectedMintedAmount)
        .and.to.not.emit(pool, "NewNav");
      expect((await pool.getPoolTokens()).unitaryValue).to.be.deep.eq(
        parseEther("1"),
      );
    });
  });

  describe("burn", async () => {
    it("should burn tokens", async () => {
      const { pool, user1 } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const etherAmount = parseEther("1");
      const poolAddress = await pool.getAddress();
      await pool.mint(user1.address, etherAmount, 0, { value: etherAmount });
      const userPoolBalance = await pool.balanceOf(user1.address);
      // TODO: following comment requires decreasing lockup to 1 second, however minimum is now 10 seconds
      // and 2-block attacks are possible with 1-2 block lockup
      // TODO: should be able to burn after 1 second, requires 2
      await timeTravel({ seconds: 2592000, mine: true });
      const { spread } = await pool.getPoolParams();
      const netAmount = etherAmount - (etherAmount * spread) / 10000n;
      const poolBalance = await ethers.provider.getBalance(poolAddress);
      expect(poolBalance).to.be.deep.eq(netAmount);
      const preBalance = await ethers.provider.getBalance(user1.address);
      const netRevenue = await pool.burn.staticCall(userPoolBalance, 1);
      //const { unitaryValue } = await pool.getPoolTokens()
      expect(netRevenue).to.be.eq(
        poolBalance - (poolBalance * spread) / 10000n,
      );
      // the following is true with fee set as 0
      await expect(pool.burn(userPoolBalance, 1))
        .to.emit(pool, "Transfer")
        .withArgs(user1.address, ethersLib.ZeroAddress, userPoolBalance);
      expect(await ethers.provider.getBalance(poolAddress)).to.be.deep.eq(0n);
      const postBalance = await ethers.provider.getBalance(user1.address);
      expect(postBalance).to.be.gt(preBalance);
    });

    // assert burn cannot be denied by anyone. Assumes the user has not given mint access to anyone else (i.e. an attacker)
    it("should not allow dos by frontrun with mint to holder", async () => {
      const { pool, user1, user2 } = await setupTests();
      const etherAmount = parseEther("1");
      await pool.mint(user1.address, etherAmount, 0, { value: etherAmount });
      const userPoolBalance = await pool.balanceOf(user1.address);
      await timeTravel({ seconds: 2592000, mine: true });
      await expect(
        connect(pool, user2).mint(user1.address, etherAmount, 0, {
          value: etherAmount,
        }),
      ).to.be.revertedWithCustomError(pool, "InvalidOperator");
      // the following is true with fee set as 0
      await expect(pool.burn(userPoolBalance, 1))
        .to.emit(pool, "Transfer")
        .withArgs(user1.address, ethersLib.ZeroAddress, userPoolBalance);
    });

    it("should allocate fee tokens to fee recipient", async () => {
      const { pool, user1, user3 } = await setupTests();
      const etherAmount = parseEther("1");
      await pool.mint(user1.address, etherAmount, 0, { value: etherAmount });
      await timeTravel({ seconds: 2592000, mine: true });
      const transactionFee = 50n;
      await pool.setTransactionFee(transactionFee);
      let userPoolBalance = await pool.balanceOf(user1.address);
      await expect(pool.burn(userPoolBalance / 2n, 1))
        .to.emit(pool, "Transfer")
        .withArgs(user1.address, ethersLib.ZeroAddress, userPoolBalance / 2n);
      const feeCollector = user3;
      // fee collector must approve receiving fees
      await connect(pool, feeCollector).setOperator(user1.address, true);
      await pool.changeFeeCollector(feeCollector.address);
      userPoolBalance = await pool.balanceOf(user1.address);
      const fee = (userPoolBalance / 10000n) * transactionFee;
      const burntAmount = userPoolBalance - fee;
      await expect(pool.burn(userPoolBalance, 1))
        .to.emit(pool, "Transfer")
        .withArgs(user1.address, feeCollector.address, fee)
        .and.to.emit(pool, "Transfer")
        .withArgs(user1.address, ethersLib.ZeroAddress, burntAmount);
    });

    // assert burn cannot be denied by pool operator. Assumes the user has not given mint access to the pool operator (can be revoked at any time)
    it("should not allow dos by setting holder as fee recipient", async () => {
      const { pool, user1, user2, user3 } = await setupTests();
      const etherAmount = parseEther("1");
      await connect(pool, user3).mint(user3.address, etherAmount, 0, {
        value: etherAmount,
      });
      await timeTravel({ seconds: 2592000, mine: true });
      const transactionFee = 50n;
      await pool.setTransactionFee(transactionFee);
      let userPoolBalance = await pool.balanceOf(user3.address);
      // pool operator must set fee recipient as the target wallet, but this is not possible unless the target wallet has given permission to the pool operator
      await expect(
        pool.changeFeeCollector(user3.address),
      ).to.be.revertedWithCustomError(pool, "InvalidOperator");
      // now, any wallet can trigger him receiving the fee in locked pool tokens
      await expect(
        connect(pool, user3).mint(user2.address, etherAmount, 0, {
          value: etherAmount,
        }),
      ).to.be.revertedWithCustomError(pool, "InvalidOperator");
      await connect(pool, user2).mint(user2.address, etherAmount, 0, {
        value: etherAmount,
      });
      const fee = (userPoolBalance / 10000n) * transactionFee;
      const burntAmount = userPoolBalance - fee;
      await expect(connect(pool, user3).burn(userPoolBalance, 1))
        .to.emit(pool, "Transfer")
        .withArgs(user3.address, user1.address, fee)
        .and.to.emit(pool, "Transfer")
        .withArgs(user3.address, ethersLib.ZeroAddress, burntAmount);
    });
  });

  it("should revert without enough base token balance", async () => {
    const { pool, weth, oracle, user1 } = await setupTests();
    const { ethers } = await network.getOrCreate();
    const etherAmount = parseEther("11");
    const poolAddress = await pool.getAddress();
    const wethAddress = await weth.getAddress();
    await pool.mint(user1.address, etherAmount, 1, { value: etherAmount });
    // transfer weth and activate it, so that nav increases, but balance is 0
    await weth.deposit({ value: etherAmount });
    await weth.transfer(poolAddress, etherAmount);
    await pool.updateUnitaryValue();
    const unitaryValue = (await pool.getPoolTokens()).unitaryValue;
    // the token is not active, so it will not be included in the nav
    expect(unitaryValue).to.be.eq(parseEther("1"));
    const v4Planner: V4Planner = new V4Planner();
    v4Planner.addAction(Actions.TAKE, [
      wethAddress,
      poolAddress,
      parseEther("12"),
    ]);
    const planner: RoutePlanner = new RoutePlanner();
    planner.addCommand(CommandType.V4_SWAP, [
      v4Planner.actions,
      v4Planner.params,
    ]);
    const { commands, inputs } = planner;
    const extPool = await ethers.getContractAt("AUniswapRouter", poolAddress);
    const encodedSwapData = extPool.interface.encodeFunctionData(
      "execute(bytes,bytes[],uint256)",
      [commands, inputs, DEADLINE],
    );
    const oracleAddress = await oracle.getAddress();
    const poolKey = {
      currency0: ethersLib.ZeroAddress,
      currency1: wethAddress,
      fee: 0,
      tickSpacing: MAX_TICK_SPACING,
      hooks: oracleAddress,
    };
    await oracle.initializeObservations(poolKey);
    // this call will activate the token
    await user1.sendTransaction({
      to: poolAddress,
      value: 0,
      data: encodedSwapData,
    });
    await timeTravel({ seconds: 2592000, mine: true });
    await expect(pool.burn(parseEther("6"), 1)).to.be.revertedWithCustomError(
      pool,
      "NativeTransferFailed",
    );
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

  describe("updateUnitaryValue", async () => {
    it("should update storage when caller is any wallet", async () => {
      const { pool, user1, user2 } = await setupTests();
      const poolAddress = await pool.getAddress();
      await pool.setOwner(user2.address);
      // First call initializes NAV to 10^decimals and writes to storage
      // msg.sender is still user1 (the one calling updateUnitaryValue)
      await expect(pool.updateUnitaryValue())
        .to.emit(pool, "NewNav")
        .withArgs(user1.address, poolAddress, parseEther("1"));
      const etherAmount = parseEther("0.1");
      // Mint calls _updateNav() but NAV already initialized, so no NewNav emission
      await expect(
        pool.mint(user1.address, etherAmount, 0, { value: etherAmount }),
      ).to.not.emit(pool, "NewNav");
      await expect(pool.updateUnitaryValue()).to.not.emit(pool, "NewNav");
    });

    it("should update storage when caller is owner", async () => {
      const { pool, user1 } = await setupTests();
      const poolAddress = await pool.getAddress();
      // First call initializes NAV to 10^decimals and writes to storage
      await expect(pool.updateUnitaryValue())
        .to.emit(pool, "NewNav")
        .withArgs(user1.address, poolAddress, parseEther("1"));
      const etherAmount = parseEther("0.1");
      // Mint calls _updateNav() but NAV already initialized, so no NewNav emission
      await expect(
        pool.mint(user1.address, etherAmount, 0, { value: etherAmount }),
      ).to.not.emit(pool, "NewNav");
      await expect(pool.updateUnitaryValue()).to.not.emit(pool, "NewNav");
    });

    it("should update unitary value when base token balance increases", async () => {
      const { pool, user1 } = await setupTests();
      const poolAddress = await pool.getAddress();
      let etherAmount = parseEther("0.1");
      await pool.mint(user1.address, etherAmount, 0, { value: etherAmount });
      etherAmount = parseEther("0.4");
      await user1.sendTransaction({ to: poolAddress, value: etherAmount });
      // spread is applied on mint amount and transferred token, so the native transfer amount has higher impact on nav
      await expect(pool.updateUnitaryValue())
        .to.emit(pool, "NewNav")
        .withArgs(
          user1.address,
          poolAddress,
          parseEther("5.004004004004004004"),
        );
    });

    it("should handle previously burnt supply gracefully", async () => {
      const { pool, user1 } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const poolAddress = await pool.getAddress();
      let etherAmount = parseEther("0.1");
      await pool.mint(user1.address, etherAmount, 0, { value: etherAmount });
      let ethBalance = await ethers.provider.getBalance(poolAddress);
      const { spread } = await pool.getPoolParams();
      expect(ethBalance).to.be.eq(
        etherAmount - (etherAmount * spread) / 10000n,
      );
      await timeTravel({ seconds: 2592000, mine: true });
      await pool.burn(etherAmount - (etherAmount * spread) / 10000n, 1);
      ethBalance = await ethers.provider.getBalance(poolAddress);
      expect(ethBalance).to.be.eq(0n);
      // With zero supply, returns stored NAV without revert
      await expect(pool.updateUnitaryValue()).to.not.emit(pool, "NewNav");
    });
  });

  describe("setOperator", async () => {
    // used when someone is minting on behalf of the user
    it("should set operator for user", async () => {
      const { pool, user1, user2 } = await setupTests();
      let isOperator = await pool.isOperator(user1.address, user2.address);
      await expect(isOperator).to.not.be.true;
      await expect(pool.setOperator(user2.address, true))
        .to.emit(pool, "OperatorSet")
        .withArgs(user1.address, user2.address, true);
      isOperator = await pool.isOperator(user1.address, user2.address);
      await expect(isOperator).to.be.true;
    });
  });

  describe("setKycProvider", async () => {
    it("should revert if caller not pool owner", async () => {
      const { pool, user2 } = await setupTests();
      await expect(
        connect(pool, user2).setKycProvider(user2.address),
      ).to.be.revertedWithCustomError(pool, "PoolCallerIsNotOwner");
    });

    it("should set pool kyc provider", async () => {
      const { pool, user2 } = await setupTests();
      const poolAddress = await pool.getAddress();
      expect((await pool.getPoolParams()).kycProvider).to.be.eq(
        ethersLib.ZeroAddress,
      );
      await expect(
        pool.setKycProvider(user2.address),
      ).to.be.revertedWithCustomError(pool, "PoolInputIsNotContract");
      await expect(pool.setKycProvider(poolAddress))
        .to.emit(pool, "KycProviderSet")
        .withArgs(poolAddress, poolAddress);
      expect((await pool.getPoolParams()).kycProvider).to.be.eq(poolAddress);
    });

    it("should allow reset kyc provider", async () => {
      const { pool } = await setupTests();
      expect((await pool.getPoolParams()).kycProvider).to.be.eq(
        ethersLib.ZeroAddress,
      );
      await expect(
        pool.setKycProvider(ethersLib.ZeroAddress),
      ).to.be.revertedWithCustomError(pool, "OwnerActionInputIsSameAsCurrent");
    });
  });

  describe("changeFeeCollector", async () => {
    it("should revert if caller not pool owner", async () => {
      const { pool, user2 } = await setupTests();
      await expect(
        connect(pool, user2).changeFeeCollector(user2.address),
      ).to.be.revertedWithCustomError(pool, "PoolCallerIsNotOwner");
    });

    it("should revert if fee collector has not given permission to pool operator", async () => {
      const { pool } = await setupTests();
      await expect(
        pool.changeFeeCollector(ethersLib.ZeroAddress),
      ).to.be.revertedWithCustomError(pool, "InvalidOperator");
    });

    it("should set fee collector", async () => {
      const { pool, user1, user2 } = await setupTests();
      const poolAddress = await pool.getAddress();
      // default fee collector is pool owner
      expect((await pool.getPoolParams()).feeCollector).to.be.eq(
        await pool.owner(),
      );
      // fee collector must approve receiving fees
      await connect(pool, user2).setOperator(user1.address, true);
      await expect(pool.changeFeeCollector(user2.address))
        .to.emit(pool, "NewCollector")
        .withArgs(user1.address, poolAddress, user2.address);
      expect((await pool.getPoolParams()).feeCollector).to.be.eq(user2.address);
    });

    it("should revert if new is same as current", async () => {
      const { pool, user1, user2 } = await setupTests();
      const poolAddress = await pool.getAddress();
      const initialCollector = await pool.owner();
      // the first time we update storage, the address must be different from the default one (pool owner)
      await expect(
        pool.changeFeeCollector(initialCollector),
      ).to.be.revertedWithCustomError(pool, "OwnerActionInputIsSameAsCurrent");
      await connect(pool, user2).setOperator(user1.address, true);
      await expect(pool.changeFeeCollector(user2.address))
        .to.emit(pool, "NewCollector")
        .withArgs(user1.address, poolAddress, user2.address);
      await expect(pool.changeFeeCollector(initialCollector))
        .to.emit(pool, "NewCollector")
        .withArgs(user1.address, poolAddress, initialCollector);
    });
  });

  describe("changeSpread", async () => {
    it("should revert if caller not pool owner", async () => {
      const { pool, user2 } = await setupTests();
      await expect(
        connect(pool, user2).changeSpread(1),
      ).to.be.revertedWithCustomError(pool, "PoolCallerIsNotOwner");
    });

    it("should revert with rogue values", async () => {
      const { pool } = await setupTests();
      // spread must always be != 0, otherwise default value from immutable storage will be returned (i.e. initial spread)
      await expect(pool.changeSpread(0))
        .to.be.revertedWithCustomError(pool, "PoolSpreadInvalid")
        .withArgs(500n);
      await expect(pool.changeSpread(1001))
        .to.be.revertedWithCustomError(pool, "PoolSpreadInvalid")
        .withArgs(500n);
    });

    it("should change spread", async () => {
      const { pool } = await setupTests();
      const poolAddress = await pool.getAddress();
      expect((await pool.getPoolParams()).spread).to.be.eq(10n);
      await expect(pool.changeSpread(100))
        .to.emit(pool, "SpreadChanged")
        .withArgs(poolAddress, 100n);
      expect((await pool.getPoolParams()).spread).to.be.eq(100n);
    });

    it("should revert if same as current", async () => {
      const { pool } = await setupTests();
      const poolAddress = await pool.getAddress();
      expect((await pool.getPoolParams()).spread).to.be.eq(10n);
      // the first time we update storage, the spread must be different from the default one (10)
      await expect(pool.changeSpread(10)).to.be.revertedWithCustomError(
        pool,
        "OwnerActionInputIsSameAsCurrent",
      );
      await expect(pool.changeSpread(400))
        .to.emit(pool, "SpreadChanged")
        .withArgs(poolAddress, 400n);
      await expect(pool.changeSpread(10))
        .to.emit(pool, "SpreadChanged")
        .withArgs(poolAddress, 10n);
    });
  });

  describe("changeMinPeriod", async () => {
    it("should revert if caller not pool owner", async () => {
      const { pool, user2 } = await setupTests();
      await expect(
        connect(pool, user2).changeMinPeriod(1),
      ).to.be.revertedWithCustomError(pool, "PoolCallerIsNotOwner");
    });

    it("should revert with rogue values", async () => {
      const { pool } = await setupTests();
      // min lockup is 1 hour.
      await expect(pool.changeMinPeriod(1))
        .to.be.revertedWithCustomError(pool, "PoolLockupPeriodInvalid")
        .withArgs(86400n, 2592000n);
      // max 30 days lockup
      await expect(pool.changeMinPeriod(2592001))
        .to.be.revertedWithCustomError(pool, "PoolLockupPeriodInvalid")
        .withArgs(86400n, 2592000n);
    });

    it("should change spread", async () => {
      const { pool } = await setupTests();
      expect((await pool.getPoolParams()).minPeriod).to.be.eq(2592000n);
      const newPeriod = 86400n;
      await expect(pool.changeMinPeriod(newPeriod))
        .to.emit(pool, "MinimumPeriodChanged")
        .withArgs(await pool.getAddress(), newPeriod);
      expect((await pool.getPoolParams()).minPeriod).to.be.eq(newPeriod);
    });

    it("will revert if spread same as current", async () => {
      const { pool } = await setupTests();
      const poolAddress = await pool.getAddress();
      expect((await pool.getPoolParams()).minPeriod).to.be.eq(2592000n);
      let newPeriod = 86400n;
      await expect(pool.changeMinPeriod(newPeriod))
        .to.emit(pool, "MinimumPeriodChanged")
        .withArgs(poolAddress, newPeriod);
      expect((await pool.getPoolParams()).minPeriod).to.be.eq(newPeriod);
      newPeriod = 2592000n;
      await expect(pool.changeMinPeriod(newPeriod))
        .to.emit(pool, "MinimumPeriodChanged")
        .withArgs(poolAddress, newPeriod);
      expect((await pool.getPoolParams()).minPeriod).to.be.eq(newPeriod);
      await expect(
        pool.changeMinPeriod(newPeriod),
      ).to.be.revertedWithCustomError(pool, "OwnerActionInputIsSameAsCurrent");
      expect((await pool.getPoolParams()).minPeriod).to.be.eq(newPeriod);
    });
  });

  describe("purgeInativeTokensAndApps", async () => {
    it("should revert if caller is not pool owner", async () => {
      const { pool, user2 } = await setupTests();
      await expect(
        connect(pool, user2).purgeInactiveTokensAndApps(),
      ).to.be.revertedWithCustomError(pool, "PoolCallerIsNotOwner");
    });

    it("should not revert if nothing is found", async () => {
      const { pool } = await setupTests();
      const { ethers } = await network.getOrCreate();
      await expect(pool.purgeInactiveTokensAndApps()).to.not.revert(ethers);
    });

    it("should not remove an active token with positive balance", async () => {
      const { pool, oracle, weth, user1 } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const etherAmount = parseEther("12");
      const poolAddress = await pool.getAddress();
      const wethAddress = await weth.getAddress();
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount });
      // first mint does not prompt nav calculations
      let activeTokens = (await pool.getActiveTokens()).activeTokens;
      expect(activeTokens.length).to.be.eq(0);
      let isWethInActiveTokens = activeTokens.includes(wethAddress);
      expect(isWethInActiveTokens).to.be.false;
      const poolKey = {
        currency0: ethersLib.ZeroAddress,
        currency1: wethAddress,
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(poolKey);
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.TAKE, [
        wethAddress,
        poolAddress,
        parseEther("12"),
      ]);
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.V4_SWAP, [
        v4Planner.actions,
        v4Planner.params,
      ]);
      const { commands, inputs } = planner;
      const extPool = await ethers.getContractAt("AUniswapRouter", poolAddress);
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );
      // this call will activate the token
      await user1.sendTransaction({
        to: poolAddress,
        value: 0,
        data: encodedSwapData,
      });
      await weth.deposit({ value: etherAmount });
      await weth.transfer(poolAddress, etherAmount);
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount });
      activeTokens = (await pool.getActiveTokens()).activeTokens;
      // second mint will prompt nav calculations, so lp tokens are included in active tokens
      expect(activeTokens.length).to.be.eq(1);
      isWethInActiveTokens = activeTokens.includes(wethAddress);
      expect(isWethInActiveTokens).to.be.true;
      // will execute and not remove any token
      await expect(pool.purgeInactiveTokensAndApps()).to.not.revert(ethers);
      activeTokens = (await pool.getActiveTokens()).activeTokens;
      expect(activeTokens.length).to.be.eq(1);
    });

    it("should remove an active token with null balance", async () => {
      const { pool, oracle, weth, user1 } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const etherAmount = parseEther("12");
      const poolAddress = await pool.getAddress();
      const wethAddress = await weth.getAddress();
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount });
      // first mint does not prompt nav calculations
      let activeTokens = (await pool.getActiveTokens()).activeTokens;
      expect(activeTokens.length).to.be.eq(0);
      let isWethInActiveTokens = activeTokens.includes(wethAddress);
      expect(isWethInActiveTokens).to.be.false;
      const poolKey = {
        currency0: ethersLib.ZeroAddress,
        currency1: wethAddress,
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: await oracle.getAddress(),
      };
      await oracle.initializeObservations(poolKey);
      const v4Planner: V4Planner = new V4Planner();
      v4Planner.addAction(Actions.TAKE, [
        wethAddress,
        poolAddress,
        parseEther("12"),
      ]);
      const planner: RoutePlanner = new RoutePlanner();
      planner.addCommand(CommandType.V4_SWAP, [
        v4Planner.actions,
        v4Planner.params,
      ]);
      const { commands, inputs } = planner;
      const extPool = await ethers.getContractAt("AUniswapRouter", poolAddress);
      const encodedSwapData = extPool.interface.encodeFunctionData(
        "execute(bytes,bytes[],uint256)",
        [commands, inputs, DEADLINE],
      );
      // this call will activate the token
      await user1.sendTransaction({
        to: poolAddress,
        value: 0,
        data: encodedSwapData,
      });
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount });
      activeTokens = (await pool.getActiveTokens()).activeTokens;
      // second mint will prompt nav calculations, so lp tokens are included in active tokens
      expect(activeTokens.length).to.be.eq(1);
      isWethInActiveTokens = activeTokens.includes(wethAddress);
      expect(isWethInActiveTokens).to.be.true;
      // will execute and remove the token (balance is 0)
      await expect(pool.purgeInactiveTokensAndApps())
        .to.emit(pool, "TokenStatusChanged")
        .withArgs(wethAddress, false);
      activeTokens = (await pool.getActiveTokens()).activeTokens;
      expect(activeTokens.length).to.be.eq(0);
    });

    it("should not remove an active applications", async () => {
      const { pool, uniswapV3Npm, uniswapV4Posm, user1 } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const wethAddress = await uniswapV3Npm.WETH9();
      const poolAddress = await pool.getAddress();
      // TODO: move definitions to constants file
      // must fix typechain error to import from uni shared/v4Helpers
      const MAX_UINT128 = "0xffffffffffffffffffffffffffffffff";
      const USDC_WETH = {
        poolKey: {
          currency0: wethAddress,
          currency1: ethersLib.ZeroAddress,
          fee: 500,
          tickSpacing: 10,
          hooks: ethersLib.ZeroAddress,
        },
        price: 1282621508889261311518273674430423n,
        tickLower: 193800,
        tickUpper: 193900,
      };
      // mint in v4 Posm is a mock method
      await uniswapV4Posm.mint(
        USDC_WETH.poolKey,
        USDC_WETH.tickLower,
        USDC_WETH.tickUpper,
        1, // liquidity
        MAX_UINT128,
        MAX_UINT128,
        poolAddress,
        "0x", // hookData
      );
      const etherAmount = parseEther("12");
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount });
      // first mint does not prompt nav calculations, so lp tokens are not included in active tokens
      let activeTokens = (await pool.getActiveTokens()).activeTokens;
      expect(activeTokens.length).to.be.eq(0);
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount });
      activeTokens = (await pool.getActiveTokens()).activeTokens;
      // second mint will prompt nav calculations, so lp tokens are included in active tokens
      expect(activeTokens.length).to.be.eq(0);
      expect(await uniswapV4Posm.nextTokenId()).to.be.eq(2n);
      expect(await uniswapV4Posm.balanceOf(poolAddress)).to.be.eq(1n);
      // will execute and not remove any token
      await expect(pool.purgeInactiveTokensAndApps()).to.not.revert(ethers);
      activeTokens = (await pool.getActiveTokens()).activeTokens;
      expect(activeTokens.length).to.be.eq(0);
    });
  });
});
