import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber, Contract, utils } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { deployContract, timeTravel } from "../utils/utils";
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
            factory,
            grgToken: GrgToken.attach(GrgTokenInstance.address)
        }
    });

    describe("poolStorage", async () => {
        it('should return pool implementation immutables', async () => {
            const { pool } = await setupTests()
            const authority = await deployments.get("Authority")
            expect(await pool.authority()).to.be.eq(authority.address)
            // TODO: we should have an assertion that the version is different if implementation has changed
            //   so we are prompted to change the version in the deployment constants.
            expect(await pool.VERSION()).to.be.eq('4.0.0')
        })
    })

    describe("getPool", async () => {
        it('should return pool immutable parameters', async () => {
            const { pool, grgToken } = await setupTests()
            const poolData = await pool.getPool()
            //expect(poolData.name).to.be.eq('testpool')
            expect(poolData.symbol).to.be.eq('TEST')
            expect(poolData.decimals).to.be.eq(await grgToken.decimals())
            expect(poolData.decimals).to.be.eq(18)
            expect(poolData.owner).to.be.eq(user1.address)
            expect(poolData.baseToken).to.be.eq(grgToken.address)
            expect(await pool.name()).to.be.eq(poolData.name)
            expect(await pool.symbol()).to.be.eq(poolData.symbol)
            expect(await pool.decimals()).to.be.eq(poolData.decimals)
            expect(await pool.owner()).to.be.eq(poolData.owner)
        })
    })

    describe("getPoolParams", async () => {
        it('should return pool parameters', async () => {
            const { pool } = await setupTests()
            const poolData = await pool.getPoolParams()
            // 30 days default minimum period
            expect(poolData.minPeriod).to.be.eq(2592000)
            // 5% default spread
            expect(poolData.spread).to.be.eq(500)
            expect(poolData.transactionFee).to.be.eq(0)
            // pool operator default fee collector
            expect(poolData.feeCollector).to.be.eq(user1.address)
            expect(poolData.kycProvider).to.be.eq(AddressZero)
        })
    })

    describe("getPoolTokens", async () => {
        it('should return pool tokens struct', async () => {
            const { pool, grgToken } = await setupTests()
            let poolData = await pool.getPoolTokens()
            const decimals = await pool.decimals()
            const initialUnitaryValue = 1 * 10**decimals
            expect(poolData.unitaryValue).to.be.eq(initialUnitaryValue.toString())
            expect(poolData.totalSupply).to.be.eq(0)
            await grgToken.approve(pool.address, parseEther("20"))
            await pool.mint(user1.address, parseEther("10"), 0)
            poolData = await pool.getPoolTokens()
            expect(poolData.totalSupply).to.be.eq(parseEther("10"))
            // TODO: second mint will fail until EApps is correctly initialized
            await pool.mint(user2.address, parseEther("10"), 0)
            poolData = await pool.getPoolTokens()
            // 5% default spread results in less token than amount in at initial price 1
            expect(poolData.totalSupply).to.be.eq(parseEther("19.5"))
            await pool.setUnitaryValue()
            poolData = await pool.getPoolTokens()
            // TODO: check it is ok to charge spread on mint (instead could do on burn only)
            // and verify root of approximations, as 20 eth balance is divided by 19.5 tokens
            // which should result in a unitary value of 1.025641025641025641
            // the applied spread results in less minted tokens, hence price increases
            expect(poolData.unitaryValue).to.be.eq(parseEther("1.025641025641025641"))
        })
    })

    describe("getPoolStorage", async () => {
        it('should return pool init params', async () => {
            const { pool, grgToken } = await setupTests()
            const poolData = await pool.getPoolStorage()
            expect(poolData.poolInitParams.name).to.be.eq('testpool')
            expect(poolData.poolInitParams.symbol).to.be.eq('TEST')
            expect(poolData.poolInitParams.decimals).to.be.eq(18)
            expect(poolData.poolInitParams.owner).to.be.eq(user1.address)
            expect(poolData.poolInitParams.baseToken).to.be.eq(grgToken.address)
        })

        it('should return pool params', async () => {
            const { pool, grgToken } = await setupTests()
            const poolData = await pool.getPoolStorage()
            // 30 days default minimum period
            expect(poolData.poolVariables.minPeriod).to.be.eq(2592000)
            expect(poolData.poolVariables.spread).to.be.eq(500)
            expect(poolData.poolVariables.transactionFee).to.be.eq(0)
            expect(poolData.poolVariables.feeCollector).to.be.eq(user1.address)
            expect(poolData.poolVariables.kycProvider).to.be.eq(AddressZero)
        })

        it('should return pool tokens struct', async () => {
            // this test should always return 18 with any token but special tokens (i.e. 6 decimals tokens)
            const { pool, grgToken } = await setupTests()
            let poolData = await pool.getPoolStorage()
            expect(poolData.poolTokensInfo.unitaryValue).to.be.eq(parseEther("1"))
            expect(poolData.poolTokensInfo.totalSupply).to.be.eq(0)
            await grgToken.approve(pool.address, parseEther("10"))
            await pool.mint(user1.address, parseEther("10"), 0)
            // TODO: storage should be updated after mint, this is probably not necessary. However, this one
            // goes through nav calculations, while first mint simply stores initial value
            await pool.setUnitaryValue()
            poolData = await pool.getPoolStorage()
            expect(poolData.poolTokensInfo.unitaryValue).to.be.eq(parseEther("1"))
            expect(poolData.poolTokensInfo.totalSupply).to.be.eq(parseEther("10"))
            // TODO: should add test of second mint with another wallet?
            // default spread of 5% results in less token minted than amount in at initial price 1

        })
    })

    describe("getUserAccount", async () => {
        it('should return UserAccount struct', async () => {
            const { pool, grgToken } = await setupTests()
            let poolData = await pool.getUserAccount(user1.address)
            expect(poolData.userBalance).to.be.eq(0)
            expect(poolData.activation).to.be.eq(0)
            await grgToken.approve(pool.address, parseEther("10"))
            const tx = await pool.mint(user1.address, parseEther("10"), 0)
            const receipt = await tx.wait()
            const block = await receipt.events[0].getBlock()
            poolData = await pool.getUserAccount(user1.address)
            expect(poolData.activation).to.be.eq(block.timestamp + 30 * 24 * 60 * 60)
            // when user is only holder, spread is not applied
            expect(poolData.userBalance).to.be.eq(parseEther("10"))
        })
    })

    describe("mint", async () => {
        it('should create new tokens with input tokens', async () => {
            const { pool, grgToken } = await setupTests()
            expect(await pool.totalSupply()).to.be.eq(0)
            expect(await grgToken.balanceOf(pool.address)).to.be.eq(0)
            const dustAmount = parseEther("0.000999")
            expect(await pool.decimals()).to.be.eq(18)
            await expect(
                pool.mint(user1.address, dustAmount, 0)
            ).to.be.revertedWith('PoolAmountSmallerThanMinumum(1000)')
            const tokenAmountIn = parseEther("1")
            await expect(
                pool.mint(user1.address, tokenAmountIn, 0)
            ).to.be.revertedWith('PoolTransferFromFailed()')
            await grgToken.approve(pool.address, tokenAmountIn)
            expect(
                await grgToken.allowance(user1.address, pool.address)
            ).to.be.eq(tokenAmountIn)
            await expect(
                pool.mint(user1.address, tokenAmountIn, tokenAmountIn)
            ).to.be.revertedWith('PoolMintOutputAmount()')
            const userTokens = await pool.callStatic.mint(user1.address, tokenAmountIn, 0)
            await expect(
                pool.mint(user1.address, tokenAmountIn, 0)
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
            const poolData = await pool.getPoolParams()
            // TODO: only holder is not charged a spread, check if should assert with an additional holder
            //const spread = poolGrgBalance * poolData.spread / 10000 // spread
            //poolGrgBalance -= spread
            expect(userTokens.toString()).to.be.eq(poolGrgBalance.toString())
        })
    })

    describe("burn", async () => {
        it('should burn tokens with input tokens', async () => {
            const { pool, grgToken } = await setupTests()
            const tokenAmountIn = parseEther("1")
            await grgToken.approve(pool.address, tokenAmountIn)
            const userTokens = await pool.callStatic.mint(user1.address, tokenAmountIn, 0)
            expect((await pool.getPoolParams()).minPeriod).to.be.eq(2592000)
            await pool.mint(user1.address, tokenAmountIn, 0)
            expect(await pool.totalSupply()).to.be.not.eq(0)
            expect(await pool.balanceOf(user1.address)).to.be.eq(userTokens)
            await expect(
                pool.burn(0, 0)
            ).to.be.revertedWith('PoolBurnNullAmount()')
            let userPoolBalance = await pool.balanceOf(user1.address)
            // initial price is 1, so user balance is same as tokenAmountIn as long as no spread is applied
            expect(userPoolBalance).to.be.eq(tokenAmountIn)
            await expect(
                pool.burn(BigNumber.from(tokenAmountIn).add(1), 0)
            ).to.be.revertedWith('PoolBurnNotEnough()')
            await expect(
                pool.burn(userPoolBalance, 0)
            ).to.be.revertedWith('PoolMinimumPeriodNotEnough()')
            // previous assertions result in 1 second time travel per assertion
            await timeTravel({ seconds: 2592000 - 4, mine: false })
            await expect(
                pool.burn(tokenAmountIn, BigNumber.from(tokenAmountIn).add(1))
            ).to.be.revertedWith('PoolMinimumPeriodNotEnough()')
            await timeTravel({ seconds: 1, mine: false })
            await expect(
                pool.burn(tokenAmountIn, BigNumber.from(tokenAmountIn).add(1))
            ).to.be.revertedWith('PoolBurnOutputAmount()')

            // when spread is applied, also requesting tokenAmountIn as minimum will revert
            await expect(
                pool.burn(tokenAmountIn, BigNumber.from(tokenAmountIn).add(1))
            ).to.be.revertedWith('PoolBurnOutputAmount()')

            // TODO: now can always burn as pool value is calculate automatically. Only way to simulate
            // would be to move tokens via an adapter.
            //await expect(
            //    pool.burn(userPoolBalance, 0)
            //).to.be.revertedWith('PoolTransferFailed()')
            //await expect(
            //    pool.burn(userPoolBalance, userPoolBalance)
            //).to.be.revertedWith('PoolBurnOutputAmount()')
            const netRevenue = await pool.callStatic.burn(userPoolBalance, 0)
            // the following is true with fee set as 0
            await expect(
                pool.burn(userPoolBalance, 1)
            ).to.emit(grgToken, "Transfer").withArgs(
                pool.address,
                user1.address,
                netRevenue
            )
            const poolTotalSupply = await pool.totalSupply()
            expect(poolTotalSupply).to.be.eq(0)
            expect(await pool.balanceOf(user1.address)).to.be.eq(0)
            // TODO: mint with another wallet as well, so we can simulate with positive spread
            // and increased unitary value. Be careful as we also want to assert base case where spread is nil
            // as long as price is 1, tokenAmountIn should be equal to netRevenue
            expect(Number(tokenAmountIn)).to.be.eq(Number(netRevenue))
            const tokenDelta = Number(tokenAmountIn) - netRevenue
            const poolGrgBalance = await grgToken.balanceOf(pool.address)
            expect(poolGrgBalance).to.be.eq(tokenDelta.toString())
            // if fee != 0 and caller not fee recipient, supply will not be 0
            let poolData = await pool.getPoolParams()
            // TODO: we could return a 0 spread if only holder, but if the transaction were frontrun, it would fail (which could be ok)
            const spread = poolData.spread
            const markup = userPoolBalance === poolTotalSupply ? userPoolBalance.mul(spread).div(10000) : 0
            // TODO: also assert with positive spread
            userPoolBalance -= markup
            poolData = await pool.getPoolTokens()
            const unitaryValue = poolData.unitaryValue
            const decimals = await pool.decimals()
            // we need to multiply by fraction as ts overflows otherwise
            const revenue = unitaryValue / (10**decimals) * userPoolBalance
            expect(userPoolBalance - revenue).to.be.eq(0)
            expect(Number(netRevenue)).to.be.deep.eq(revenue)
        })
    })

    describe("burn", async () => {
        it('should burn tokens with 6-decimal base token', async () => {
            const { pool, factory } = await setupTests()
            const source = `
            contract USDC {
                uint256 public totalSupply = 1e16;
                uint8 public decimals = 6;
                mapping(address => uint256) balances;
                function init() public { balances[msg.sender] = totalSupply; }
                function transfer(address to,uint amount) public { transferFrom(msg.sender,to,amount); }
                function transferFrom(address from,address to,uint256 amount) public {
                    balances[to] += amount; balances[from] -= amount;
                }
                function balanceOf(address _who) external view returns (uint256) {
                    return balances[_who];
                }
            }`
            const usdc = await deployContract(user1, source)
            await usdc.init()
            const newPool = await factory.callStatic.createPool('USDC pool','USDP',usdc.address)
            await factory.createPool('USDC pool','USDP',usdc.address)
            const poolUsdc = pool.attach(newPool.newPoolAddress)
            expect(await poolUsdc.decimals()).to.be.eq(6)
            await usdc.transfer(user2.address, 2000000)
            // TODO: use a different amount than unit to make sure it is not a coincidence
            // TODO: mint, then transfer, then mint again with higher price, ...
            await poolUsdc.connect(user2).mint(user2.address, 100000, 1)
            // second mint will prompt storing unitary value in storage, which was empty before
            await expect(
                poolUsdc.connect(user2).mint(user2.address, 100000, 0)
            )
                .to.emit(poolUsdc, "Transfer") //.withArgs(AddressZero, user2.address, 3800)
                .and.to.emit(poolUsdc, "NewNav").withArgs(
                    user2.address,
                    poolUsdc.address, 
                    10**6 // this is true as long as pool as initial price 1
                )
            await expect(
                poolUsdc.connect(user2).mint(user2.address, 999, 0)
            ).to.be.revertedWith('PoolAmountSmallerThanMinumum(1000)')
            // TODO: try burn, then set value again
            /*await poolUsdc.setUnitaryValue()
            await poolUsdc.setUnitaryValue()
            await poolUsdc.setUnitaryValue()
            await poolUsdc.setUnitaryValue()
            await poolUsdc.setUnitaryValue()
            await poolUsdc.setUnitaryValue()
            await poolUsdc.setUnitaryValue()
            // the following line undeflows minimum liquidity (99.96% loss with small decimals), which is ok
            poolUsdc.setUnitaryValue(401)
            // passes locally with 1 second time travel, fails in CI
            // TODO: verify setting minimum period to 2 will set to 10?
            await timeTravel({ seconds: 2592000, mine: true })
            const burnAmount = 6000
            await expect(
                poolUsdc.connect(user2).burn(burnAmount, 1)
            ).to.emit(poolUsdc, "Transfer").withArgs(user2.address, AddressZero, burnAmount)*/
        })
    })

    describe("initializePool", async () => {
        it('should revert when already initialized', async () => {
            const { pool, grgToken } = await setupTests()
            let symbol = utils.formatBytes32String("TEST")
            symbol = utils.hexDataSlice(symbol, 0, 8)
            await expect(pool.initializePool())
                .to.be.revertedWith('PoolAlreadyInitialized()')
        })
    })
})
