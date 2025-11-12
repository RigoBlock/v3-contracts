import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber } from "ethers";
import { timeTravel } from "../utils/utils";

describe("MintWithToken", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()
    const MAX_TICK_SPACING = 32767

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const AuthorityInstance = await deployments.get("Authority")
        const Authority = await hre.ethers.getContractFactory("Authority")
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        const factory = Factory.attach(RigoblockPoolProxyFactory.address)
        const RigoTokenInstance = await deployments.get("RigoToken")
        const RigoToken = await hre.ethers.getContractFactory("RigoToken")
        const grgToken = RigoToken.attach(RigoTokenInstance.address)
        const { newPoolAddress } = await factory.callStatic.createPool(
            'testpool',
            'TEST',
            grgToken.address
        )
        await factory.createPool('testpool','TEST',grgToken.address)
        const pool = await hre.ethers.getContractAt(
            "SmartPool",
            newPoolAddress
        )
        const HookInstance = await deployments.get("MockOracle")
        const Hook = await hre.ethers.getContractFactory("MockOracle")
        const oracle = Hook.attach(HookInstance.address)
        const authority = Authority.attach(AuthorityInstance.address)
        const Weth = await hre.ethers.getContractFactory("WETH9")
        const WethInstance = await deployments.get("WETH9")
        const weth = Weth.attach(WethInstance.address)
        const DeflationInstance = await deployments.get("Deflation")
        const Deflation = await hre.ethers.getContractFactory("Deflation")
        const deflation = Deflation.attach(DeflationInstance.address)

        return {
            authority,
            factory,
            pool,
            oracle,
            grgToken,
            weth,
            deflation
        }
    })

    describe("mintWithToken", async () => {
        it('should revert if token not active', async () => {
            const { pool, weth, grgToken } = await setupTests()
            const tokenAmount = parseEther("10")
            await grgToken.approve(pool.address, tokenAmount)
            
            // weth is not in the active tokens set
            await expect(
                pool.mintWithToken(user1.address, tokenAmount, 0, weth.address)
            ).to.be.revertedWith('PoolTokenNotActive()')
        })

        it('should mint with GRG token when pool base token is GRG', async () => {
            const { pool, oracle, grgToken, deflation } = await setupTests()
            const poolKey = { 
                currency0: AddressZero, 
                currency1: grgToken.address, 
                fee: 0, 
                tickSpacing: MAX_TICK_SPACING, 
                hooks: oracle.address 
            }
            await oracle.initializeObservations(poolKey)
            
            const tokenAmount = parseEther("100")
            await grgToken.approve(pool.address, tokenAmount)
            
            const { spread } = await pool.getPoolParams()
            const spreadAmount = tokenAmount.mul(spread).div(10000)
            const deflationBalanceBefore = await grgToken.balanceOf(deflation.address)
            
            await expect(
                pool.mintWithToken(user1.address, tokenAmount, 0, grgToken.address)
            ).to.emit(pool, "Transfer").withArgs(
                AddressZero,
                user1.address,
                tokenAmount.sub(spreadAmount)
            )
            
            const deflationBalanceAfter = await grgToken.balanceOf(deflation.address)
            expect(deflationBalanceAfter.sub(deflationBalanceBefore)).to.be.eq(spreadAmount)
            expect(await pool.balanceOf(user1.address)).to.be.eq(tokenAmount.sub(spreadAmount))
        })

        it('should mint with alternative ERC20 token', async () => {
            const { pool, oracle, grgToken, weth } = await setupTests()
            
            // Initialize price feeds for both tokens
            const grgPoolKey = { 
                currency0: AddressZero, 
                currency1: grgToken.address, 
                fee: 0, 
                tickSpacing: MAX_TICK_SPACING, 
                hooks: oracle.address 
            }
            await oracle.initializeObservations(grgPoolKey)
            
            const wethPoolKey = { 
                currency0: AddressZero, 
                currency1: weth.address, 
                fee: 0, 
                tickSpacing: MAX_TICK_SPACING, 
                hooks: oracle.address 
            }
            await oracle.initializeObservations(wethPoolKey)
            
            // Add weth to active tokens by minting some weth to the pool
            await weth.deposit({ value: parseEther("1") })
            await weth.transfer(pool.address, parseEther("0.1"))
            
            const wethAmount = parseEther("10")
            await weth.deposit({ value: wethAmount })
            await weth.approve(pool.address, wethAmount)
            
            const userBalanceBefore = await pool.balanceOf(user1.address)
            
            await pool.mintWithToken(user1.address, wethAmount, 0, weth.address)
            
            const userBalanceAfter = await pool.balanceOf(user1.address)
            expect(userBalanceAfter).to.be.gt(userBalanceBefore)
        })

        it('should apply spread and transfer to deflation contract', async () => {
            const { pool, oracle, grgToken, deflation } = await setupTests()
            const poolKey = { 
                currency0: AddressZero, 
                currency1: grgToken.address, 
                fee: 0, 
                tickSpacing: MAX_TICK_SPACING, 
                hooks: oracle.address 
            }
            await oracle.initializeObservations(poolKey)
            
            const tokenAmount = parseEther("100")
            await grgToken.approve(pool.address, tokenAmount)
            
            const { spread } = await pool.getPoolParams()
            const expectedSpread = tokenAmount.mul(spread).div(10000)
            
            const deflationBalanceBefore = await grgToken.balanceOf(deflation.address)
            
            await pool.mintWithToken(user1.address, tokenAmount, 0, grgToken.address)
            
            const deflationBalanceAfter = await grgToken.balanceOf(deflation.address)
            expect(deflationBalanceAfter.sub(deflationBalanceBefore)).to.be.eq(expectedSpread)
        })

        it('should respect minimum output amount', async () => {
            const { pool, oracle, grgToken } = await setupTests()
            const poolKey = { 
                currency0: AddressZero, 
                currency1: grgToken.address, 
                fee: 0, 
                tickSpacing: MAX_TICK_SPACING, 
                hooks: oracle.address 
            }
            await oracle.initializeObservations(poolKey)
            
            const tokenAmount = parseEther("100")
            await grgToken.approve(pool.address, tokenAmount)
            
            const { spread } = await pool.getPoolParams()
            const expectedMint = tokenAmount.sub(tokenAmount.mul(spread).div(10000))
            
            // Request more than will be minted
            await expect(
                pool.mintWithToken(user1.address, tokenAmount, expectedMint.add(1), grgToken.address)
            ).to.be.revertedWith('PoolMintOutputAmount()')
        })

        it('should work with operator', async () => {
            const { pool, oracle, grgToken } = await setupTests()
            const poolKey = { 
                currency0: AddressZero, 
                currency1: grgToken.address, 
                fee: 0, 
                tickSpacing: MAX_TICK_SPACING, 
                hooks: oracle.address 
            }
            await oracle.initializeObservations(poolKey)
            
            await grgToken.transfer(user2.address, parseEther("100"))
            
            const tokenAmount = parseEther("50")
            await grgToken.connect(user2).approve(pool.address, tokenAmount)
            
            // Should fail without operator approval
            await expect(
                pool.mintWithToken(user2.address, tokenAmount, 0, grgToken.address)
            ).to.be.revertedWith('InvalidOperator()')
            
            // Set operator
            await pool.connect(user2).setOperator(user1.address, true)
            
            // Should work now
            await expect(
                pool.mintWithToken(user2.address, tokenAmount, 0, grgToken.address)
            ).to.not.be.reverted
            
            expect(await pool.balanceOf(user2.address)).to.be.gt(0)
        })

        it('should enforce KYC if provider is set', async () => {
            const { pool, factory, oracle, grgToken } = await setupTests()
            
            // Set a KYC provider (any non-zero address will enforce the check)
            await pool.setKycProvider(user2.address)
            
            const poolKey = { 
                currency0: AddressZero, 
                currency1: grgToken.address, 
                fee: 0, 
                tickSpacing: MAX_TICK_SPACING, 
                hooks: oracle.address 
            }
            await oracle.initializeObservations(poolKey)
            
            const tokenAmount = parseEther("10")
            await grgToken.approve(pool.address, tokenAmount)
            
            // Should fail because user1 is not whitelisted
            await expect(
                pool.mintWithToken(user1.address, tokenAmount, 0, grgToken.address)
            ).to.be.revertedWith('PoolCallerNotWhitelisted()')
        })

        it('should enforce minimum amount', async () => {
            const { pool, oracle, grgToken } = await setupTests()
            const poolKey = { 
                currency0: AddressZero, 
                currency1: grgToken.address, 
                fee: 0, 
                tickSpacing: MAX_TICK_SPACING, 
                hooks: oracle.address 
            }
            await oracle.initializeObservations(poolKey)
            
            const decimals = await pool.decimals()
            const minimumAmount = BigNumber.from(10).pow(decimals).div(100000)
            
            await grgToken.approve(pool.address, minimumAmount.sub(1))
            
            await expect(
                pool.mintWithToken(user1.address, minimumAmount.sub(1), 0, grgToken.address)
            ).to.be.revertedWith('PoolAmountSmallerThanMinumum')
        })
    })
})
