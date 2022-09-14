import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber, Contract } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { timeTravel } from "../utils/utils";
import { getAddress } from "ethers/lib/utils";

describe("AUniswap", async () => {
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
        const AUniswapInstance = await deployments.get("AUniswap")
        await authority.setAdapter(AUniswapInstance.address, true)
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
        await authority.addMethod("0x88316456", AUniswapInstance.address)
        await authority.addMethod("0xc20ec580", AUniswapInstance.address)
        await authority.addMethod("0xa785a3d8", AUniswapInstance.address)
        await authority.addMethod("0x42966c68", AUniswapInstance.address)
        await authority.addMethod("0xfc6f7865", AUniswapInstance.address)
        await authority.addMethod("0x13ead562", AUniswapInstance.address)
        await authority.addMethod("0x0c49ccbe", AUniswapInstance.address)
        await authority.addMethod("0x219f5d17", AUniswapInstance.address)
        await authority.addMethod("0x12210e8a", AUniswapInstance.address)
        await authority.addMethod("0xdf2ab5bb", AUniswapInstance.address)
        await authority.addMethod("0x49404b7c", AUniswapInstance.address)
        await authority.addMethod("0x1c58db4f", AUniswapInstance.address)
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
            aUniswap: AUniswapInstance.address,
            authority,
            newPoolAddress,
            poolId
        }
    })

    describe("mint", async () => {
        it('should mint an NFT', async () => {
            const { grgToken, newPoolAddress, poolId } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
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
            await pool.burn(5)
            await pool.wrapETH(parseEther("100"))
            // TODO: hardhat does not recognize duplicate method with different inputs. Check if upgrading fixes
            //await pool.unwrapWETH9(parseEther("50"), pool.address)
            await pool.refundETH()
            //await pool.sweepToken(grgToken.address, 50, pool.address)
        })
    })

    describe("multicall", async () => {
        it('should send transaction in multicall format', async () => {
            const { grgToken, aUniswap, authority, newPoolAddress, poolId } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
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
            const encodedUnwrapData = pool.interface.encodeFunctionData(
                'unwrapWETH9(uint256,address)',
                [parseEther("50"), pool.address]
            )
            multicallPool.multicall([encodedUnwrapData])
            const encodedRefundData = pool.interface.encodeFunctionData(
                'refundETH'
            )
            await multicallPool.multicall([encodedRefundData])
            const encodedSweepData = pool.interface.encodeFunctionData(
                'sweepToken(address,uint256,address)',
                [
                    grgToken.address,
                    50,
                    pool.address
                ]
            )
            await multicallPool.multicall([encodedSweepData])
            await authority.removeMethod("0x12210e8a", aUniswap)
            await expect(
                multicallPool.multicall([encodedRefundData])
            ).to.be.revertedWith("POOL_METHOD_NOT_ALLOWED_ERROR")
        })
    })

    describe("burn", async () => {
        it('should call uniswap npm', async () => {
            const { grgToken, authority, aUniswap, newPoolAddress } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            await expect(authority.addMethod("0x42966c68", aUniswap))
                .to.be.revertedWith("SELECTOR_EXISTS_ERROR")
            await pool.burn(100)
        })
    })

    // TODO: check calldata vs memory in contract
    describe("swapExactTokensForTokens", async () => {
        it('should call uniswap router', async () => {
            const { grgToken, authority, aUniswap, newPoolAddress } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            await authority.addMethod("0x472b43f3", aUniswap)
            await pool.swapExactTokensForTokens(
                100,
                100,
                [grgToken.address, grgToken.address],
                newPoolAddress
            )
        })
    })

    describe("swapTokensForExactTokens", async () => {
        it('should call uniswap router', async () => {
            const { grgToken, authority, aUniswap, newPoolAddress } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            await authority.addMethod("0x42712a67", aUniswap)
            await pool.swapTokensForExactTokens(
                100,
                100,
                [grgToken.address, grgToken.address],
                newPoolAddress
            )
        })
    })
/*
    describe("exactInputSingle", async () => {
        it('should call uniswap router', async () => {
            const { grgToken, authority, aUniswap, newPoolAddress } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            await authority.addMethod("0x04e45aaf", aUniswap)
            await pool.exactInputSingle({
                tokenIn: grgToken.address,
                tokenOut: grgToken.address,
                fee: 0,
                recipient: newPoolAddress,
                amountIn: 20,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 4
            })
        })
    })
*/
    describe("exactInput", async () => {
        it('should call uniswap router', async () => {
            const { grgToken, authority, aUniswap, newPoolAddress } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            await authority.addMethod("0xb858183f", aUniswap)
            const mockPath = hre.ethers.utils.hexZeroPad(ethers.utils.hexlify(1), 64)
            await pool.exactInput({
                path: mockPath,
                recipient: newPoolAddress,
                amountIn: 20,
                amountOutMinimum: 1
            })
        })
    })
/*
    describe("exactOutputSingle", async () => {
        it('should call uniswap router', async () => {
            const { grgToken, authority, aUniswap, newPoolAddress } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            await authority.addMethod("0x5023b4df", aUniswap)
            await pool.exactOutputSingle({
                tokenIn: grgToken.address,
                tokenOut: grgToken.address,
                fee: 0,
                recipient: newPoolAddress,
                amountOut: 20,
                amountInMinimum: 1,
                sqrtPriceLimitX96: 4
            })
        })
    })
*/
    describe("exactOutput", async () => {
        it('should call uniswap router', async () => {
            const { grgToken, authority, aUniswap, newPoolAddress } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            await authority.addMethod("0x09b81346", aUniswap)
            const mockPath = hre.ethers.utils.hexZeroPad(ethers.utils.hexlify(1), 64)
            /*await pool.exactOutput({
                path: mockPath,
                recipient: newPoolAddress,
                amountOut: 20,
                amountInMinimum: 10
            })
            */
        })
    })
})
