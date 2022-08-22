import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber, Contract } from "ethers";
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
            const { pool, grgToken } = await setupTests()
            expect(await pool.totalSupply()).to.be.eq(0)
            expect(await grgToken.balanceOf(pool.address)).to.be.eq(0)
            const dustAmount = parseEther("0.000999")
            expect(await pool.decimals()).to.be.eq(18)
            await expect(
                pool.mint(user1.address, dustAmount)
            ).to.be.revertedWith("POOL_AMOUNT_SMALLER_THAN_MINIMUM_ERROR")
            const tokenAmountIn = parseEther("1")
            await expect(
                pool.mint(user1.address, tokenAmountIn)
            ).to.be.revertedWith("POOL_TRANSFER_FROM_FAILED_ERROR")
            await grgToken.approve(pool.address, tokenAmountIn)
            expect(
                await grgToken.allowance(user1.address, pool.address)
            ).to.be.eq(tokenAmountIn)
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
            expect((await pool.getAdminData()).minPeriod).to.be.eq(2)
            await pool.mint(user1.address, tokenAmountIn)
            expect(await pool.totalSupply()).to.be.not.eq(0)
            expect(await pool.balanceOf(user1.address)).to.be.eq(userTokens)
            const biggerthanBalance = parseEther("1.1")
            let userPoolBalance = await pool.balanceOf(user1.address)
            await expect(
                pool.burn(userPoolBalance)
            ).to.be.revertedWith("POOL_MINIMUM_PERIOD_NOT_ENOUGH_ERROR")
            // following condition is true with spread > 0
            // TODO: check why this test fails when placed before previous one
            await expect(
                pool.burn(tokenAmountIn)
            ).to.be.revertedWith("POOL_BURN_NOT_ENOUGH_ERROR")
            await expect(
                pool.burn(0)
            ).to.be.revertedWith("POOL_BURN_NULL_AMOUNT_ERROR")
            // we do not mine as want to check transaction does not happen in same block
            await timeTravel({ seconds: 1, mine: true })
            const bytes32hash = hre.ethers.utils.formatBytes32String('notused')
            const AuthorityCoreInstance = await deployments.get("AuthorityCore")
            const AuthorityCore = await hre.ethers.getContractFactory("AuthorityCore")
            const authority = AuthorityCore.attach(AuthorityCoreInstance.address)
            const NavVerifierInstance = await deployments.get("NavVerifier")
            //"9e4e93d0": "isValidNav(uint256,uint256,bytes32,bytes)"
            await authority.addMethod("0x9e4e93d0", NavVerifierInstance.address)
            // will not be able to send more owned tokens than pool balance
            await pool.setUnitaryValue(parseEther("2"), 0, bytes32hash, bytes32hash)
            await expect(
                pool.burn(userPoolBalance)
            ).to.be.revertedWith("POOL_TRANSFER_FAILED_ERROR")
            await pool.setUnitaryValue(parseEther("1"), 0, bytes32hash, bytes32hash)
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
            const spread = poolData.spread
            const markup = userPoolBalance.mul(spread).div(10000)
            userPoolBalance -= markup
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
            }`
            const tokenAmountIn = parseEther("1")
            const usdc = await deployContract(user1, source)
            await usdc.init()
            const newPool = await factory.callStatic.createPool('USDC pool','USDP',usdc.address)
            await factory.createPool('USDC pool','USDP',usdc.address)
            const poolUsdc = pool.attach(newPool.newPoolAddress)
            expect(await poolUsdc.decimals()).to.be.eq(6)
            await usdc.transfer(user2.address, 2000000)
            await poolUsdc.connect(user2).mint(user2.address, 100000)
            const AuthorityCoreInstance = await deployments.get("AuthorityCore")
            const AuthorityCore = await hre.ethers.getContractFactory("AuthorityCore")
            const authority = AuthorityCore.attach(AuthorityCoreInstance.address)
            const NavVerifierInstance = await deployments.get("NavVerifier")
            const NavVerifier = await hre.ethers.getContractFactory("NavVerifier")
            const navVerifier = NavVerifier.attach(NavVerifierInstance.address)
            //"9e4e93d0": "isValidNav(uint256,uint256,bytes32,bytes)"
            await authority.addMethod("0x9e4e93d0", navVerifier.address)
            const bytes32hash = hre.ethers.utils.formatBytes32String('notused')
            await poolUsdc.setUnitaryValue(4999999, 1, bytes32hash, bytes32hash)
            await poolUsdc.setUnitaryValue(24999990, 1, bytes32hash, bytes32hash)
            await poolUsdc.setUnitaryValue(124999900, 1, bytes32hash, bytes32hash)
            await expect(
                poolUsdc.connect(user2).mint(user2.address, 100000)
            ).be.emit(poolUsdc, "Transfer").withArgs(AddressZero, user2.address, 760)
            await expect(
                poolUsdc.connect(user2).mint(user2.address, 999)
            ).to.be.revertedWith("POOL_AMOUNT_SMALLER_THAN_MINIMUM_ERROR")
            await poolUsdc.setUnitaryValue(25000001, 1, bytes32hash, bytes32hash)
            await poolUsdc.setUnitaryValue(5000001, 1, bytes32hash, bytes32hash)
            await poolUsdc.setUnitaryValue(1000001, 1, bytes32hash, bytes32hash)
            await poolUsdc.setUnitaryValue(200001, 1, bytes32hash, bytes32hash)
            await poolUsdc.setUnitaryValue(50001, 1, bytes32hash, bytes32hash)
            await poolUsdc.setUnitaryValue(10001, 1, bytes32hash, bytes32hash)
            await poolUsdc.setUnitaryValue(2001, 1, bytes32hash, bytes32hash)
            await poolUsdc.setUnitaryValue(401, 1, bytes32hash, bytes32hash)
            await timeTravel({ seconds: 1, mine: true })
            const burnAmount = 6000
            // TODO: check if burning underflows netRevenue
            await expect(
                poolUsdc.connect(user2).burn(burnAmount)
            ).to.emit(poolUsdc, "Transfer").withArgs(user2.address, AddressZero, burnAmount)
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
