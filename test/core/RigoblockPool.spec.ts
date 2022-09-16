import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber, Contract } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { deployContract, timeTravel } from "../utils/utils";
import { getAddress } from "ethers/lib/utils";

describe("Proxy", async () => {
    const [ user1, user2, user3 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
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
            factory,
            pool
        }
    });

    describe("receive", async () => {
        it('should revert if direct call to implementation', async () => {
            const { factory } = await setupTests()
            const etherAmount = parseEther("5")
            const implementation = await factory.implementation()
            await expect(
                user1.sendTransaction({ to: implementation, value: etherAmount})
            ).to.be.revertedWith("POOL_IMPLEMENTATION_DIRECT_CALL_NOT_ALLOWED_ERROR")
        })

        it('should receive ether', async () => {
            const { pool } = await setupTests()
            const etherAmount = parseEther("5")
            await user1.sendTransaction({ to: pool.address, value: etherAmount})
            expect(await hre.ethers.provider.getBalance(pool.address)).to.be.deep.eq(etherAmount)
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
                  0,
                  { value: etherAmount }
            )
            await expect(
                pool.mint(user1.address, parseEther("2"), 0, { value: etherAmount })
            ).to.be.revertedWith("POOL_MINT_AMOUNTIN_ERROR")
            await expect(
                pool.mint(user1.address, etherAmount, 0, { value: etherAmount })
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
            await expect(pool.mint(user1.address, etherAmount, 0, { value: etherAmount })
            ).to.be.revertedWith("POOL_AMOUNT_SMALLER_THAN_MINIMUM_ERROR")
        })

        it('should revert if user not whitelisted when whitelist enabled', async () => {
            const { pool } = await setupTests()
            const etherAmount = parseEther("1")
            const source = `
            contract Kyc {
                mapping(address => bool) whitelisted;
                function whitelistUser(address user) public { whitelisted[user] = true; }
                function isWhitelistedUser(address user) public view returns (bool) { return whitelisted[user] == true; }
            }`
            const kyc = await deployContract(user1, source)
            await pool.setKycProvider(kyc.address)
            const recipient = user1.address
            await expect(
                pool.mint(recipient, etherAmount, 0, { value: etherAmount })
            ).to.be.revertedWith("POOL_CALLER_NOT_WHITELISTED_ERROR")
            await kyc.whitelistUser(recipient)
            const mintedAmount = await pool.callStatic.mint(recipient, etherAmount, 0, { value: etherAmount })
            await expect(
                pool.mint(recipient, etherAmount, 0, { value: etherAmount })
            ).to.emit(pool, "Transfer").withArgs(AddressZero, recipient, mintedAmount)
        })

        it('should allocate fee tokens to fee recipient', async () => {
            const { pool } = await setupTests()
            const etherAmount = parseEther("1")
            const transactionFee = 50
            await pool.setTransactionFee(transactionFee)
            let feeCollector = (await pool.getAdminData()).feeCollector
            expect(await pool.owner()).to.be.eq(feeCollector)
            // when fee collector is mint recipient, fee collector receives full amount
            let mintedAmount = await pool.callStatic.mint(user1.address, etherAmount, 0, { value: etherAmount })
            await expect(
                pool.mint(user1.address, etherAmount, 0, { value: etherAmount })
            ).to.emit(pool, "Transfer").withArgs(AddressZero, feeCollector, mintedAmount)
            // when fee collector not same as recipient, fee gets allocated to fee recipient
            const fee = mintedAmount.div(10000).mul(transactionFee)
            mintedAmount = await pool.callStatic.mint(user2.address, etherAmount, 0, { value: etherAmount })
            await expect(
                pool.mint(user2.address, etherAmount, 0, { value: etherAmount })
            )
                .to.emit(pool, "Transfer").withArgs(AddressZero, feeCollector, fee)
                .and.to.emit(pool, "Transfer").withArgs(AddressZero, user2.address, mintedAmount)
            await pool.changeFeeCollector(user3.address)
            feeCollector = (await pool.getAdminData()).feeCollector
            expect(feeCollector).to.be.eq(user3.address)
            await pool.mint(user1.address, etherAmount, 0, { value: etherAmount })
            expect(await pool.balanceOf(user3.address)).to.be.eq(fee)
        })
    })

    describe("burn", async () => {
        it('should burn tokens', async () => {
            const { pool } = await setupTests()
            const etherAmount = parseEther("1")
            await pool.mint(user1.address, etherAmount, 0, { value: etherAmount })
            const userPoolBalance = await pool.balanceOf(user1.address)
            // TODO: should be able to burn after 1 second, just like with base token
            await timeTravel({ seconds: 2, mine: true })
            // the following is true with fee set as 0
            await expect(
                pool.burn(userPoolBalance, 1)
            ).to.emit(pool, "Transfer").withArgs(
                user1.address,
                AddressZero,
                userPoolBalance
            )
        })

        it('should allocate fee tokens to fee recipient', async () => {
            const { pool } = await setupTests()
            const etherAmount = parseEther("1")
            await pool.mint(user1.address, etherAmount, 0, { value: etherAmount })
            await timeTravel({ seconds: 2, mine: true })
            const transactionFee = 50
            await pool.setTransactionFee(transactionFee)
            let userPoolBalance = await pool.balanceOf(user1.address)
            await expect(
                pool.burn(userPoolBalance.div(2), 1)
            ).to.emit(pool, "Transfer").withArgs(user1.address, AddressZero, userPoolBalance.div(2))
            const feeCollector = user3.address
            await pool.changeFeeCollector(feeCollector)
            userPoolBalance = await pool.balanceOf(user1.address)
            const fee = userPoolBalance.div(10000).mul(transactionFee)
            const burntAmount = userPoolBalance.sub(fee)
            await expect(
                pool.burn(userPoolBalance, 1)
            )
                .to.emit(pool, "Transfer").withArgs(user1.address, feeCollector, fee)
                .and.to.emit(pool, "Transfer").withArgs(user1.address, AddressZero, burntAmount)
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
            await expect(pool.setUnitaryValue(newPrice))
                .to.be.revertedWith("OWNED_CALLER_IS_NOT_OWNER_ERROR")
        })

        it('should revert when price error', async () => {
            const { pool } = await setupTests()
            const newPrice = parseEther("11")
            await expect(pool.setUnitaryValue(newPrice))
                .to.be.revertedWith("POOL_INPUT_VALUE_ERROR")
        })

        it('should revert with less than 3% liquidity', async () => {
            const { pool } = await setupTests()
            const etherAmount = parseEther("0.1")
            await pool.mint(user1.address, etherAmount, 0, { value: etherAmount })
            let newPrice
            newPrice = parseEther("4.99")
            await pool.setUnitaryValue(newPrice)
            newPrice = parseEther("24.94")
            await pool.setUnitaryValue(newPrice)
            newPrice = parseEther("35.1")
            // TODO: should revert at reciprocal of 3%, probably approximation error
            await expect(pool.setUnitaryValue(newPrice))
                .to.be.revertedWith("POOL_CURRENCY_BALANCE_TOO_LOW_ERROR")
        })

        it('should set price when caller is owner', async () => {
            const { pool } = await setupTests()
            const newValue = parseEther("1.1")
            await expect(pool.setUnitaryValue(newValue))
                .to.be.revertedWith("POOL_SUPPLY_NULL_ERROR")
            const etherAmount = parseEther("0.1")
            await pool.mint(user1.address, etherAmount, 0, { value: etherAmount })
            await expect(pool.setUnitaryValue(newValue))
                .to.emit(pool, "NewNav").withArgs(
                user1.address,
                pool.address,
                newValue
            )
        })
    })

    describe("setKycProvider", async () => {
        it('should revert if caller not pool owner', async () => {
            const { pool } = await setupTests()
            await expect(
                pool.connect(user2).setKycProvider(user2.address)
            ).to.be.revertedWith("OWNED_CALLER_IS_NOT_OWNER_ERROR")
        })

        it('should set pool kyc provider', async () => {
            const { pool } = await setupTests()
            expect(await pool.getKycProvider()).to.be.eq(AddressZero)
            await expect(pool.setKycProvider(user2.address)).to.be.revertedWith("POOL_INPUT_NOT_CONTRACT_ERROR")
            await pool.setKycProvider(pool.address)
            expect(await pool.getKycProvider()).to.be.eq(pool.address)
        })
    })

    describe("changeFeeCollector", async () => {
        it('should revert if caller not pool owner', async () => {
            const { pool } = await setupTests()
            await expect(
                pool.connect(user2).changeFeeCollector(user2.address)
            ).to.be.revertedWith("OWNED_CALLER_IS_NOT_OWNER_ERROR")
        })

        it('should set fee collector', async () => {
            const { pool } = await setupTests()
            // default fee collector is pool owner
            expect((await pool.getAdminData()).feeCollector).to.be.eq(await pool.owner())
            await expect(
                pool.changeFeeCollector(user2.address)
            ).to.emit(pool, "NewCollector").withArgs(user1.address, pool.address, user2.address)
            expect((await pool.getAdminData()).feeCollector).to.be.eq(user2.address)
        })
    })

    describe("changeSpread", async () => {
        it('should revert if caller not pool owner', async () => {
            const { pool } = await setupTests()
            await expect(
                pool.connect(user2).changeSpread(1)
            ).to.be.revertedWith("OWNED_CALLER_IS_NOT_OWNER_ERROR")
        })

        it('should revert with rogue values', async () => {
            const { pool } = await setupTests()
            await expect(
                pool.changeSpread(0)
            ).to.be.revertedWith("POOL_SPREAD_NULL_ERROR")
            await expect(
                pool.changeSpread(1001)
            ).to.be.revertedWith("POOL_SPREAD_TOO_HIGH_ERROR")
        })

        it('should change spread', async () => {
            const { pool } = await setupTests()
            expect((await pool.getData()).spread).to.be.eq(500)
            await pool.changeSpread(100)
            expect((await pool.getData()).spread).to.be.eq(100)
        })
    })

    describe("changeMinPeriod", async () => {
        it('should revert if caller not pool owner', async () => {
            const { pool } = await setupTests()
            await expect(
                pool.connect(user2).changeMinPeriod(1)
            ).to.be.revertedWith("OWNED_CALLER_IS_NOT_OWNER_ERROR")
        })

        it('should revert with rogue values', async () => {
            const { pool } = await setupTests()
            await expect(
                pool.changeMinPeriod(1)
            ).to.be.revertedWith("POOL_CHANGE_MIN_LOCKUP_PERIOD_ERROR")
            // max 30 days lockup
            await expect(
                pool.changeMinPeriod(2592001)
            ).to.be.revertedWith("POOL_CHANGE_MIN_LOCKUP_PERIOD_ERROR")
        })

        it('should change spread', async () => {
            const { pool } = await setupTests()
            expect((await pool.getAdminData()).minPeriod).to.be.eq(2)
            await pool.changeMinPeriod(2592000)
            expect((await pool.getAdminData()).minPeriod).to.be.eq(2592000)
        })
    })
})
