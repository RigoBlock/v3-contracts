import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber, Contract, utils } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { deployContract, timeTravel } from "../utils/utils";
import { getAddress } from "ethers/lib/utils";

describe("Proxy", async () => {
    const [ user1, user2, user3 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const AuthorityInstance = await deployments.get("Authority")
        const Authority = await hre.ethers.getContractFactory("Authority")
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
            authority: Authority.attach(AuthorityInstance.address),
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
            ).to.be.revertedWith('PoolImplementationDirectCallNotAllowed()')
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
            const poolData = await pool.getPool()
            expect(poolData.name).to.be.eq('testpool')
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
            const poolData = await pool.getPoolParams()
            expect(poolData.transactionFee).to.be.eq(2)
        })

        it('should not set fee if caller not owner', async () => {
            const { pool } = await setupTests()
            await pool.setOwner(user2.address)
            await expect(pool.setTransactionFee(2)
          ).to.be.revertedWith('PoolCallerIsNotOwner()')
        })

        it('should not set fee higher than 1 percent', async () => {
            const { pool } = await setupTests()
            await expect(
              pool.setTransactionFee(101) // 100 / 10000 = 1%
            ).to.be.revertedWith('PoolFeeBiggerThanMax(100)')
        })
    })

    describe("setOwner", async () => {
        it('should revert if caller not owner', async () => {
            const { pool } = await setupTests()
            await expect(pool.connect(user2).setOwner(user2.address))
                .to.be.revertedWith('PoolCallerIsNotOwner()')
        })

        it('should revert if new owner null address', async () => {
            const { pool } = await setupTests()
            await expect(pool.setOwner(AddressZero))
                .to.be.revertedWith('PoolNullOwnerInput()')
        })

        it('should set owner', async () => {
            const { pool } = await setupTests()
            const owner = await pool.owner()
            expect(owner).to.be.eq(user1.address)
            const newOwner = user2.address
            await expect(pool.setOwner(newOwner))
                .to.emit(pool, "NewOwner").withArgs(owner, newOwner)
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
            ).to.be.revertedWith('PoolMintAmountIn()')
            await expect(
                pool.mint(user1.address, etherAmount, 0, { value: etherAmount })
            ).to.emit(pool, "Transfer").withArgs(
                AddressZero,
                user1.address,
                amount
            )
            expect(await pool.totalSupply()).to.be.not.eq(0)
            expect(await pool.balanceOf(user1.address)).to.be.eq(amount)
            const poolData = await pool.getPoolParams()
            // TODO: check if should add test with second user mint (which will have positive spread)
            //const spread = poolData.spread / 10000
            //const netAmount = amount / (1 - spread)
            const netAmount = amount
            expect(netAmount.toString()).to.be.eq(etherAmount.toString())
        })

        it('should revert with order below minimum', async () => {
            const { pool } = await setupTests()
            const etherAmount = parseEther("0.00012")
            await expect(pool.mint(user1.address, etherAmount, 0, { value: etherAmount })
            ).to.be.revertedWith('PoolAmountSmallerThanMinumum(1000)')
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
            // TODO: verify we are reverting when recipient is not whitelisted, vs when caller is not whitelisted
            await expect(
                pool.mint(recipient, etherAmount, 0, { value: etherAmount })
            ).to.be.revertedWith('PoolCallerNotWhitelisted()')
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
            let feeCollector = (await pool.getPoolParams()).feeCollector
            expect(await pool.owner()).to.be.eq(feeCollector)
            // when fee collector is mint recipient, fee collector receives full amount
            let mintedAmount = await pool.callStatic.mint(user1.address, etherAmount, 0, { value: etherAmount })
            await expect(
                pool.mint(user1.address, etherAmount, 0, { value: etherAmount })
            ).to.emit(pool, "Transfer").withArgs(AddressZero, feeCollector, mintedAmount)
            // when fee collector not same as recipient, fee gets allocated to fee recipient
            const fee = mintedAmount.div(10000).mul(transactionFee)
            // TODO: fix when pipeline correctly set
            mintedAmount = await expect(pool.callStatic.mint(user2.address, etherAmount, 0, { value: etherAmount })).to.be.reverted
            /*await expect(
                pool.mint(user2.address, etherAmount, 0, { value: etherAmount })
            )
                .to.emit(pool, "Transfer").withArgs(AddressZero, feeCollector, fee)
                .and.to.emit(pool, "Transfer").withArgs(AddressZero, user2.address, mintedAmount)
            await pool.changeFeeCollector(user3.address)
            feeCollector = (await pool.getPoolParams()).feeCollector
            expect(feeCollector).to.be.eq(user3.address)
            await pool.mint(user1.address, etherAmount, 0, { value: etherAmount })
            expect(await pool.balanceOf(user3.address)).to.be.eq(fee)*/
        })
    })

    describe("burn", async () => {
        it('should burn tokens', async () => {
            const { authority, pool } = await setupTests()
            const etherAmount = parseEther("1")
            await pool.mint(user1.address, etherAmount, 0, { value: etherAmount })
            const userPoolBalance = await pool.balanceOf(user1.address)
            // TODO: should be able to burn after 1 second, requires 2
            await timeTravel({ seconds: 2592000, mine: true })
            expect(await hre.ethers.provider.getBalance(pool.address)).to.be.deep.eq(etherAmount)
            const preBalance = await hre.ethers.provider.getBalance(user1.address)
            await expect(pool.callStatic.burn(userPoolBalance, 1)).to.be.reverted

            // TODO: add correct pipeline when installed
            const mockAdapter = user3.address
            await authority.setAdapter(mockAdapter, true)
            // 64397f68 'getAppTokenBalances(uint256)'
            await authority.addMethod("0x64397f68", mockAdapter)
            // 22fa7d04 'getCrossSqrtPriceX96(address,address)'
            await authority.addMethod("0x22fa7d04", mockAdapter)

            const netRevenue = await expect(pool.callStatic.burn(userPoolBalance, 1)).to.be.reverted

            const { unitaryValue } = await pool.getPoolTokens()
            //expect(netRevenue).to.be.eq(BigNumber.from(userPoolBalance).mul(95).div(100).mul(unitaryValue).div(etherAmount))
            // the following is true with fee set as 0
            // TODO: fix when EApps is correctly initialized
            /*await expect(
                pool.burn(userPoolBalance, 1)
            //).to.emit(pool, "Transfer").withArgs(
            //    user1.address,
            //    AddressZero,
            //    userPoolBalance
            //)
            ).to.be.revertedWith("Transaction reverted without a reason string")*/

            //const spreadAmount = BigNumber.from(etherAmount).sub(etherAmount.div(100).mul(95).div(100).mul(95))
            //expect(await hre.ethers.provider.getBalance(pool.address)).to.be.deep.eq(spreadAmount)
            //const postBalance = await hre.ethers.provider.getBalance(user1.address)
            //expect(postBalance).to.be.gt(preBalance)
        })

        it('should allocate fee tokens to fee recipient', async () => {
            const { pool } = await setupTests()
            const etherAmount = parseEther("1")
            await pool.mint(user1.address, etherAmount, 0, { value: etherAmount })
            await timeTravel({ seconds: 2592000, mine: true })
            const transactionFee = 50
            await pool.setTransactionFee(transactionFee)
            let userPoolBalance = await pool.balanceOf(user1.address)
            await expect(
                pool.burn(userPoolBalance.div(2), 1)
            //).to.emit(pool, "Transfer").withArgs(user1.address, AddressZero, userPoolBalance.div(2))
            // TODO: fix when EApps is correctly initialized
            ).to.be.revertedWith("Transaction reverted without a reason string")
            const feeCollector = user3.address
            await pool.changeFeeCollector(feeCollector)
            userPoolBalance = await pool.balanceOf(user1.address)
            const fee = userPoolBalance.div(10000).mul(transactionFee)
            const burntAmount = userPoolBalance.sub(fee)
            await expect(
                pool.burn(userPoolBalance, 1)
            )
                //.to.emit(pool, "Transfer").withArgs(user1.address, feeCollector, fee)
                //.and.to.emit(pool, "Transfer").withArgs(user1.address, AddressZero, burntAmount)
                .to.be.revertedWith("Transaction reverted without a reason string")
        })
    })

    describe("initializePool", async () => {
        it('should revert when already initialized', async () => {
            const { pool } = await setupTests()
            let symbol = utils.formatBytes32String("TEST")
            symbol = utils.hexDataSlice(symbol, 0, 8)
            await expect(pool.initializePool())
                .to.be.revertedWith("VM Exception while processing transaction: reverted with custom error 'PoolAlreadyInitialized()'")
        })
    })

    describe("setPrices", async () => {
        it('should update storage when caller is any wallet', async () => {
            const { authority, pool } = await setupTests()
            await pool.setOwner(user2.address)
            await expect(pool.setUnitaryValue())
                .to.be.revertedWith('PoolSupplyIsNullOrDust()')
            const etherAmount = parseEther("0.1")
            await pool.mint(user1.address, etherAmount, 0, { value: etherAmount })
            // TODO: nav is set to 1, but should be parseEther("1"), this because base token not
            // correctly accounted for.
            await expect(pool.setUnitaryValue())
                .to.emit(pool, "NewNav").withArgs(
                user1.address,
                pool.address,
                1
            )
        })

        it.skip('should revert with less than 3% liquidity', async () => {
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
    })

    describe("setKycProvider", async () => {
        it('should revert if caller not pool owner', async () => {
            const { pool } = await setupTests()
            await expect(
                pool.connect(user2).setKycProvider(user2.address)
            ).to.be.revertedWith('PoolCallerIsNotOwner()')
        })

        it('should set pool kyc provider', async () => {
            const { pool } = await setupTests()
            expect((await pool.getPoolParams()).kycProvider).to.be.eq(AddressZero)
            await expect(pool.setKycProvider(user2.address))
                .to.be.revertedWith('PoolInputIsNotContract()')
            await expect(pool.setKycProvider(pool.address))
                .to.emit(pool, "KycProviderSet").withArgs(pool.address, pool.address)
            expect((await pool.getPoolParams()).kycProvider).to.be.eq(pool.address)
        })
    })

    describe("changeFeeCollector", async () => {
        it('should revert if caller not pool owner', async () => {
            const { pool } = await setupTests()
            await expect(
                pool.connect(user2).changeFeeCollector(user2.address)
            ).to.be.revertedWith('PoolCallerIsNotOwner()')
        })

        it('should set fee collector', async () => {
            const { pool } = await setupTests()
            // default fee collector is pool owner
            expect((await pool.getPoolParams()).feeCollector).to.be.eq(await pool.owner())
            await expect(
                pool.changeFeeCollector(user2.address)
            ).to.emit(pool, "NewCollector").withArgs(user1.address, pool.address, user2.address)
            expect((await pool.getPoolParams()).feeCollector).to.be.eq(user2.address)
        })
    })

    describe("changeSpread", async () => {
        it('should revert if caller not pool owner', async () => {
            const { pool } = await setupTests()
            await expect(
                pool.connect(user2).changeSpread(1)
            ).to.be.revertedWith('PoolCallerIsNotOwner()')
        })

        it('should revert with rogue values', async () => {
            const { pool } = await setupTests()
            // spread must always be != 0, otherwise default value from immutable storage will be returned (i.e. initial spread)
            await expect(
                pool.changeSpread(0)
            ).to.be.revertedWith('PoolSpreadInvalid(500)')
            await expect(
                pool.changeSpread(1001)
            ).to.be.revertedWith('PoolSpreadInvalid(500)')
        })

        it('should change spread', async () => {
            const { pool } = await setupTests()
            expect((await pool.getPoolParams()).spread).to.be.eq(500)
            await expect(pool.changeSpread(100))
                .to.emit(pool, "SpreadChanged").withArgs(pool.address, 100)
            expect((await pool.getPoolParams()).spread).to.be.eq(100)
        })
    })

    describe("changeMinPeriod", async () => {
        it('should revert if caller not pool owner', async () => {
            const { pool } = await setupTests()
            await expect(
                pool.connect(user2).changeMinPeriod(1)
            ).to.be.revertedWith('PoolCallerIsNotOwner()')
        })

        it('should revert with rogue values', async () => {
            const { pool } = await setupTests()
            // min lockup is 10 seconds. TODO: verify if should be 10 blocks
            await expect(
                pool.changeMinPeriod(1)
            ).to.be.revertedWith('PoolLockupPeriodInvalid(10, 2592000)')
            // max 30 days lockup
            await expect(
                pool.changeMinPeriod(2592001)
            ).to.be.revertedWith('PoolLockupPeriodInvalid(10, 2592000)')
        })

        it('should change spread', async () => {
            const { pool } = await setupTests()
            expect((await pool.getPoolParams()).minPeriod).to.be.eq(2592000)
            const newPeriod = 2592000
            await expect(pool.changeMinPeriod(newPeriod))
                .to.emit(pool, "MinimumPeriodChanged").withArgs(pool.address, newPeriod)
            expect((await pool.getPoolParams()).minPeriod).to.be.eq(newPeriod)
        })
    })
})
