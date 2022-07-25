import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber, Contract } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { getAddress } from "ethers/lib/utils";

describe("Proxy", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        const NavVerifierInstance = await deployments.get("NavVerifier")
        const NavVerifier = await hre.ethers.getContractFactory("NavVerifier")
        const factory = Factory.attach(RigoblockPoolProxyFactory.address)
        const { newPoolAddress } = await factory.callStatic.createPool(
            'testpool',
            'TEST',
            AddressZero
        )
        await factory.createPool('testpool','TEST',AddressZero)
        const pool = await hre.ethers.getContractAt(
            "RigoblockV3Pool",
            newPoolAddress
        )
        return {
            pool,
            navVerifier: NavVerifier.attach(NavVerifierInstance.address)
        }
    });

    describe("receive", async () => {
        it('should receive ether', async () => {
            const { pool } = await setupTests()
            const etherAmount = parseEther("5")
            await user1.sendTransaction({ to: pool.address, value: etherAmount})
            await expect(await hre.ethers.provider.getBalance(pool.address)).to.be.deep.eq(etherAmount)
        })
    })

    describe("poolStorage", async () => {
        it('should return pool name from new pool', async () => {
            const { pool } = await setupTests()
            const poolData = await pool.getData()
            expect(poolData.poolName).to.be.eq('testpool')
        })

        it('should return pool owner', async () => {
            const { pool } = await setupTests()
            expect(await pool.owner()).to.be.eq(user1.address)
        })
    })

    describe("setTransactionFee", async () => {
        it('should set the transaction fee', async () => {
            const { pool } = await setupTests()
            await pool.setTransactionFee(2)
            const poolData = await pool.getAdminData()
            expect(poolData.transactionFee).to.be.eq(2)
        })

        it('should not set fee if caller not owner', async () => {
            const { pool } = await setupTests()
            await pool.setOwner(user2.address)
            await expect(pool.setTransactionFee(2)
            ).to.be.revertedWith("OWNED_CALLER_IS_NOT_OWNER_ERROR")
        })

        it('should not set fee higher than 1 percent', async () => {
            const { pool } = await setupTests()
            await expect(
              pool.setTransactionFee(101) // 100 / 10000 = 1%
            ).to.be.revertedWith("POOL_FEE_HIGHER_THAN_ONE_PERCENT_ERROR")
        })
    })

    describe("mint", async () => {
        it('should create new tokens', async () => {
            const { pool } = await setupTests()
            expect(await pool.totalSupply()).to.be.eq(0)
            const etherAmount = parseEther("1")
            const name = await pool.name()
            const symbol = await pool.symbol()
            const amount = await pool.callStatic.mint(
                  user1.address,
                  etherAmount,
                  { value: etherAmount }
            )
            await expect(
                pool.mint(user1.address, etherAmount, { value: etherAmount })
            ).to.emit(pool, "Transfer").withArgs(
                AddressZero,
                user1.address,
                amount
            )
            expect(await pool.totalSupply()).to.be.not.eq(0)
            expect(await pool.balanceOf(user1.address)).to.be.eq(amount)
            const poolData = await pool.getData()
            const spread = poolData.spread / 10000 // spread
            const netAmount = amount / (1 - spread)
            expect(netAmount.toString()).to.be.eq(etherAmount.toString())
        })

        it('should revert with order below minimum', async () => {
            const { pool } = await setupTests()
            const etherAmount = parseEther("0.0001")
            await expect(pool.mint(user1.address, etherAmount, { value: etherAmount })
            ).to.be.revertedWith("POOL_AMOUNT_SMALLER_THAN_MINIMUM_ERROR")
        })
    })

    describe("_initializePool", async () => {
        it('should revert when already initialized', async () => {
            const { pool } = await setupTests()
            await expect(
                pool._initializePool(
                    'testpool',
                    'TEST',
                    AddressZero,
                    user1.address
                )
            ).to.be.revertedWith("POOL_ALREADY_INITIALIZED_ERROR")
        })
    })

    describe("setPrices", async () => {
        it('should revert when caller is not owner', async () => {
            const { pool } = await setupTests()
            await pool.setOwner(user2.address)
            const newPrice = parseEther("1.1")
            const signaturevaliduntilBlock = 1 // relevant only when checked
            const bytes32hash = hre.ethers.utils.formatBytes32String('notused')
            await expect(
                pool.setUnitaryValue(
                    newPrice,
                    signaturevaliduntilBlock,
                    bytes32hash,
                    bytes32hash
                )
            ).to.be.revertedWith("OWNED_CALLER_IS_NOT_OWNER_ERROR")
        })

        it('should revert when price error', async () => {
            const { pool } = await setupTests()
            const newPrice = parseEther("11")
            const signaturevaliduntilBlock = 1 // relevant only when checked
            const bytes32hash = hre.ethers.utils.formatBytes32String('notused')
            await expect(
                pool.setUnitaryValue(
                    newPrice,
                    signaturevaliduntilBlock,
                    bytes32hash,
                    bytes32hash
                )
            ).to.be.revertedWith("POOL_INPUT_VALUE_ERROR")
        })

        it('should set price when caller is owner', async () => {
            const { pool, navVerifier } = await setupTests()
            const newValue = parseEther("1.1")
            const signaturevaliduntilBlock = 1 // relevant only when checked
            const bytes32hash = hre.ethers.utils.formatBytes32String('notused')
            const bytesSignedData = hre.ethers.utils.formatBytes32String('notused')
            await expect(
                pool.setUnitaryValue(
                    newValue,
                    signaturevaliduntilBlock,
                    bytes32hash,
                    bytes32hash
                )
            ).to.be.revertedWith("POOL_METHOD_NOT_ALLOWED_ERROR")

            const AuthorityCoreInstance = await deployments.get("AuthorityCore")
            const AuthorityCore = await hre.ethers.getContractFactory("AuthorityCore")
            const authority = AuthorityCore.attach(AuthorityCoreInstance.address)
            //"9e4e93d0": "isValidNav(uint256,uint256,bytes32,bytes)"
            await authority.addMethod("0x9e4e93d0", navVerifier.address)
            await expect(
                pool.setUnitaryValue(
                    newValue,
                    signaturevaliduntilBlock,
                    bytes32hash,
                    bytes32hash
                )
            ).to.emit(pool, "NewNav").withArgs(
                user1.address,
                pool.address,
                newValue
            )
        })
    })
})
