import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber, Contract } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { getAddress } from "ethers/lib/utils";

describe("Proxy", async () => {
    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        const ResitryInstance = await deployments.get("PoolRegistry")
        const Registry = await hre.ethers.getContractFactory("PoolRegistry")
        return {
          factory: Factory.attach(RigoblockPoolProxyFactory.address),
          registry: Registry.attach(ResitryInstance.address)
        }
    });

    describe("poolStorage", async () => {
        it('should return pool name from new pool', async () => {
            const { factory } = await setupTests()
            const { newPoolAddress } = await factory.callStatic.createPool('testpool','TEST')
            const txReceipt = await factory.createPool('testpool', 'TEST')
            const pool = await hre.ethers.getContractAt("RigoblockV3Pool", newPoolAddress)
            const poolData = await pool.getData()
            expect(poolData.poolName).to.be.eq('testpool')
        })

        it('should return pool owner', async () => {
            const { factory, registry } = await setupTests()
            const { newPoolAddress } = await factory.callStatic.createPool('testpool','TEST')
            await factory.createPool('testpool', 'TEST')
            const pool = await hre.ethers.getContractAt("RigoblockV3Pool", newPoolAddress)
            const [ user1 ] = waffle.provider.getWallets()
            expect(await pool.owner()).to.be.eq(user1.address)
        })
    })

    describe("setTransactionFee", async () => {
        it('should set the transaction fee', async () => {
            const { factory, registry } = await setupTests()
            const { newPoolAddress } = await factory.callStatic.createPool('testpool','TEST')
            await factory.createPool('testpool', 'TEST')
            const pool = await hre.ethers.getContractAt("RigoblockV3Pool", newPoolAddress)
            await pool.setTransactionFee(2)
            const poolData = await pool.getAdminData()
            expect(poolData.transactionFee).to.be.eq(2)
        })

        it('should not set fee if caller not owner', async () => {
            const { factory, registry } = await setupTests()
            const { newPoolAddress } = await factory.callStatic.createPool('testpool','TEST')
            await factory.createPool('testpool', 'TEST')
            const pool = await hre.ethers.getContractAt("RigoblockV3Pool", newPoolAddress)
            const [ user1, user2 ] = waffle.provider.getWallets()
            await pool.setOwner(user2.address)
            await expect(pool.setTransactionFee(2)
            ).to.be.revertedWith("OWNED_CALLER_IS_NOT_OWNER_ERROR")
        })

        it('should not set fee higher than 1 percent', async () => {
            const { factory, registry } = await setupTests()
            const { newPoolAddress } = await factory.callStatic.createPool('testpool','TEST')
            await factory.createPool('testpool', 'TEST')
            const pool = await hre.ethers.getContractAt("RigoblockV3Pool", newPoolAddress)
            const [ user1, user2 ] = waffle.provider.getWallets()
            await expect(
              pool.setTransactionFee(101) // 100 / 10000 = 1%
            ).to.be.revertedWith("POOL_FEE_HIGHER_THAN_ONE_PERCENT_ERROR")
        })
    })

    describe("mint", async () => {
        it('should create new tokens', async () => {
            const { factory, registry } = await setupTests()
            const { newPoolAddress } = await factory.callStatic.createPool('testpool','TEST')
            await factory.createPool('testpool', 'TEST')
            const pool = await hre.ethers.getContractAt("RigoblockV3Pool", newPoolAddress)
            expect(await pool.totalSupply()).to.be.eq(0)
            const etherAmount = parseEther("1")
            const [ user1 ] = waffle.provider.getWallets()
            const name = await pool.name()
            const symbol = await pool.symbol()
            const amount = await pool.callStatic.mint({ value: etherAmount })
            await expect(
                pool.mint({ value: etherAmount })
            ).to.emit(pool, "Mint").withArgs(
                user1.address,
                newPoolAddress,
                user1.address,
                etherAmount,
                amount
            )
            expect(await pool.totalSupply()).to.be.not.eq(0)
            expect(await pool.balanceOf(user1.address)).to.be.eq(amount)
        })

        it('should revert with order below minimum', async () => {
            const { factory, registry } = await setupTests()
            const { newPoolAddress } = await factory.callStatic.createPool('testpool','TEST')
            await factory.createPool('testpool', 'TEST')
            const pool = await hre.ethers.getContractAt("RigoblockV3Pool", newPoolAddress)
            const etherAmount = parseEther("0.0001")
            await expect(pool.mint({ value: etherAmount })
            ).to.be.revertedWith("POOL_AMOUNT_SMALLER_THAN_MINIMUM_ERROR")
        })
    })

    describe("_initializePool", async () => {
        it('should revert when already initialized', async () => {
            const { factory, registry } = await setupTests()
            const { newPoolAddress } = await factory.callStatic.createPool('testpool','TEST')
            await factory.createPool('testpool', 'TEST')
            const pool = await hre.ethers.getContractAt("RigoblockV3Pool", newPoolAddress)
            await expect(pool._initializePool('testpool','TEST', newPoolAddress)
            ).to.be.revertedWith("POOL_ALREADY_INITIALIZED_ERROR")
        })
    })
})
