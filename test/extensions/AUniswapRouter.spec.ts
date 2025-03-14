import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import { AddressZero } from "@ethersproject/constants";
import { Contract, BigNumber } from "ethers";
import { DEADLINE, MAX_UINT128, MAX_UINT160 } from "../shared/constants";
import { Actions, V4Planner } from '../shared/v4Planner'
import { CommandType, RoutePlanner } from '../shared/planner'
import { parse } from "path";
import { parseEther } from "ethers/lib/utils";
import { encodePath, FeeAmount } from "../utils/path";
import { timeTravel } from "../utils/utils";
import { time } from "console";

describe("AUniswapRouter", async () => {
  const [ user1, user2 ] = waffle.provider.getWallets()
  const MAX_TICK_SPACING = 32767
  const DEFAULT_PAIR = {
    poolKey: {
      currency0: AddressZero,
      currency1: AddressZero,
      fee: 0,
      tickSpacing: MAX_TICK_SPACING,
      hooks: AddressZero,
    },
    price: BigNumber.from('1282621508889261311518273674430423'),
    tickLower: 193800,
    tickUpper: 193900,
  }

  const setupTests = deployments.createFixture(async ({ deployments }) => {
    await deployments.fixture('tests-setup')
    const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
    const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
    const GrgTokenInstance = await deployments.get("RigoToken")
    const GrgToken = await hre.ethers.getContractFactory("RigoToken")
    const AuthorityInstance = await deployments.get("Authority")
    const Authority = await hre.ethers.getContractFactory("Authority")
    const authority = Authority.attach(AuthorityInstance.address)
    const factory = Factory.attach(RigoblockPoolProxyFactory.address)
    const { newPoolAddress, poolId } = await factory.callStatic.createPool(
        'testpool',
        'TEST',
        AddressZero
    )
    await factory.createPool('testpool','TEST',AddressZero)
    // TODO: verify what is needed before this block
    const UniRouter2Instance = await deployments.get("MockUniswapRouter");
    const uniswapRouter2 = await ethers.getContractAt("MockUniswapRouter", UniRouter2Instance.address) 
    const univ3NpmAddress = await uniswapRouter2.positionManager()
    const Univ3Npm = await hre.ethers.getContractFactory("MockUniswapNpm")
    const Univ4PosmInstance = await deployments.get("MockUniswapPosm");
    const Univ4Posm = await hre.ethers.getContractFactory("MockUniswapPosm")
    const MockUniUniversalRouter = await ethers.getContractFactory("MockUniUniversalRouter");
    const uniRouter = await MockUniUniversalRouter.deploy(univ3NpmAddress, Univ4PosmInstance.address)
    const AUniswapRouter = await ethers.getContractFactory("AUniswapRouter")
    // TODO: verify we are using the same WETH9 for Posm initialization
    const univ3Npm = Univ3Npm.attach(univ3NpmAddress)
    const wethAddress = await univ3Npm.WETH9()
    const aUniswapRouter = await AUniswapRouter.deploy(uniRouter.address, Univ4PosmInstance.address, wethAddress)
    await authority.setAdapter(aUniswapRouter.address, true)
    // "3593564c": "execute(bytes calldata, bytes[] calldata, uint256)"
    // "24856bc3": "execute(bytes calldata, bytes[] calldata)"
    // "dd46508f": "modifyLiquidities(bytes calldata, uint256)"
    await authority.addMethod("0x3593564c", aUniswapRouter.address)
    await authority.addMethod("0x24856bc3", aUniswapRouter.address)
    await authority.addMethod("0xdd46508f", aUniswapRouter.address)
    const HookInstance = await deployments.get("MockOracle")
    const Hook = await hre.ethers.getContractFactory("MockOracle")
    const Pool = await hre.ethers.getContractFactory("SmartPool")
    const Permit2Instance = await deployments.get("MockPermit2")
    const Permit2 = await hre.ethers.getContractFactory("MockPermit2")
    return {
      grgToken: GrgToken.attach(GrgTokenInstance.address),
      pool: Pool.attach(newPoolAddress),
      newPoolAddress,
      poolId,
      univ3Npm,
      univ4Posm: Univ4Posm.attach(Univ4PosmInstance.address),
      wethAddress,
      aUniswapRouter,
      uniRouterAddress: uniRouter.address,
      hookAddress: HookInstance.address,
      oracle: Hook.attach(HookInstance.address),
      permit2: Permit2.attach(Permit2Instance.address),
    }
  });

  // TODO: verify if should avoid direct calls to aUniswapRouter, or there are no side-effects (has write access to storage)
  describe("modifyLiquidities", async () => {
    it('should route to uniV4Posm', async () => {
      const { pool, univ4Posm, wethAddress, oracle } = await setupTests()
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey = { currency0: AddressZero, currency1: wethAddress, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
      await oracle.initializeObservations(PAIR.poolKey)
      PAIR.poolKey.hooks = AddressZero
      let v4Planner: V4Planner = new V4Planner()
      const nativeAmount = ethers.utils.parseEther("1")
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower,
        PAIR.tickUpper,
        1, // liquidity
        nativeAmount,
        MAX_UINT128,
        pool.address,
        '0x', // hookData
      ])
      v4Planner.addAction(Actions.SETTLE_PAIR, [PAIR.poolKey.currency0, PAIR.poolKey.currency1])
      // tokens are taken from the pool, so value is always 0
      const value = ethers.utils.parseEther("0")
      // the mock posm does not move funds from the pool, so we can send before pool has balance
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      await expect(
        extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      ).to.be.revertedWith('InsufficientNativeBalance()')
      const etherAmount = ethers.utils.parseEther("12")
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      // first mint does not prompt nav calculations, so lp tokens are not included in active tokens
      let activeTokens = (await pool.getActiveTokens()).activeTokens
      expect(activeTokens.length).to.be.eq(1)
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
      activeTokens = (await pool.getActiveTokens()).activeTokens
      // second mint will prompt nav calculations, and lp tokens are not added to active tokens again
      expect(activeTokens.length).to.be.eq(1)
      expect(await univ4Posm.nextTokenId()).to.be.eq(2)
      expect(await univ4Posm.balanceOf(pool.address)).to.be.eq(1)
      // will execute and not remove any token
      await expect(pool.purgeInactiveTokensAndApps()).to.not.be.reverted
      activeTokens = (await pool.getActiveTokens()).activeTokens
      // token is not removed, as it is returned by the posm
      expect(activeTokens.length).to.be.eq(1)
    })

    it('should mint 2 positions in the same call', async () => {
      const { pool, wethAddress, univ4Posm } = await setupTests()
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey.currency1 = wethAddress
      let v4Planner: V4Planner = new V4Planner()
      const maxAmountOut = ethers.utils.parseEther("1")
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower,
        PAIR.tickUpper,
        1, // liquidity
        maxAmountOut,
        MAX_UINT128,
        pool.address,
        '0x', // hookData
      ])
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower + 1,
        PAIR.tickUpper - 1,
        1, // liquidity
        maxAmountOut,
        MAX_UINT128,
        pool.address,
        '0x', // hookData
      ])
      // tokens are taken from the pool, so value is always 0
      const value = ethers.utils.parseEther("0")
      // the mock posm does not move funds from the pool, so we can send before pool has balance
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      // minting 2 positions using eth as one of the tokens requires transferring eth to the uniswap router
      await user1.sendTransaction({ to: pool.address, value: ethers.utils.parseEther("2") })
      await //expect(
        extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      //).to.be.not.be.reverted
      //expect(await univ4Posm.nextTokenId()).to.be.eq(2)
      //expect(await univ4Posm.balanceOf(pool.address)).to.be.eq(2)
    })

    it('should revert if position recipient is not pool', async () => {
      const { pool, wethAddress } = await setupTests()
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey.currency1 = wethAddress
      let v4Planner: V4Planner = new V4Planner()
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower,
        PAIR.tickUpper,
        1, // liquidity
        MAX_UINT128,
        MAX_UINT128,
        user1.address,
        '0x', // hookData
      ])
      // tokens are taken from the pool, so value is always 0
      const value = ethers.utils.parseEther("0")
      // the mock posm does not move funds from the pool, so we can send before pool has balance
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      await expect(
        extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      ).to.be.revertedWith('RecipientIsNotSmartPool()')
    })

    it('should revert mint if a token does not have a price feed', async () => {
      const { pool, wethAddress, grgToken, oracle } = await setupTests()
      const PAIR = DEFAULT_PAIR
      const etherAmount = ethers.utils.parseEther("12")
      PAIR.poolKey = { currency0: grgToken.address, currency1: wethAddress, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: AddressZero }
      let v4Planner: V4Planner = new V4Planner()
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower,
        PAIR.tickUpper,
        1, // liquidity
        etherAmount,
        MAX_UINT128,
        pool.address,
        '0x', // hookData
      ])
      const value = ethers.utils.parseEther("0")
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
      await expect(
        extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      ).to.be.revertedWith(`TokenPriceFeedDoesNotExist("${grgToken.address}")`)
      PAIR.poolKey.hooks = oracle.address
      PAIR.poolKey.currency0 = AddressZero
      PAIR.poolKey.currency1 = grgToken.address
      await oracle.initializeObservations(PAIR.poolKey)
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
    })

    it('should revert if hook can access liquidity deltas', async () => {
      const { pool, wethAddress, hookAddress } = await setupTests()
      const PAIR = DEFAULT_PAIR
      const etherAmount = ethers.utils.parseEther("12")
      PAIR.poolKey = { currency0: AddressZero, currency1: wethAddress, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: hookAddress }
      let v4Planner: V4Planner = new V4Planner()
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower,
        PAIR.tickUpper,
        1, // liquidity
        etherAmount,
        MAX_UINT128,
        pool.address,
        '0x', // hookData
      ])
      const value = ethers.utils.parseEther("0")
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
      await expect(
        extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      ).to.be.revertedWith(`LiquidityMintHookError("${hookAddress}")`)
      // reset hook to default state globally
      PAIR.poolKey.hooks = AddressZero
    })

    it('should not be able to increase liquidity of non-owned position', async () => {
      const { pool, univ4Posm, wethAddress, oracle } = await setupTests()
      const etherAmount = ethers.utils.parseEther("12")
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey = { currency0: AddressZero, currency1: wethAddress, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
      await oracle.initializeObservations(PAIR.poolKey)
      PAIR.poolKey.hooks = AddressZero
      const expectedTokenId = await univ4Posm.nextTokenId()
      let v4Planner: V4Planner = new V4Planner()
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower,
        PAIR.tickUpper,
        1, // liquidity
        etherAmount,
        MAX_UINT128,
        user1.address,
        '0x', // hookData
      ])
      // mint the token from user1, so the pool is not the owner
      await univ4Posm.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value: 0 })
      v4Planner = new V4Planner()
      v4Planner.addAction(Actions.INCREASE_LIQUIDITY, [expectedTokenId, '6000000', etherAmount, MAX_UINT128, '0x'])
      // tokens are taken from the pool, so value is always 0
      const value = ethers.utils.parseEther("0")
      // the mock posm does not move funds from the pool, so we can send before pool has balance
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      // adding liquidity to a non-owned position reverts without error, just a simple assertion is implemented
      await expect(
        extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      ).to.be.revertedWith('PositionOwner()')
    })

    it('should not allow mint and increase liquidity in same call', async () => {
      const { pool, univ4Posm, wethAddress, oracle } = await setupTests()
      const etherAmount = ethers.utils.parseEther("12")
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey = { currency0: AddressZero, currency1: wethAddress, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
      await oracle.initializeObservations(PAIR.poolKey)
      PAIR.poolKey.hooks = AddressZero
      const expectedTokenId = await univ4Posm.nextTokenId()
      let v4Planner: V4Planner = new V4Planner()
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower,
        PAIR.tickUpper,
        10001, // liquidity
        etherAmount.div(2),
        MAX_UINT128,
        pool.address,
        '0x', // hookData
      ])
      v4Planner.addAction(Actions.INCREASE_LIQUIDITY, [expectedTokenId, '6000000', etherAmount.div(2), MAX_UINT128, '0x'])
      // tokens are taken from the pool, so value is always 0
      const value = ethers.utils.parseEther("0")
      // the mock posm does not move funds from the pool, so we can send before pool has balance
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      // TODO: we can record event
      await expect(
        extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      ).to.be.revertedWith('PositionDoesNotExist()')
    })

    it('should increase liquidity', async () => {
      const { pool, univ4Posm, wethAddress, oracle } = await setupTests()
      const etherAmount = ethers.utils.parseEther("12")
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey = { currency0: AddressZero, currency1: wethAddress, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
      await oracle.initializeObservations(PAIR.poolKey)
      PAIR.poolKey.hooks = AddressZero
      const expectedTokenId = await univ4Posm.nextTokenId()
      let v4Planner: V4Planner = new V4Planner()
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower,
        PAIR.tickUpper,
        10001, // liquidity
        etherAmount.div(2),
        MAX_UINT128,
        pool.address,
        '0x', // hookData
      ])
      // tokens are taken from the pool, so value is always 0
      const value = ethers.utils.parseEther("0")
      // the mock posm does not move funds from the pool, so we can send before pool has balance
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      v4Planner = new V4Planner()
      v4Planner.addAction(Actions.INCREASE_LIQUIDITY, [expectedTokenId, '6000000', etherAmount.div(2), MAX_UINT128, '0x'])
      // TODO: we can record event
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      expect(await univ4Posm.nextTokenId()).to.be.eq(2)
      expect(await univ4Posm.balanceOf(pool.address)).to.be.eq(1)
      expect(await univ4Posm.ownerOf(expectedTokenId)).to.be.eq(pool.address)
      expect(await univ4Posm.getPositionLiquidity(expectedTokenId)).to.be.eq(10001 + 6000000)
    })

    it('should remove liquidity', async () => {
      const { pool, univ4Posm, wethAddress, oracle } = await setupTests()
      const etherAmount = ethers.utils.parseEther("12")
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey = { currency0: AddressZero, currency1: wethAddress, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
      await oracle.initializeObservations(PAIR.poolKey)
      PAIR.poolKey.hooks = AddressZero
      const expectedTokenId = await univ4Posm.nextTokenId()
      let v4Planner: V4Planner = new V4Planner()
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower,
        PAIR.tickUpper,
        10001, // liquidity
        etherAmount.div(2),
        MAX_UINT128,
        pool.address,
        '0x', // hookData
      ])
      const value = ethers.utils.parseEther("0")
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      v4Planner = new V4Planner()
      v4Planner.addAction(Actions.INCREASE_LIQUIDITY, [expectedTokenId, '6000000', etherAmount.div(2), MAX_UINT128, '0x'])
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      // clear state for actions
      v4Planner = new V4Planner()
      v4Planner.addAction(Actions.DECREASE_LIQUIDITY, [expectedTokenId, '1200000', MAX_UINT128, MAX_UINT128, '0x'])
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      expect(await univ4Posm.getPositionLiquidity(expectedTokenId)).to.be.eq(10001 + 6000000 - 1200000)
      // TODO: should verify that tokenIds storage is unchanged
    })

    it('should burn owned position', async () => {
      const { pool, univ4Posm, wethAddress, oracle } = await setupTests()
      const etherAmount = ethers.utils.parseEther("12")
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey = { currency0: AddressZero, currency1: wethAddress, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
      await oracle.initializeObservations(PAIR.poolKey)
      PAIR.poolKey.hooks = AddressZero
      const expectedTokenId = await univ4Posm.nextTokenId()
      let v4Planner: V4Planner = new V4Planner()
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower,
        PAIR.tickUpper,
        10001, // liquidity
        etherAmount.div(2),
        MAX_UINT128,
        pool.address,
        '0x', // hookData
      ])
      const value = ethers.utils.parseEther("0")
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      v4Planner = new V4Planner()
      v4Planner.addAction(Actions.INCREASE_LIQUIDITY, [expectedTokenId, '6000000', etherAmount.div(2), MAX_UINT128, '0x'])
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      const PositionPool = await hre.ethers.getContractFactory("EApps")
      const positionPool = PositionPool.attach(pool.address)
      expect((await positionPool.getUniV4TokenIds()).length).to.be.eq(1)
      // clear state for actions
      v4Planner = new V4Planner()
      // burn will remove any position liquidity in Posm
      v4Planner.addAction(Actions.BURN_POSITION, [expectedTokenId, MAX_UINT128, MAX_UINT128, '0x'])
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      expect(await univ4Posm.getPositionLiquidity(expectedTokenId)).to.be.eq(0)
      expect((await positionPool.getUniV4TokenIds()).length).to.be.eq(0)
    })

    it('should burn tokenId at a specific position', async () => {
      const { pool, univ4Posm, wethAddress, oracle } = await setupTests()
      const etherAmount = ethers.utils.parseEther("12")
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey = { currency0: AddressZero, currency1: wethAddress, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
      await oracle.initializeObservations(PAIR.poolKey)
      PAIR.poolKey.hooks = AddressZero
      const expectedTokenId = await univ4Posm.nextTokenId()
      let v4Planner: V4Planner = new V4Planner()
      let mintParams = [PAIR.poolKey, PAIR.tickLower, PAIR.tickUpper, 10001, etherAmount.div(3), MAX_UINT128, pool.address, '0x']
      v4Planner.addAction(Actions.MINT_POSITION, mintParams)
      mintParams = [PAIR.poolKey, PAIR.tickLower, PAIR.tickUpper - 1, 10001, etherAmount.div(3), MAX_UINT128, pool.address, '0x']
      v4Planner.addAction(Actions.MINT_POSITION, mintParams)
      mintParams = [PAIR.poolKey, PAIR.tickLower, PAIR.tickUpper - 2, 10001, etherAmount.div(3), MAX_UINT128, pool.address, '0x']
      v4Planner.addAction(Actions.MINT_POSITION, mintParams)
      const value = ethers.utils.parseEther("0")
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      const PositionPool = await hre.ethers.getContractFactory("EApps")
      const positionPool = PositionPool.attach(pool.address)
      expect((await positionPool.getUniV4TokenIds()).length).to.be.eq(3)
      // clear state for actions
      v4Planner = new V4Planner()
      // burn will remove any position liquidity in Posm
      v4Planner.addAction(Actions.BURN_POSITION, [expectedTokenId, MAX_UINT128, MAX_UINT128, '0x'])
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      expect(await univ4Posm.getPositionLiquidity(expectedTokenId)).to.be.eq(0)
      expect((await positionPool.getUniV4TokenIds()).length).to.be.eq(2)
    })

    it('position should be included in nav calculations', async () => {
      const { newPoolAddress, grgToken, pool, univ4Posm, wethAddress, oracle } = await setupTests()
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey = { currency0: AddressZero, currency1: grgToken.address, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
      await oracle.initializeObservations(PAIR.poolKey)
      PAIR.poolKey = { currency0: AddressZero, currency1: wethAddress, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
      await oracle.initializeObservations(PAIR.poolKey)
      PAIR.poolKey.currency0 = grgToken.address
      PAIR.poolKey.hooks = AddressZero
      const expectedTokenId = await univ4Posm.nextTokenId()
      let v4Planner: V4Planner = new V4Planner()
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower,
        PAIR.tickUpper,
        10001, // liquidity
        MAX_UINT128,
        MAX_UINT128,
        pool.address,
        '0x', // hookData
      ])
      const value = ethers.utils.parseEther("0")
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      v4Planner = new V4Planner()
      // TODO: verify if it is correct that small numbers of liquidity are not affecting nav calculations
      // we must add enough liquidity, otherwise the position will be too small to affect nav calculations
      v4Planner.addAction(Actions.INCREASE_LIQUIDITY, [expectedTokenId, ethers.utils.parseEther("2"), MAX_UINT128, MAX_UINT128, '0x'])
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      const PositionsPool = await hre.ethers.getContractFactory("EApps")
      const positionsPool = PositionsPool.attach(newPoolAddress)
      expect((await positionsPool.getUniV4TokenIds()).length).to.be.eq(1)
      expect(await univ4Posm.nextTokenId()).to.be.eq(2)
      const etherAmount = ethers.utils.parseEther("12")
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
      const unitaryValue = (await pool.getPoolTokens()).unitaryValue
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
      expect((await pool.getActiveTokens()).activeTokens.length).to.be.eq(2)
      // technically, this does not happen in real world, where pool tokens are used and should not inflate it. But we return mock values from the test posm.
      const poolPrice = (await pool.getPoolTokens()).unitaryValue
      expect(poolPrice).to.be.gt(unitaryValue)
      expect(poolPrice).to.be.eq(ethers.utils.parseEther("1.000000050457209347"))
    })

    it('should decode payment methods', async () => {
      const { pool, grgToken, wethAddress, oracle } = await setupTests()
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey = { currency0: AddressZero, currency1: grgToken.address, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
      await oracle.initializeObservations(PAIR.poolKey)
      PAIR.poolKey.currency1 = wethAddress
      await oracle.initializeObservations(PAIR.poolKey)
      let v4Planner: V4Planner = new V4Planner()
      v4Planner.addAction(Actions.SETTLE_PAIR, [grgToken.address, wethAddress])
      v4Planner.addAction(Actions.TAKE_PAIR, [grgToken.address, wethAddress, pool.address])
      v4Planner.addAction(Actions.SETTLE, [grgToken.address, parseEther("12"), true])
      v4Planner.addAction(Actions.SETTLE, [AddressZero, parseEther("12"), false])
      v4Planner.addAction(Actions.SETTLE, [AddressZero, parseEther("0.1"), true])
      v4Planner.addAction(Actions.TAKE, [wethAddress, pool.address, parseEther("12")])
      v4Planner.addAction(Actions.CLEAR_OR_TAKE, [grgToken.address, 0])
      v4Planner.addAction(Actions.SWEEP, [wethAddress, pool.address])
      v4Planner.addAction(Actions.WRAP, [parseEther("1")])
      v4Planner.addAction(Actions.UNWRAP, [parseEther("1")])
      // tokens are taken from the pool, so value is always 0
      const value = ethers.utils.parseEther("0")
      // the mock posm does not move funds from the pool, so we can send before pool has balance
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      // ETH transfer fails without error when pool does not have enough balance
      // TODO: safeTransferETH reverts with a reason, must verify why the reason is not returned
      await expect(
        extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      ).to.be.revertedWith('InsufficientNativeBalance()')
      const etherAmount = ethers.utils.parseEther("13.1") // settle 12 + 0.1 + 1 (wrap)
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
    })

    it('should revert when calling unsupported methods', async () => {
      const { pool, grgToken } = await setupTests()
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey.currency1 = grgToken.address
      let v4Planner: V4Planner = new V4Planner()
      v4Planner.addAction(Actions.INCREASE_LIQUIDITY_FROM_DELTAS, [0, 0, 0, '0x'])
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      await expect(
        extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value: 0 })
      ).to.be.revertedWith(`UnsupportedAction(${Actions.INCREASE_LIQUIDITY_FROM_DELTAS})`)
      v4Planner = new V4Planner()
      // TODO: we revert in adapter because we cannot settle if we do not know the amount, but should check if
      // we already forwarded enough eth or approved token, so currency can be settled or taken?
      v4Planner.addAction(Actions.MINT_POSITION_FROM_DELTAS, [
        [AddressZero, AddressZero, 0, 0, AddressZero],
        0, 0, 0, 0, AddressZero, '0x']
      )
      await expect(
        extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value:  0 })
      ).to.be.revertedWith(`UnsupportedAction(${Actions.MINT_POSITION_FROM_DELTAS})`)
      v4Planner = new V4Planner()
      // TODO: we revert because we cannot settle if we do not know the amount, but should check if
      // we already forwarded enough eth or approved token, so currency can be settled or taken?
      v4Planner.addAction(Actions.CLOSE_CURRENCY, [pool.address])
      await expect(
        extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value: 0 })
      ).to.be.revertedWith(`UnsupportedAction(${Actions.CLOSE_CURRENCY})`)
    })

    it('returns gas cost for eth pool mint with 1 uni v4 liquidity position', async () => {
      const { pool, univ4Posm, wethAddress, grgToken, oracle } = await setupTests()
      const etherAmount = ethers.utils.parseEther("12")
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey = { currency0: AddressZero, currency1: wethAddress, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
      await oracle.initializeObservations(PAIR.poolKey)
      // reset hook to default state
      PAIR.poolKey.hooks = AddressZero
      PAIR.poolKey.currency1 = wethAddress
      const expectedTokenId = await univ4Posm.nextTokenId()
      let v4Planner: V4Planner = new V4Planner()
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower,
        PAIR.tickUpper,
        10001, // liquidity
        etherAmount.div(2),
        MAX_UINT128,
        pool.address,
        '0x', // hookData
      ])
      const value = ethers.utils.parseEther("0")
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      await expect(
        extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      ).to.be.revertedWith('InsufficientNativeBalance()')
      let txReceipt = await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
      let result = await txReceipt.wait()
      let gasCost = result.cumulativeGasUsed.toNumber()
      console.log(gasCost,'first mint gas cost')
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      v4Planner = new V4Planner()
      v4Planner.addAction(Actions.INCREASE_LIQUIDITY, [expectedTokenId, ethers.utils.parseEther("2"), etherAmount.div(2), MAX_UINT128, '0x'])
      txReceipt = await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
      result = await txReceipt.wait()
      gasCost = result.cumulativeGasUsed.toNumber()
      console.log(gasCost,'second mintgas cost,  with no position')
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      txReceipt = await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
      result = await txReceipt.wait()
      gasCost = result.cumulativeGasUsed.toNumber()
      console.log(gasCost,'third mintgas cost,  with 1 position')
      txReceipt = await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
      result = await txReceipt.wait()
      gasCost = result.cumulativeGasUsed.toNumber()
      console.log(gasCost,'fourth mint gas cost, with 1 position')
      v4Planner = new V4Planner()
      // mint a different tokenIds with same tokens
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower - 500,
        PAIR.tickUpper - 500,
        10001, // liquidity
        etherAmount.div(2),
        MAX_UINT128,
        pool.address,
        '0x', // hookData
      ])
      v4Planner.addAction(Actions.INCREASE_LIQUIDITY, [expectedTokenId, ethers.utils.parseEther("2"), etherAmount.div(2), MAX_UINT128, '0x'])
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      txReceipt = await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
      result = await txReceipt.wait()
      gasCost = result.cumulativeGasUsed.toNumber()
      console.log(gasCost,'5th mint gas cost, with 2 positions')
      txReceipt = await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
      result = await txReceipt.wait()
      gasCost = result.cumulativeGasUsed.toNumber()
      console.log(gasCost,'6th mint gas cost, with 2 positions')
      await timeTravel({ days: 30 })
      txReceipt = await pool.burn(etherAmount, 1)
      result = await txReceipt.wait()
      gasCost = result.cumulativeGasUsed.toNumber()
      console.log(gasCost,'burn gas cost, with 2 positions')
      v4Planner = new V4Planner()
      // we add a new token on top of a new position
      PAIR.poolKey.currency1 = grgToken.address
      await oracle.initializeObservations(PAIR.poolKey)
      // mint a different tokenIds with same tokens
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower + 500,
        PAIR.tickUpper + 500,
        10001, // liquidity
        etherAmount.div(2),
        MAX_UINT128,
        pool.address,
        '0x', // hookData
      ])
      // need to take currency1 to activate token in storage
      v4Planner.addAction(Actions.TAKE, [PAIR.poolKey.currency1, pool.address, parseEther("12")])
      txReceipt = await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
      result = await txReceipt.wait()
      gasCost = result.cumulativeGasUsed.toNumber()
      // TODO: gas cost has not increased, but it should, as we have a new position and 1 more token
      console.log(gasCost,'7th mint gas cost, with 3 positions and an additional token')
    })
  })

  describe("execute", async () => {
    it('should execute a v4 swap', async () => {
      const { pool, wethAddress } = await setupTests()
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey.currency0 = AddressZero
      PAIR.poolKey.currency1 = wethAddress
      let v4Planner: V4Planner = new V4Planner()
      v4Planner.addAction(Actions.SWAP_EXACT_IN_SINGLE, [
        {
          poolKey: PAIR.poolKey,
          zeroForOne: true,
          amountIn: ethers.utils.parseEther("12"),
          amountOutMinimum: ethers.utils.parseEther("22"),
          hookData: '0x',
        },
      ])
      v4Planner.addAction(Actions.SETTLE, [PAIR.poolKey.currency0, parseEther("12"), true])
      let planner: RoutePlanner = new RoutePlanner()
      planner.addCommand(CommandType.V4_SWAP, [v4Planner.actions, v4Planner.params])
      const { commands, inputs } = planner
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      const encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [commands, inputs, DEADLINE]
      )
      await expect(
        user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      ).to.be.revertedWith('InsufficientNativeBalance()')
      await pool.mint(user1.address, ethers.utils.parseEther("12"), 1, { value: ethers.utils.parseEther("12") })
      await user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
    })

    it('should revert if deadline past', async () => {
      const { pool, wethAddress } = await setupTests()
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey.currency1 = wethAddress
      let v4Planner: V4Planner = new V4Planner()
      v4Planner.addAction(Actions.SWAP_EXACT_IN_SINGLE, [
        {
          poolKey: PAIR.poolKey,
          zeroForOne: true,
          amountIn: ethers.utils.parseEther("12"),
          amountOutMinimum: ethers.utils.parseEther("22"),
          hookData: '0x',
        },
      ])
      let planner: RoutePlanner = new RoutePlanner()
      planner.addCommand(CommandType.V4_SWAP, [v4Planner.actions, v4Planner.params])
      const { commands, inputs } = planner
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      await timeTravel({ seconds: DEADLINE + 1, mine: true })
      const encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [commands, inputs, DEADLINE]
      )
      await expect(
        user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      ).to.be.revertedWith('TransactionDeadlinePassed()')
    })

    it('should set approval with settle action', async () => {
      const { pool, grgToken, permit2, uniRouterAddress } = await setupTests()
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey.currency0 = grgToken.address
      let v4Planner: V4Planner = new V4Planner()
      v4Planner.addAction(Actions.SWAP_EXACT_IN_SINGLE, [
        {
          poolKey: PAIR.poolKey,
          zeroForOne: true,
          amountIn: ethers.utils.parseEther("12"),
          amountOutMinimum: ethers.utils.parseEther("22"),
          hookData: '0x',
        },
      ])
      v4Planner.addAction(Actions.SETTLE, [PAIR.poolKey.currency0, parseEther("12"), true])
      let planner: RoutePlanner = new RoutePlanner()
      planner.addCommand(CommandType.V4_SWAP, [v4Planner.actions, v4Planner.params])
      const { commands, inputs } = planner
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      const encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [commands, inputs, DEADLINE]
      )
      expect(await grgToken.allowance(pool.address, permit2.address)).to.be.eq(0)
      // TODO: this swap failed silently before, as we did not set the correct permit2 approval. Check why it was not reverted with error
      const tx = await user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      const receipt = await tx.wait()
      const block = await hre.ethers.provider.getBlock(receipt.blockNumber)
      // rigoblock sets max approval to permit2, then sets permit2 approval with expity = 0, so approval is valid only for duration of transaction
      expect(await grgToken.allowance(pool.address, permit2.address)).to.be.eq(ethers.constants.MaxUint256)
      const permit2Allowace = await permit2.allowance(pool.address, grgToken.address, uniRouterAddress)
      // Define uint160 max: 2^160 - 1
      const maxUint160 = hre.ethers.BigNumber.from("1461501637330902918203684832716283019655932542975");
      expect(permit2Allowace.amount).to.be.eq(maxUint160)
      expect(permit2Allowace.expiration).to.be.eq(block.timestamp)
      expect(permit2Allowace.nonce).to.be.eq(0)
      // NOTE: we must reset the currency0 to the default value, as the next test otherwise will revert (even though it should be reset, but for some reason it is not)
      PAIR.poolKey.currency0 = AddressZero
    })

    it('should transfer eth to universal router with settle', async () => {
      const { pool, grgToken, uniRouterAddress } = await setupTests()
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey.currency1 = grgToken.address
      let v4Planner: V4Planner = new V4Planner()
      v4Planner.addAction(Actions.SWAP_EXACT_IN_SINGLE, [
        {
          poolKey: PAIR.poolKey,
          zeroForOne: true,
          amountIn: ethers.utils.parseEther("12"),
          amountOutMinimum: ethers.utils.parseEther("22"),
          hookData: '0x',
        },
      ])
      v4Planner.addAction(Actions.SETTLE, [PAIR.poolKey.currency0, parseEther("12"), true])
      let planner: RoutePlanner = new RoutePlanner()
      planner.addCommand(CommandType.V4_SWAP, [v4Planner.actions, v4Planner.params])
      const { commands, inputs } = planner
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      const encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [commands, inputs, DEADLINE]
      )
      expect(await hre.ethers.provider.getBalance(uniRouterAddress)).to.be.eq(ethers.utils.parseEther("0"))
      await expect(
        user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      ).to.be.revertedWith('InsufficientNativeBalance()')
      await pool.mint(user1.address, ethers.utils.parseEther("12"), 1, { value: ethers.utils.parseEther("12") })
      await user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      // expect universal router to have received eth
      expect(await hre.ethers.provider.getBalance(uniRouterAddress)).to.be.eq(ethers.utils.parseEther("12"))
    })

    it('should revert if recipient is not pool', async () => {
      const { pool, grgToken } = await setupTests()
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey.currency1 = grgToken.address
      const v4Planner: V4Planner = new V4Planner()
      v4Planner.addAction(Actions.TAKE, [PAIR.poolKey.currency0, user2.address, parseEther("12")])
      const planner: RoutePlanner = new RoutePlanner()
      planner.addCommand(CommandType.V4_SWAP, [v4Planner.actions, v4Planner.params])
      const { commands, inputs } = planner
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      const encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [commands, inputs, DEADLINE]
      )
      await expect(
        user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      ).to.be.revertedWith('RecipientIsNotSmartPool()')
    })

    it('should revert settle if tokenOut does not have a price feed', async () => {
      const { pool, grgToken, oracle } = await setupTests()
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey = { currency0: AddressZero, currency1: grgToken.address, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
      const v4Planner: V4Planner = new V4Planner()
      v4Planner.addAction(Actions.TAKE, [PAIR.poolKey.currency1, pool.address, parseEther("12")])
      const planner: RoutePlanner = new RoutePlanner()
      planner.addCommand(CommandType.V4_SWAP, [v4Planner.actions, v4Planner.params])
      const { commands, inputs } = planner
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      const encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [commands, inputs, DEADLINE]
      )
      await expect(
        user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      // we cannot get the correct error address format, but the address is the grgToken address
      //).to.be.revertedWith(`TokenPriceFeedDoesNotExist(${PAIR.poolKey.currency1})`)
      ).to.be.revertedWith(`TokenPriceFeedDoesNotExist`)
      await oracle.initializeObservations(PAIR.poolKey)
      await user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
    })

    it('should take a currency', async () => {
      const { pool, grgToken } = await setupTests()
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey.currency1 = grgToken.address
      const v4Planner: V4Planner = new V4Planner()
      v4Planner.addAction(Actions.TAKE, [PAIR.poolKey.currency0, pool.address, parseEther("12")])
      const planner: RoutePlanner = new RoutePlanner()
      planner.addCommand(CommandType.V4_SWAP, [v4Planner.actions, v4Planner.params])
      const { commands, inputs } = planner
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      const encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [commands, inputs, DEADLINE]
      )
      await user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
    })

    it('should decode v4 payment methods', async () => {
      const { pool, grgToken, wethAddress, oracle } = await setupTests()
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey = { currency0: AddressZero, currency1: wethAddress, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
      await oracle.initializeObservations(PAIR.poolKey)
      PAIR.poolKey = { currency0: AddressZero, currency1: grgToken.address, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
      await oracle.initializeObservations(PAIR.poolKey)
      const v4Planner: V4Planner = new V4Planner()
      // same as base token, won't be added to active tokens
      v4Planner.addAction(Actions.TAKE, [PAIR.poolKey.currency0, pool.address, parseEther("12")])
      // this will add a new token to the returned tokensOut array
      v4Planner.addAction(Actions.TAKE, [PAIR.poolKey.currency1, pool.address, parseEther("12")])
      // new token, will be added to active tokens
      v4Planner.addAction(Actions.TAKE, [wethAddress, pool.address, parseEther("1")])
      // TODO: add positive value and make sure pool has eth
      v4Planner.addAction(Actions.SETTLE_ALL, [PAIR.poolKey.currency0, 0])
      v4Planner.addAction(Actions.TAKE_ALL, [PAIR.poolKey.currency0, parseEther("12")])
      v4Planner.addAction(Actions.TAKE_PORTION, [PAIR.poolKey.currency0, pool.address, 0])
      const planner: RoutePlanner = new RoutePlanner()
      planner.addCommand(CommandType.V4_SWAP, [v4Planner.actions, v4Planner.params])
      const { commands, inputs } = planner
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      const encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [commands, inputs, DEADLINE]
      )
      await user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      const activeTokens = await pool.getActiveTokens()
      expect(activeTokens.length).to.be.eq(2)
      expect(activeTokens.activeTokens[0]).to.be.eq(grgToken.address)
      expect(activeTokens.activeTokens[1]).to.be.eq(wethAddress)
    })

    it('should wrap/unwrap native', async () => {
      const { pool, grgToken, wethAddress, oracle } = await setupTests()
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey = { currency0: AddressZero, currency1: wethAddress, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
      await oracle.initializeObservations(PAIR.poolKey)
      const planner: RoutePlanner = new RoutePlanner()
      // will revert if pool does not have enough eth
      await pool.mint(user1.address, ethers.utils.parseEther("0.1"), 1, { value: ethers.utils.parseEther("0.1") })
      planner.addCommand(CommandType.WRAP_ETH, [pool.address, 1000])
      planner.addCommand(CommandType.UNWRAP_WETH, [pool.address, 0])
      planner.addCommand(CommandType.BALANCE_CHECK_ERC20, [pool.address, grgToken.address, 1])
      const { commands, inputs } = planner
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      const encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [commands, inputs, DEADLINE]
      )
      await user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
    })

    it('a direct call should revert', async () => {
      const { pool, grgToken, aUniswapRouter } = await setupTests()
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey.currency1 = grgToken.address
      const v4Planner: V4Planner = new V4Planner()
      v4Planner.addAction(Actions.TAKE, [PAIR.poolKey.currency0, pool.address, parseEther("12")])
      const planner: RoutePlanner = new RoutePlanner()
      planner.addCommand(CommandType.V4_SWAP, [v4Planner.actions, v4Planner.params])
      const { commands, inputs } = planner
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      const encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [commands, inputs, DEADLINE]
      )
      await expect(
        user1.sendTransaction({ to: aUniswapRouter.address, value: 0, data: encodedSwapData})
      ).to.be.revertedWith('DirectCallNotAllowed()')
    })

    it('should execute a subplan', async () => {
      const { pool, grgToken } = await setupTests()
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey.currency1 = grgToken.address
      const v4Planner: V4Planner = new V4Planner()
      v4Planner.addAction(Actions.TAKE, [PAIR.poolKey.currency0, pool.address, parseEther("12")])
      const planner: RoutePlanner = new RoutePlanner()
      planner.addCommand(CommandType.V4_SWAP, [v4Planner.actions, v4Planner.params])
      const subPlanner: RoutePlanner = new RoutePlanner()
      subPlanner.addCommand(CommandType.EXECUTE_SUB_PLAN, [planner.commands, planner.inputs])
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      const encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [subPlanner.commands, subPlanner.inputs, DEADLINE]
      )
      await user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
    })

    // TODO: can move this to new file EApps.spec.ts
    it('should remove 1 token from active tokens', async () => {
      const { newPoolAddress, pool, grgToken, wethAddress, oracle } = await setupTests()
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey = { currency0: AddressZero, currency1: wethAddress, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
      await oracle.initializeObservations(PAIR.poolKey)
      PAIR.poolKey = { currency0: AddressZero, currency1: grgToken.address, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
      await oracle.initializeObservations(PAIR.poolKey)
      PAIR.poolKey.currency0 = wethAddress
      PAIR.poolKey.currency1 = grgToken.address
      const v4Planner: V4Planner = new V4Planner()
      v4Planner.addAction(Actions.TAKE, [PAIR.poolKey.currency0, pool.address, parseEther("12")])
      v4Planner.addAction(Actions.TAKE, [PAIR.poolKey.currency1, pool.address, parseEther("12")])
      const planner: RoutePlanner = new RoutePlanner()
      planner.addCommand(CommandType.V4_SWAP, [v4Planner.actions, v4Planner.params])
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      const encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [planner.commands, planner.inputs, DEADLINE]
      )
      await user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      expect((await pool.getActiveTokens()).activeTokens.length).to.be.eq(2)
      // transfer grg to pool, so it cannot be purged, while weth will be, as its balance is 0
      await grgToken.transfer(newPoolAddress, parseEther("12"))
      await pool.purgeInactiveTokensAndApps()
      expect((await pool.getActiveTokens()).activeTokens.length).to.be.eq(1)
    })

    it("should process v3 exactIn swap", async function () {
      const { pool, grgToken, wethAddress, oracle } = await setupTests()
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey = { currency0: AddressZero, currency1: grgToken.address, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
      await oracle.initializeObservations(PAIR.poolKey)
      const path = encodePath([wethAddress, grgToken.address], [FeeAmount.MEDIUM])
      const planner: RoutePlanner = new RoutePlanner()
      // recipient, amountIn, amountOutMin, path, payerIsUser
      planner.addCommand(CommandType.V3_SWAP_EXACT_IN, [pool.address, 100, 1, path, true])
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      const encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [planner.commands, planner.inputs, DEADLINE]
      )
      await user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
    });

    it("should process v3 exactOut", async function () {
      const { pool, grgToken, wethAddress, oracle } = await setupTests()
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey = { currency0: AddressZero, currency1: wethAddress, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
      await oracle.initializeObservations(PAIR.poolKey)
      const path = encodePath([wethAddress, grgToken.address], [FeeAmount.MEDIUM])
      const planner: RoutePlanner = new RoutePlanner()
      // recipient, amountOut, amountInMax, path, payerIsUser
      planner.addCommand(CommandType.V3_SWAP_EXACT_OUT, [pool.address, 100, 1, path, true])
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      const encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [planner.commands, planner.inputs, DEADLINE]
      )
      await user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
    });

    it("should process v2 swap", async function () {
      const { pool, grgToken, wethAddress, oracle } = await setupTests()
      const PAIR = DEFAULT_PAIR
      // we must add a price feed for both tokens, as we use both exactIn and exactOut methods
      PAIR.poolKey = { currency0: AddressZero, currency1: grgToken.address, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
      await oracle.initializeObservations(PAIR.poolKey)
      PAIR.poolKey = { currency0: AddressZero, currency1: wethAddress, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
      await oracle.initializeObservations(PAIR.poolKey)
      let path = [wethAddress, grgToken.address]
      const planner: RoutePlanner = new RoutePlanner()
      // recipient, amountOut, amountInMax, path, payerIsUser
      planner.addCommand(CommandType.V2_SWAP_EXACT_IN, [pool.address, 100, 1, path, true])
      planner.addCommand(CommandType.V2_SWAP_EXACT_OUT, [pool.address, 100, 1, path, true])
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      let encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [planner.commands, planner.inputs, DEADLINE]
      )
      await user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      path = [AddressZero, grgToken.address]
      planner.addCommand(CommandType.V2_SWAP_EXACT_IN, [pool.address, 100, 1, path, true])
      planner.addCommand(CommandType.V2_SWAP_EXACT_OUT, [pool.address, 100, 1, path, true])
      encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [planner.commands, planner.inputs, DEADLINE]
      )
      await expect(
        user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      ).to.be.revertedWith('InsufficientNativeBalance()')
      await pool.mint(user1.address, ethers.utils.parseEther("0.1"), 1, { value: ethers.utils.parseEther("0.1") })
      await user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      planner.addCommand(CommandType.V2_SWAP_EXACT_IN, [user1.address, 100, 1, path, true])
      encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [planner.commands, planner.inputs, DEADLINE]
      )
      await expect(
        user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      ).to.be.revertedWith('RecipientIsNotSmartPool()')
    });

    it("should process sweep, transfer and pay v3 payment methods", async function () {
      const { pool, grgToken, wethAddress, oracle } = await setupTests()
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey = { currency0: AddressZero, currency1: grgToken.address, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
      await oracle.initializeObservations(PAIR.poolKey)
      const path = encodePath([wethAddress, grgToken.address], [FeeAmount.MEDIUM])
      const planner: RoutePlanner = new RoutePlanner()
      planner.addCommand(CommandType.SWEEP, [grgToken.address, pool.address, 1])
      planner.addCommand(CommandType.TRANSFER, [grgToken.address, pool.address, 1])
      planner.addCommand(CommandType.PAY_PORTION, [grgToken.address, pool.address, 1])
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      const encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [planner.commands, planner.inputs, DEADLINE]
      )
      await user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
    });

    it('should revert when calling unsupported methods', async () => {
      const { pool, grgToken } = await setupTests()
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey.currency1 = grgToken.address
      let planner: RoutePlanner = new RoutePlanner()
      planner.addCommand(CommandType.PERMIT2_TRANSFER_FROM, [PAIR.poolKey.currency0, pool.address, parseEther("12")])
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      let encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [planner.commands, planner.inputs, DEADLINE]
      )
      await expect(
        user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      ).to.be.revertedWith(`InvalidCommandType(${CommandType.PERMIT2_TRANSFER_FROM})`)
      planner = new RoutePlanner()
      planner.addCommand(CommandType.PERMIT2_PERMIT_BATCH, [{
        details: [{token: grgToken.address, amount: 0, expiration: 0, nonce: 0}],
        spender: grgToken.address,
        sigDeadline: 0,
      }, '0x'])
      encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [planner.commands, planner.inputs, DEADLINE]
      )
      await expect(
        user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      ).to.be.revertedWith(`InvalidCommandType(${CommandType.PERMIT2_PERMIT_BATCH})`)
      planner = new RoutePlanner()
      planner.addCommand(CommandType.PERMIT2_PERMIT, [{
        details: {token: grgToken.address, amount: 0, expiration: 0, nonce: 0},
        spender: grgToken.address,
        sigDeadline: 0,
      }, '0x'])
      encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [planner.commands, planner.inputs, DEADLINE]
      )
      await expect(
        user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      ).to.be.revertedWith(`InvalidCommandType(${CommandType.PERMIT2_PERMIT})`)
      planner = new RoutePlanner()
      planner.addCommand(CommandType.PERMIT2_TRANSFER_FROM_BATCH, [[{from: pool.address, to: pool.address, amount: 1, token: pool.address}]])
      encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [planner.commands, planner.inputs, DEADLINE]
      )
      await expect(
        user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      ).to.be.revertedWith(`InvalidCommandType(${CommandType.PERMIT2_TRANSFER_FROM_BATCH})`)
      planner = new RoutePlanner()
      planner.addCommand(CommandType.V3_POSITION_MANAGER_PERMIT, [encodedSwapData])
      encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [planner.commands, planner.inputs, DEADLINE]
      )
      await expect(
        user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      ).to.be.revertedWith(`InvalidCommandType(${CommandType.V3_POSITION_MANAGER_PERMIT})`)
      planner = new RoutePlanner()
      planner.addCommand(CommandType.V3_POSITION_MANAGER_CALL, [encodedSwapData])
      encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [planner.commands, planner.inputs, DEADLINE]
      )
      await expect(
        user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      ).to.be.revertedWith(`InvalidCommandType(${CommandType.V3_POSITION_MANAGER_CALL})`)
      planner = new RoutePlanner()
      planner.addCommand(CommandType.V4_POSITION_MANAGER_CALL, [encodedSwapData])
      encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [planner.commands, planner.inputs, DEADLINE]
      )
      await expect(
        user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      ).to.be.revertedWith(`InvalidCommandType(${CommandType.V4_POSITION_MANAGER_CALL})`)

      let rogueCommand = CommandType.EXECUTE_SUB_PLAN + 1
      encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [rogueCommand, [ethers.utils.hexlify(0x0)], DEADLINE]
      )
      await expect(
        user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      ).to.be.revertedWith('InvalidCommandType(34)')
      rogueCommand = CommandType.V2_SWAP_EXACT_IN - 1
      encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [rogueCommand, [ethers.utils.hexlify(0x0)], DEADLINE]
      )
      await expect(
        user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      ).to.be.revertedWith('InvalidCommandType(7)')
      rogueCommand = CommandType.V4_SWAP - 1
      encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [rogueCommand, [ethers.utils.hexlify(0x0)], DEADLINE]
      )
      await expect(
        user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      ).to.be.revertedWith('InvalidCommandType(15)')
      rogueCommand = CommandType.EXECUTE_SUB_PLAN - 1
      encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [rogueCommand, [ethers.utils.hexlify(0x0)], DEADLINE]
      )
      await expect(
        user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      ).to.be.revertedWith('InvalidCommandType(32)')
      PAIR.poolKey.currency1 = grgToken.address
    })

    it('logs gas costs for mint when pool has null balance of active tokens', async () => {
      const { pool, wethAddress, grgToken, oracle } = await setupTests()
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey = { currency0: AddressZero, currency1: wethAddress, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
      await oracle.initializeObservations(PAIR.poolKey)
      let v4Planner: V4Planner = new V4Planner()
      v4Planner.addAction(Actions.TAKE, [PAIR.poolKey.currency1, pool.address, parseEther("12")])
      let planner: RoutePlanner = new RoutePlanner()
      planner.addCommand(CommandType.V4_SWAP, [v4Planner.actions, v4Planner.params])
      const { commands, inputs } = planner
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      let encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [commands, inputs, DEADLINE]
      )
      await user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      // add first 2 mint
      let txReceipt = await pool.mint(user1.address, ethers.utils.parseEther("12"), 1, { value: ethers.utils.parseEther("12") })
      let result = await txReceipt.wait()
      let gasCost = result.cumulativeGasUsed.toNumber()
      console.log(gasCost,'1st mint gas cost, with 1 active token (stores initial value)')
      txReceipt = await pool.mint(user1.address, ethers.utils.parseEther("12"), 1, { value: ethers.utils.parseEther("12") })
      result = await txReceipt.wait()
      gasCost = result.cumulativeGasUsed.toNumber()
      console.log(gasCost,'2nd mint gas cost, with 1 active token (calculates nav)')
      PAIR.poolKey.currency1 = grgToken.address
      await oracle.initializeObservations(PAIR.poolKey)
      v4Planner = new V4Planner()
      v4Planner.addAction(Actions.TAKE, [PAIR.poolKey.currency1, pool.address, parseEther("12")])
      planner = new RoutePlanner()
      planner.addCommand(CommandType.V4_SWAP, [v4Planner.actions, v4Planner.params])
      const { commands: newCommands, inputs: newInputs } = planner
      encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [newCommands, newInputs, DEADLINE]
      )
      await user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      txReceipt = await pool.mint(user1.address, ethers.utils.parseEther("12"), 1, { value: ethers.utils.parseEther("12") })
      result = await txReceipt.wait()
      gasCost = result.cumulativeGasUsed.toNumber()
      console.log(gasCost,'3rd mint gas cost, with 2 active token (calculates nav)')
      expect((await pool.getActiveTokens()).activeTokens.length).to.be.eq(2)
    })

    // we could also have both tokens' positive balances by initiatin WETH instance and transferring, however WETH is early-converted to ETH
    it('logs gas costs for mint when pool holds positive GRG balance', async () => {
      const { pool, wethAddress, grgToken, oracle } = await setupTests()
      await grgToken.transfer(pool.address, ethers.utils.parseEther("12"))
      const PAIR = DEFAULT_PAIR
      PAIR.poolKey = { currency0: AddressZero, currency1: wethAddress, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
      await oracle.initializeObservations(PAIR.poolKey)
      let v4Planner: V4Planner = new V4Planner()
      v4Planner.addAction(Actions.TAKE, [PAIR.poolKey.currency1, pool.address, parseEther("12")])
      let planner: RoutePlanner = new RoutePlanner()
      planner.addCommand(CommandType.V4_SWAP, [v4Planner.actions, v4Planner.params])
      const { commands, inputs } = planner
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      let encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [commands, inputs, DEADLINE]
      )
      await user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      // add first 2 mint
      let txReceipt = await pool.mint(user1.address, ethers.utils.parseEther("12"), 1, { value: ethers.utils.parseEther("12") })
      let result = await txReceipt.wait()
      let gasCost = result.cumulativeGasUsed.toNumber()
      console.log(gasCost,'1st mint gas cost, with 1 active token (stores initial value)')
      txReceipt = await pool.mint(user1.address, ethers.utils.parseEther("12"), 1, { value: ethers.utils.parseEther("12") })
      result = await txReceipt.wait()
      gasCost = result.cumulativeGasUsed.toNumber()
      console.log(gasCost,'2nd mint gas cost, with 1 active token (calculates nav)')
      PAIR.poolKey.currency1 = grgToken.address
      v4Planner = new V4Planner()
      v4Planner.addAction(Actions.TAKE, [PAIR.poolKey.currency1, pool.address, parseEther("12")])
      planner = new RoutePlanner()
      planner.addCommand(CommandType.V4_SWAP, [v4Planner.actions, v4Planner.params])
      const { commands: newCommands, inputs: newInputs } = planner
      encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [newCommands, newInputs, DEADLINE]
      )
      await oracle.initializeObservations(PAIR.poolKey)
      await user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      txReceipt = await pool.mint(user1.address, ethers.utils.parseEther("12"), 1, { value: ethers.utils.parseEther("12") })
      result = await txReceipt.wait()
      gasCost = result.cumulativeGasUsed.toNumber()
      console.log(gasCost,'3rd mint gas cost, with 2 active token (calculates nav)')
      expect((await pool.getActiveTokens()).activeTokens.length).to.be.eq(2)
      txReceipt = await pool.mint(user1.address, ethers.utils.parseEther("12"), 1, { value: ethers.utils.parseEther("12") })
      result = await txReceipt.wait()
      gasCost = result.cumulativeGasUsed.toNumber()
      console.log(gasCost,'4th mint gas cost, with 2 active token (calculates nav but does not update storage)')
      expect((await pool.getActiveTokens()).activeTokens.length).to.be.eq(2)
    })
  })
});