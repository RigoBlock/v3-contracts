import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber, Contract } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { timeTravel } from "../utils/utils";
import { getAddress } from "ethers/lib/utils";

describe("AUniswapV3NPM", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        // TODO: check if shoud create custom fixture with less contracts initialization
        await deployments.fixture('tests-setup')
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        const GrgTokenInstance = await deployments.get("RigoToken")
        const GrgToken = await hre.ethers.getContractFactory("RigoToken")
        const AuthorityCoreInstance = await deployments.get("AuthorityCore")
        const AuthorityCore = await hre.ethers.getContractFactory("AuthorityCore")
        const authority = AuthorityCore.attach(AuthorityCoreInstance.address)
        const AUniswapV3NPMInstance = await deployments.get("AUniswapV3NPM")
        await authority.setAdapter(AUniswapV3NPMInstance.address, true)
        // "88316456": "mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))",
        // "c20ec580": "UNISWAP_V3_NPM_ADDRESS()",
        // "a785a3d8": "WethAddress()",
        // "42966c68": "burn(uint256)",
        // "fc6f7865": "collect((uint256,address,uint128,uint128))",
        // "13ead562": "createAndInitializePoolIfNecessary(address,address,uint24,uint160)",
        // "0c49ccbe": "decreaseLiquidity((uint256,uint128,uint256,uint256,uint256))",
        // "219f5d17": "increaseLiquidity((uint256,uint256,uint256,uint256,uint256,uint256))",
        // "12210e8a": "refundETH()",
        // "df2ab5bb": "sweepToken(address,uint256,address)",
        // "49404b7c": "unwrapWETH9(uint256,address)",
        // "1c58db4f": "wrapETH(uint256)"
        await authority.addMethod("0x88316456", AUniswapV3NPMInstance.address)
        await authority.addMethod("0xc20ec580", AUniswapV3NPMInstance.address)
        await authority.addMethod("0xa785a3d8", AUniswapV3NPMInstance.address)
        await authority.addMethod("0x42966c68", AUniswapV3NPMInstance.address)
        await authority.addMethod("0xfc6f7865", AUniswapV3NPMInstance.address)
        await authority.addMethod("0x13ead562", AUniswapV3NPMInstance.address)
        await authority.addMethod("0x0c49ccbe", AUniswapV3NPMInstance.address)
        await authority.addMethod("0x219f5d17", AUniswapV3NPMInstance.address)
        await authority.addMethod("0x12210e8a", AUniswapV3NPMInstance.address)
        await authority.addMethod("0xdf2ab5bb", AUniswapV3NPMInstance.address)
        await authority.addMethod("0x49404b7c", AUniswapV3NPMInstance.address)
        await authority.addMethod("0x1c58db4f", AUniswapV3NPMInstance.address)
        const AMulticallInstance = await deployments.get("AMulticall")
        await authority.setAdapter(AMulticallInstance.address, true)
        // "ac9650d8": "multicall(bytes[])"
        await authority.addMethod("0xac9650d8", AMulticallInstance.address)
        const factory = Factory.attach(RigoblockPoolProxyFactory.address)
        const { newPoolAddress, poolId } = await factory.callStatic.createPool(
            'testpool',
            'TEST',
            AddressZero
        )
        await factory.createPool('testpool','TEST',AddressZero)
        return {
            grgToken: GrgToken.attach(GrgTokenInstance.address),
            newPoolAddress,
            poolId
        }
    })

    describe("mint", async () => {
        it('should mint an NFT', async () => {
            const { grgToken, newPoolAddress, poolId } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswapV3NPM")
            const pool = Pool.attach(newPoolAddress)
            const amount = parseEther("100")
            // we send both Ether and GRG to the pool
            await user1.sendTransaction({ to: newPoolAddress, value: amount})
            await grgToken.transfer(newPoolAddress, amount)
            await pool.createAndInitializePoolIfNecessary(grgToken.address, grgToken.address, 1, 1)
            await pool.mint({
                token0: grgToken.address,
                token1: grgToken.address,
                fee: 10,
                tickLower: 1,
                tickUpper: 200,
                amount0Desired: 100,
                amount1Desired: 100,
                amount0Min: 0,
                amount1Min: 0,
                recipient: pool.address,
                deadline: 1
            })
            await pool.increaseLiquidity({
                tokenId: 5,
                amount0Desired: 100,
                amount1Desired: 100,
                amount0Min: 0,
                amount1Min: 0,
                deadline: 1
            })
            await pool.decreaseLiquidity({
                tokenId: 5,
                liquidity: 25,
                amount0Min: 0,
                amount1Min: 0,
                deadline: 1
            })
            await pool.collect({
                tokenId: 5,
                recipient: pool.address,
                amount0Max: parseEther("10000"),
                amount1Max: parseEther("10000")
            })
            await expect(pool.burn(5)).to.be.revertedWith("POOL_BURN_NOT_ENOUGH_ERROR")
            await pool.wrapETH(parseEther("100"))
            await pool.unwrapWETH9(parseEther("50"), pool.address)
            await pool.refundETH()
            await pool.sweepToken(grgToken.address, 50, pool.address)
            // TODO: test in multicall format
        })
    })

    describe("multicall", async () => {
        it('should send transaction in multicall format', async () => {
            const { grgToken, newPoolAddress, poolId } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswapV3NPM")
            const pool = Pool.attach(newPoolAddress)
            const amount = parseEther("100")
            // we send both Ether and GRG to the pool
            await user1.sendTransaction({ to: newPoolAddress, value: amount})
            await grgToken.transfer(newPoolAddress, amount)
            const encodedCreateData = pool.interface.encodeFunctionData(
                'createAndInitializePoolIfNecessary',
                [grgToken.address, grgToken.address, 1, 1]
            )
            const MulticallPool = await hre.ethers.getContractFactory("AMulticall")
            const multicallPool = MulticallPool.attach(newPoolAddress)
            await multicallPool.multicall([encodedCreateData])
            // while original uniswap client sends value for ETH transactions, we wrap ETH within the pool first.
            const encodedWrapData = pool.interface.encodeFunctionData(
                'wrapETH',
                [parseEther("100")]
            )
            await multicallPool.multicall(
                [
                    encodedWrapData,
                    encodedCreateData
                ]
            )
        })
    })
})
