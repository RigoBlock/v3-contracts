import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import { AddressZero } from "@ethersproject/constants";
import { Contract, BigNumber } from "ethers";
import { MAX_UINT128, MAX_UINT160 } from "../shared/constants";
import { Actions, V4Planner } from '../shared/v4Planner'

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
    const uniRouter = await MockUniUniversalRouter.deploy(Univ3NpmInstance.address, Univ4PosmInstance.address);
    const AUniswapRouter = await ethers.getContractFactory("AUniswapRouter");
    // TODO: not sure we need univ4Posm as input, as can be retrieved from universalrouter?
    const aUniswapRouter = await AUniswapRouter.deploy(uniRouter.address, Univ4PosmInstance.address);
    await authority.setAdapter(aUniswapRouter.address, true)
    // "3593564c": "execute(bytes calldata, bytes[] calldata, uint256)"
    // "24856bc3": "execute(bytes calldata, bytes[] calldata)"
    // "dd46508f": "modifyLiquidities(bytes calldata, uint256)"
    await authority.addMethod("0x3593564c", aUniswapRouter.address)
    await authority.addMethod("0x24856bc3", aUniswapRouter.address)
    await authority.addMethod("0xdd46508f", aUniswapRouter.address)
    const Pool = await hre.ethers.getContractFactory("RigoblockV3Pool")
    return {
      grgToken: GrgToken.attach(GrgTokenInstance.address),
      pool: Pool.attach(newPoolAddress),
      newPoolAddress,
      poolId,
      univ3Npm: Univ3Npm.attach(Univ3NpmInstance.address),
      univ4Posm: Univ4Posm.attach(Univ4PosmInstance.address),
      aUniswapRouter
    }
  });

  // TODO: verify if should avoid direct calls to aUniswapRouter, or there are no side-effects (has write access to storage)
  describe("modifyLiquidities", async () => {
    it('should route to uniV4Posm', async () => {
      const { pool, univ3Npm, univ4Posm } = await setupTests()
      // TODO: verify we are using the same WETH9 for Posm initialization
      const wethAddress = await univ3Npm.WETH9()
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
      // TODO: verify why here token is removed from active tokens, as it should be returned by the posm?
      expect(activeTokens.length).to.be.eq(0)
    })

    it('should revert if position recipient is not pool', async () => {
      const { pool, univ3Npm, univ4Posm } = await setupTests()
      // TODO: verify we are using the same WETH9 for Posm initialization
      const wethAddress = await univ3Npm.WETH9()
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
  })
});