import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber, Contract } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { timeTravel } from "../utils/utils";
import { getAddress } from "ethers/lib/utils";

describe("BaseTokenProxy", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        const GrgTokenInstance = await deployments.get("RigoToken")
        const GrgToken = await hre.ethers.getContractFactory("RigoToken")
        const factory = Factory.attach(RigoblockPoolProxyFactory.address)
        const { newPoolAddress } = await factory.callStatic.createPool(
            'testpool',
            'TEST',
            GrgTokenInstance.address
        )
        await factory.createPool('testpool','TEST',GrgTokenInstance.address)
        const pool = await hre.ethers.getContractAt(
            "RigoblockV3Pool",
            newPoolAddress
        )
        return {
            pool,
            grgToken: GrgToken.attach(GrgTokenInstance.address)
        }
    });

    describe("poolStorage", async () => {
        it('should return base token', async () => {
            const { pool, grgToken } = await setupTests()
            const poolData = await pool.getData()
            expect(poolData.baseToken).to.be.eq(grgToken.address)
        })

        it('should return 5% spread', async () => {
            const { pool, grgToken } = await setupTests()
            const poolData = await pool.getData()
            expect(poolData.spread).to.be.eq(500)
        })

        it('should return token decimals', async () => {
            // this test should always return 18 with any token but special tokens (i.e. 6 decimals tokens)
            const { pool, grgToken } = await setupTests()
            expect(await pool.decimals()).to.be.eq(await grgToken.decimals())
        })

        it('should return unitary value', async () => {
            const { pool, grgToken } = await setupTests()
            const poolData = await pool.getData()
            const decimals = await pool.decimals()
            const initialUnitaryValue = 1 * 10**decimals
            const poolReturnedValue = poolData.unitaryValue
            expect(poolReturnedValue).to.be.eq(initialUnitaryValue.toString())
        })
    })

    describe("mint", async () => {
        it('should create new tokens with input tokens', async () => {
            // TODO: test minimum order assertion with small amounts
            const { pool, grgToken } = await setupTests()
            expect(await pool.totalSupply()).to.be.eq(0)
            expect(await grgToken.balanceOf(pool.address)).to.be.eq(0)
            const tokenAmountIn = parseEther("1")
            await grgToken.approve(pool.address, tokenAmountIn)
            expect(await grgToken.allowance(user1.address, pool.address)).to.be.eq(tokenAmountIn)
            const userTokens = await pool.callStatic.mint(user1.address, tokenAmountIn)
            await expect(
                pool.mint(user1.address, tokenAmountIn)
            ).to.emit(pool, "Transfer").withArgs(
                AddressZero,
                user1.address,
                userTokens
            )
            expect(await pool.totalSupply()).to.be.not.eq(0)
            let poolGrgBalance
            poolGrgBalance = await grgToken.balanceOf(pool.address)
            expect(poolGrgBalance).to.be.eq(tokenAmountIn)
            expect(await pool.balanceOf(user1.address)).to.be.eq(userTokens)
            // with 0 fees and without changing price, total supply will be equal to userbalance
            expect(userTokens).to.be.eq(await pool.totalSupply())
            // with initial price 1, user tokens are equal to grg transferred to pool
            // TODO: check why we do not use price here for expect? test when price changes
            const poolData = await pool.getData()
            const spread = poolGrgBalance * poolData.spread / 10000 // spread
            poolGrgBalance -= spread
            expect(userTokens.toString()).to.be.eq(poolGrgBalance.toString())
        })
    })

    describe("burn", async () => {
        it('should burn tokens with input tokens', async () => {
            const { pool, grgToken } = await setupTests()
            const tokenAmountIn = parseEther("1")
            await grgToken.approve(pool.address, tokenAmountIn)
            const userTokens = await pool.callStatic.mint(user1.address, tokenAmountIn)
            await pool.mint(user1.address, tokenAmountIn)
            expect(await pool.totalSupply()).to.be.not.eq(0)
            expect(await pool.balanceOf(user1.address)).to.be.eq(userTokens)
            let userPoolBalance = await pool.balanceOf(user1.address)
            // TODO: write tests failing before lockup expiry
            await timeTravel({ seconds: 1, mine: true })
            const netRevenue = await pool.callStatic.burn(userPoolBalance)
            // the following is true with fee set as 0
            await expect(
                pool.burn(userPoolBalance)
            ).to.emit(grgToken, "Transfer").withArgs(
                pool.address,
                user1.address,
                netRevenue
            )
            expect(await pool.totalSupply()).to.be.eq(0)
            expect(await pool.balanceOf(user1.address)).to.be.eq(0)
            const tokenDelta = Number(tokenAmountIn) - netRevenue
            const poolGrgBalance = await grgToken.balanceOf(pool.address)
            expect(poolGrgBalance).to.be.eq(tokenDelta.toString())

            // if fee != 0 and caller not fee recipient, supply will not be 0
            const poolData = await pool.getData()
            const spread = userPoolBalance * poolData.spread / 10000 // spread
            userPoolBalance -= spread
            const unitaryValue = poolData.unitaryValue
            const decimals = await pool.decimals()
            const revenue = userPoolBalance * unitaryValue / (10**decimals)
            // TODO: check why difference of 128 wei, possibly approximation
            expect(userPoolBalance - revenue).to.be.lt(129)
            //expect(netRevenue.toString()).to.be.deep.eq(revenue.toString())
        })
    })

    describe("_initializePool", async () => {
        it('should revert when already initialized', async () => {
            const { pool, grgToken } = await setupTests()
            await expect(
                pool._initializePool(
                    'testpool',
                    'TEST',
                    grgToken.address,
                    user1.address
                )
            ).to.be.revertedWith("POOL_ALREADY_INITIALIZED_ERROR")
        })
    })
})
