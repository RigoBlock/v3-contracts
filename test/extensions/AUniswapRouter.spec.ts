import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import { AddressZero } from "@ethersproject/constants";
import { Contract, BigNumber } from "ethers";
import { DEADLINE, MAX_UINT128, MAX_UINT160 } from "../shared/constants";
import { Actions, V4Planner } from '../shared/v4Planner'
import { CommandType, RoutePlanner } from '../shared/planner'
import { parse } from "path";
import { parseEther } from "ethers/lib/utils";
import { timeTravel } from "../utils/utils";

describe("AUniswapRouter", async () => {
  const [ user1, user2 ] = waffle.provider.getWallets()
  let PAIR = {
    poolKey: {
      currency0: AddressZero,
      currency1: AddressZero,
      fee: 500,
      tickSpacing: 10,
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
    const Univ3NpmInstance = await deployments.get("MockUniswapNpm");
    const Univ3Npm = await hre.ethers.getContractFactory("MockUniswapNpm")
    const Univ4PosmInstance = await deployments.get("MockUniswapPosm");
    const Univ4Posm = await hre.ethers.getContractFactory("MockUniswapPosm")
    const MockUniUniversalRouter = await ethers.getContractFactory("MockUniUniversalRouter");
    const uniRouter = await MockUniUniversalRouter.deploy(Univ3NpmInstance.address, Univ4PosmInstance.address)
    const AUniswapRouter = await ethers.getContractFactory("AUniswapRouter")
    // TODO: verify we are using the same WETH9 for Posm initialization
    const univ3Npm = Univ3Npm.attach(Univ3NpmInstance.address)
    const wethAddress = await univ3Npm.WETH9()
    const aUniswapRouter = await AUniswapRouter.deploy(uniRouter.address, Univ4PosmInstance.address, wethAddress)
    await authority.setAdapter(aUniswapRouter.address, true)
    // "3593564c": "execute(bytes calldata, bytes[] calldata, uint256)"
    // "24856bc3": "execute(bytes calldata, bytes[] calldata)"
    // "dd46508f": "modifyLiquidities(bytes calldata, uint256)"
    await authority.addMethod("0x3593564c", aUniswapRouter.address)
    await authority.addMethod("0x24856bc3", aUniswapRouter.address)
    await authority.addMethod("0xdd46508f", aUniswapRouter.address)
    const Pool = await hre.ethers.getContractFactory("SmartPool")
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
    }
  });

  // TODO: verify if should avoid direct calls to aUniswapRouter, or there are no side-effects (has write access to storage)
  describe("modifyLiquidities", async () => {
    it('should route to uniV4Posm', async () => {
      const { pool, univ3Npm, univ4Posm, wethAddress } = await setupTests()
      PAIR.poolKey.currency1 = wethAddress
      let v4Planner: V4Planner = new V4Planner()
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower,
        PAIR.tickUpper,
        1, // liquidity
        MAX_UINT128,
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
      const etherAmount = ethers.utils.parseEther("12")
      // TODO: we mint to prompt nav updates, but should also assert that eth value is transferred to posm
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
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

    it('should revert if position recipient is not pool', async () => {
      const { pool, univ3Npm, univ4Posm, wethAddress } = await setupTests()
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

    it('should not be able to increase liquidity of non-owned position', async () => {
      const { pool, univ3Npm, univ4Posm, wethAddress } = await setupTests()
      PAIR.poolKey.currency1 = wethAddress
      const expectedTokenId = await univ4Posm.nextTokenId()
      let v4Planner: V4Planner = new V4Planner()
      v4Planner.addAction(Actions.INCREASE_LIQUIDITY, [expectedTokenId, '6000000', MAX_UINT128, MAX_UINT128, '0x'])
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

    it('should increase liquidity', async () => {
      const { pool, univ3Npm, univ4Posm, wethAddress } = await setupTests()
      PAIR.poolKey.currency1 = wethAddress
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
      v4Planner.addAction(Actions.INCREASE_LIQUIDITY, [expectedTokenId, '6000000', MAX_UINT128, MAX_UINT128, '0x'])
      // tokens are taken from the pool, so value is always 0
      const value = ethers.utils.parseEther("0")
      // the mock posm does not move funds from the pool, so we can send before pool has balance
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      // TODO: we can record event
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      expect(await univ4Posm.nextTokenId()).to.be.eq(2)
      expect(await univ4Posm.balanceOf(pool.address)).to.be.eq(1)
      expect(await univ4Posm.ownerOf(expectedTokenId)).to.be.eq(pool.address)
      expect(await univ4Posm.getPositionLiquidity(expectedTokenId)).to.be.eq(10001 + 6000000)
    })

    it('should remove liquidity', async () => {
      const { pool, univ4Posm, wethAddress } = await setupTests()
      PAIR.poolKey.currency1 = wethAddress
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
      v4Planner.addAction(Actions.INCREASE_LIQUIDITY, [expectedTokenId, '6000000', MAX_UINT128, MAX_UINT128, '0x'])
      // tokens are taken from the pool, so value is always 0
      const value = ethers.utils.parseEther("0")
      // the mock posm does not move funds from the pool, so we can send before pool has balance
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      // TODO: we can record event
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      // clear state for actions
      v4Planner = new V4Planner()
      v4Planner.addAction(Actions.DECREASE_LIQUIDITY, [expectedTokenId, '1200000', MAX_UINT128, MAX_UINT128, '0x'])
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      expect(await univ4Posm.getPositionLiquidity(expectedTokenId)).to.be.eq(10001 + 6000000 - 1200000)
      // TODO: should verify that tokenIds storage is unchanged
    })

    it('should burn owned position', async () => {
      const { pool, univ4Posm, wethAddress } = await setupTests()
      PAIR.poolKey.currency1 = wethAddress
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
      v4Planner.addAction(Actions.INCREASE_LIQUIDITY, [expectedTokenId, '6000000', MAX_UINT128, MAX_UINT128, '0x'])
      // tokens are taken from the pool, so value is always 0
      const value = ethers.utils.parseEther("0")
      // the mock posm does not move funds from the pool, so we can send before pool has balance
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      // clear state for actions
      v4Planner = new V4Planner()
      // burn will remove any position liquidity in Posm
      v4Planner.addAction(Actions.BURN_POSITION, [expectedTokenId, MAX_UINT128, MAX_UINT128, '0x'])
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      //expect(await univ4Posm.getPositionLiquidity(expectedTokenId)).to.be.eq(0)
      // TODO: should verify that tokenIds storage is modified
    })

    it('position should be included in nav calculations', async () => {
      const { pool, univ4Posm, wethAddress } = await setupTests()
      PAIR.poolKey.currency1 = wethAddress
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
      // TODO: verify if it is correct that small numbers of liquidity are not affecting nav calculations
      // we must add enough liquidity, otherwise the position will be too small to affect nav calculations
      v4Planner.addAction(Actions.INCREASE_LIQUIDITY, [expectedTokenId, ethers.utils.parseEther("2"), MAX_UINT128, MAX_UINT128, '0x'])
      // tokens are taken from the pool, so value is always 0
      const value = ethers.utils.parseEther("0")
      // the mock posm does not move funds from the pool, so we can send before pool has balance
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      const etherAmount = ethers.utils.parseEther("12")
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
      const unitaryValue = (await pool.getPoolTokens()).unitaryValue
      await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
      expect((await pool.getActiveTokens()).activeTokens.length).to.be.eq(1)
      // technically, this does not happen in real world, where pool tokens are used and should not inflate it. But we return mock values from the test posm.
      const poolPrice = (await pool.getPoolTokens()).unitaryValue
      expect(poolPrice).to.be.gt(unitaryValue)
      expect(poolPrice).to.be.eq(ethers.utils.parseEther("1.000000051476461117"))
    })

    it('returns gas cost for eth pool mint with 1 uni v4 liquidity position', async () => {
      const { pool, univ4Posm, wethAddress, grgToken } = await setupTests()
      PAIR.poolKey.currency1 = wethAddress
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
      v4Planner.addAction(Actions.INCREASE_LIQUIDITY, [expectedTokenId, ethers.utils.parseEther("2"), MAX_UINT128, MAX_UINT128, '0x'])
      const value = ethers.utils.parseEther("0")
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      const etherAmount = ethers.utils.parseEther("12")
      let txReceipt = await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
      let result = await txReceipt.wait()
      let gasCost = result.cumulativeGasUsed.toNumber()
      console.log(gasCost,'first mint gas cost')
      txReceipt = await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
      result = await txReceipt.wait()
      gasCost = result.cumulativeGasUsed.toNumber()
      console.log(gasCost,'second mintgas cost,  with 1 position')
      txReceipt = await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
      result = await txReceipt.wait()
      gasCost = result.cumulativeGasUsed.toNumber()
      console.log(gasCost,'third mint gas cost, with 1 position')
      v4Planner = new V4Planner()
      // mint a different tokenIds with same tokens
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower - 500,
        PAIR.tickUpper - 500,
        10001, // liquidity
        MAX_UINT128,
        MAX_UINT128,
        pool.address,
        '0x', // hookData
      ])
      v4Planner.addAction(Actions.INCREASE_LIQUIDITY, [expectedTokenId, ethers.utils.parseEther("2"), MAX_UINT128, MAX_UINT128, '0x'])
      await extPool.modifyLiquidities(v4Planner.finalize(), MAX_UINT160, { value })
      txReceipt = await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
      result = await txReceipt.wait()
      gasCost = result.cumulativeGasUsed.toNumber()
      console.log(gasCost,'4th mint gas cost, with 2 positions')
      txReceipt = await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
      result = await txReceipt.wait()
      gasCost = result.cumulativeGasUsed.toNumber()
      console.log(gasCost,'5th mint gas cost, with 2 positions')
      await timeTravel({ days: 30 })
      txReceipt = await pool.burn(etherAmount, 1)
      result = await txReceipt.wait()
      gasCost = result.cumulativeGasUsed.toNumber()
      console.log(gasCost,'burn gas cost, with 2 positions')
      v4Planner = new V4Planner()
      // we add a new token on top of a new position
      PAIR.poolKey.currency1 = grgToken.address
      // mint a different tokenIds with same tokens
      v4Planner.addAction(Actions.MINT_POSITION, [
        PAIR.poolKey,
        PAIR.tickLower + 500,
        PAIR.tickUpper + 500,
        10001, // liquidity
        MAX_UINT128,
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
      console.log(gasCost,'6th mint gas cost, with 3 positions and an additional token')
    })
  })

  describe("execute", async () => {
    // this won't do much until we encode a settle, as we only return params with payments actions.
    // TODO: flow could change as it could be harder to find eth amount later
    it('should execute a v4 swap', async () => {
      const { pool, wethAddress } = await setupTests()
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
      const encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [commands, inputs, DEADLINE]
      )
      await user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
    })

    it('should set approval with settle action', async () => {
      const { pool, grgToken, uniRouterAddress } = await setupTests()
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
      v4Planner.addAction(Actions.SETTLE, [PAIR.poolKey.currency1, parseEther("12"), true])
      let planner: RoutePlanner = new RoutePlanner()
      planner.addCommand(CommandType.V4_SWAP, [v4Planner.actions, v4Planner.params])
      const { commands, inputs } = planner
      const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
      const extPool = ExtPool.attach(pool.address)
      const encodedSwapData = extPool.interface.encodeFunctionData(
        'execute(bytes,bytes[],uint256)',
        [commands, inputs, DEADLINE]
      )
      expect(await grgToken.allowance(pool.address, uniRouterAddress)).to.be.eq(0)
      await user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      // rigoblock sets max approval, and then resets it to 1 to prevent clearing storage
      expect(await grgToken.allowance(pool.address, uniRouterAddress)).to.be.eq(1)
    })

    it('should transfer eth to universal router with settle', async () => {
      const { pool, grgToken, uniRouterAddress } = await setupTests()
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
      // eth transfer reverts without a reason, so we can't check for a revert message
      //await expect(
      //  user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      //).to.be.revertedWith('NativeTransferFailed()')
      await pool.mint(user1.address, ethers.utils.parseEther("12"), 1, { value: ethers.utils.parseEther("12") })
      await user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      // expect universal router to have received eth
      expect(await hre.ethers.provider.getBalance(uniRouterAddress)).to.be.eq(ethers.utils.parseEther("12"))
    })

    it('should revert if recipient is not pool', async () => {
      const { pool, grgToken } = await setupTests()
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

    it('should take a currency', async () => {
      const { pool, grgToken } = await setupTests()
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

    it('a direct call should revert', async () => {
      const { pool, grgToken, aUniswapRouter } = await setupTests()
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

    it('logs gas costs for mint when pool has null balance of active tokens', async () => {
      const { pool, wethAddress, grgToken } = await setupTests()
      PAIR.poolKey.currency1 = wethAddress
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
      await user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
      txReceipt = await pool.mint(user1.address, ethers.utils.parseEther("12"), 1, { value: ethers.utils.parseEther("12") })
      result = await txReceipt.wait()
      gasCost = result.cumulativeGasUsed.toNumber()
      console.log(gasCost,'3rd mint gas cost, with 2 active token (calculates nav)')
      expect((await pool.getActiveTokens()).activeTokens.length).to.be.eq(2)
    })

    // we could also have both tokens' positive balances by initiatin WETH instance and transferring, however WETH is early-converted to ETH
    it('logs gas costs for mint when pool holds positive GRG balance', async () => {
      const { pool, wethAddress, grgToken } = await setupTests()
      await grgToken.transfer(pool.address, ethers.utils.parseEther("12"))
      PAIR.poolKey.currency1 = wethAddress
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