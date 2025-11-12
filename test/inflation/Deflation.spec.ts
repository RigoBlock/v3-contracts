import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber } from "ethers";
import { timeTravel } from "../utils/utils";

describe("Deflation", async () => {
    const [ user1, user2, user3 ] = waffle.provider.getWallets()
    const MAX_TICK_SPACING = 32767
    const ETH_TOKEN_ADDRESS = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE"

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const RigoTokenInstance = await deployments.get("RigoToken")
        const RigoToken = await hre.ethers.getContractFactory("RigoToken")
        const grgToken = RigoToken.attach(RigoTokenInstance.address)
        
        const DeflationInstance = await deployments.get("Deflation")
        const Deflation = await hre.ethers.getContractFactory("Deflation")
        const deflation = Deflation.attach(DeflationInstance.address)
        
        const HookInstance = await deployments.get("MockOracle")
        const Hook = await hre.ethers.getContractFactory("MockOracle")
        const oracle = Hook.attach(HookInstance.address)
        
        const Weth = await hre.ethers.getContractFactory("WETH9")
        const WethInstance = await deployments.get("WETH9")
        const weth = Weth.attach(WethInstance.address)
        
        return {
            deflation,
            grgToken,
            oracle,
            weth
        }
    })

    describe("constructor", async () => {
        it('should have correct immutable values', async () => {
            const { deflation, grgToken, oracle } = await setupTests()
            expect(await deflation.GRG()).to.be.eq(grgToken.address)
            expect(await deflation.oracle()).to.be.eq(oracle.address)
        })

        it('should have correct constants', async () => {
            const { deflation } = await setupTests()
            expect(await deflation.MAX_DISCOUNT()).to.be.eq(8000) // 80%
            expect(await deflation.AUCTION_DURATION()).to.be.eq(14 * 24 * 60 * 60) // 2 weeks
            expect(await deflation.BASIS_POINTS()).to.be.eq(10000)
        })
    })

    describe("receive", async () => {
        it('should receive ETH', async () => {
            const { deflation } = await setupTests()
            const ethAmount = parseEther("1")
            
            await expect(
                user1.sendTransaction({ to: deflation.address, value: ethAmount })
            ).to.not.be.reverted
            
            expect(await hre.ethers.provider.getBalance(deflation.address)).to.be.eq(ethAmount)
        })
    })

    describe("getCurrentDiscount", async () => {
        it('should return 0 discount initially', async () => {
            const { deflation, weth } = await setupTests()
            expect(await deflation.getCurrentDiscount(weth.address)).to.be.eq(0)
        })

        it('should return max discount after auction duration', async () => {
            const { deflation, weth } = await setupTests()
            
            // Set lastPurchaseTime by making a purchase
            const { grgToken } = await setupTests()
            await weth.deposit({ value: parseEther("1") })
            await weth.transfer(deflation.address, parseEther("1"))
            await grgToken.approve(deflation.address, parseEther("1000"))
            
            const poolKey = { 
                currency0: AddressZero, 
                currency1: weth.address, 
                fee: 0, 
                tickSpacing: MAX_TICK_SPACING, 
                hooks: oracle.address 
            }
            await oracle.initializeObservations(poolKey)
            
            // Make initial purchase to set timestamp
            await deflation.buyToken(weth.address, parseEther("0.1"))
            
            // Travel 2 weeks
            await timeTravel({ days: 14, mine: true })
            
            const discount = await deflation.getCurrentDiscount(weth.address)
            expect(discount).to.be.eq(8000) // MAX_DISCOUNT
        })

        it('should return proportional discount during auction', async () => {
            const { deflation, weth, oracle } = await setupTests()
            
            const poolKey = { 
                currency0: AddressZero, 
                currency1: weth.address, 
                fee: 0, 
                tickSpacing: MAX_TICK_SPACING, 
                hooks: oracle.address 
            }
            await oracle.initializeObservations(poolKey)
            
            await weth.deposit({ value: parseEther("1") })
            await weth.transfer(deflation.address, parseEther("1"))
            
            // Make initial purchase
            await deflation.buyToken(weth.address, parseEther("0.1"))
            
            // Travel 7 days (half of auction duration)
            await timeTravel({ days: 7, mine: true })
            
            const discount = await deflation.getCurrentDiscount(weth.address)
            // Should be approximately 50% of max discount
            expect(discount).to.be.closeTo(4000, 100)
        })

        it('should cap discount at BASIS_POINTS', async () => {
            const { deflation, weth } = await setupTests()
            
            // Even if we travel way beyond auction duration
            await timeTravel({ days: 100, mine: true })
            
            const discount = await deflation.getCurrentDiscount(weth.address)
            expect(discount).to.be.lte(10000) // BASIS_POINTS
        })
    })

    describe("buyToken", async () => {
        it('should revert with zero amount', async () => {
            const { deflation, weth } = await setupTests()
            
            await expect(
                deflation.buyToken(weth.address, 0)
            ).to.be.revertedWith("Amount must be greater than 0")
        })

        it('should revert with zero token address', async () => {
            const { deflation } = await setupTests()
            
            await expect(
                deflation.buyToken(AddressZero, parseEther("1"))
            ).to.be.revertedWith("Invalid token address")
        })

        it('should revert if oracle returns non-positive amount', async () => {
            const { deflation, weth, oracle, grgToken } = await setupTests()
            
            // Don't initialize observations, so oracle will return 0
            await weth.deposit({ value: parseEther("1") })
            await weth.transfer(deflation.address, parseEther("1"))
            
            await expect(
                deflation.buyToken(weth.address, parseEther("0.1"))
            ).to.be.revertedWith("InvalidConvertedAmount()")
        })

        it('should purchase ERC20 tokens with GRG', async () => {
            const { deflation, weth, oracle, grgToken } = await setupTests()
            
            const poolKey = { 
                currency0: AddressZero, 
                currency1: weth.address, 
                fee: 0, 
                tickSpacing: MAX_TICK_SPACING, 
                hooks: oracle.address 
            }
            await oracle.initializeObservations(poolKey)
            
            const wethAmount = parseEther("1")
            await weth.deposit({ value: wethAmount })
            await weth.transfer(deflation.address, wethAmount)
            
            const grgBalanceBefore = await grgToken.balanceOf(user1.address)
            const wethBalanceBefore = await weth.balanceOf(user1.address)
            
            const amountOut = parseEther("0.5")
            const amountIn = await deflation.callStatic.buyToken(weth.address, amountOut)
            
            await expect(
                deflation.buyToken(weth.address, amountOut)
            ).to.emit(deflation, "TokenPurchased")
            
            const grgBalanceAfter = await grgToken.balanceOf(user1.address)
            const wethBalanceAfter = await weth.balanceOf(user1.address)
            
            expect(grgBalanceAfter).to.be.lt(grgBalanceBefore) // GRG spent
            expect(wethBalanceAfter).to.be.eq(wethBalanceBefore.add(amountOut)) // WETH received
        })

        it('should purchase ETH with GRG', async () => {
            const { deflation, oracle, grgToken } = await setupTests()
            
            // Send ETH to deflation contract
            const ethAmount = parseEther("2")
            await user1.sendTransaction({ to: deflation.address, value: ethAmount })
            
            const grgBalanceBefore = await grgToken.balanceOf(user1.address)
            const ethBalanceBefore = await user1.getBalance()
            
            const amountOut = parseEther("1")
            const amountIn = await deflation.callStatic.buyToken(ETH_TOKEN_ADDRESS, amountOut)
            
            const tx = await deflation.buyToken(ETH_TOKEN_ADDRESS, amountOut)
            const receipt = await tx.wait()
            const gasUsed = receipt.gasUsed.mul(receipt.effectiveGasPrice)
            
            const grgBalanceAfter = await grgToken.balanceOf(user1.address)
            const ethBalanceAfter = await user1.getBalance()
            
            expect(grgBalanceAfter).to.be.lt(grgBalanceBefore) // GRG spent
            expect(ethBalanceAfter).to.be.closeTo(
                ethBalanceBefore.add(amountOut).sub(gasUsed),
                parseEther("0.001") // Allow for small gas estimation errors
            )
        })

        it('should apply discount correctly', async () => {
            const { deflation, weth, oracle, grgToken } = await setupTests()
            
            const poolKey = { 
                currency0: AddressZero, 
                currency1: weth.address, 
                fee: 0, 
                tickSpacing: MAX_TICK_SPACING, 
                hooks: oracle.address 
            }
            await oracle.initializeObservations(poolKey)
            
            const wethAmount = parseEther("10")
            await weth.deposit({ value: wethAmount })
            await weth.transfer(deflation.address, wethAmount)
            
            // First purchase with no discount
            const amountOut1 = parseEther("1")
            const amountIn1 = await deflation.callStatic.buyToken(weth.address, amountOut1)
            await deflation.buyToken(weth.address, amountOut1)
            
            // Travel 1 week for partial discount
            await timeTravel({ days: 7, mine: true })
            
            const amountIn2 = await deflation.callStatic.buyToken(weth.address, amountOut1)
            
            // Second purchase should cost less due to discount
            expect(amountIn2).to.be.lt(amountIn1)
            
            // Travel another week for max discount
            await timeTravel({ days: 7, mine: true })
            
            const amountIn3 = await deflation.callStatic.buyToken(weth.address, amountOut1)
            
            // Third purchase should cost even less
            expect(amountIn3).to.be.lt(amountIn2)
            
            // Max discount should be 80%, so min cost should be 20% of original
            expect(amountIn3).to.be.closeTo(amountIn1.mul(20).div(100), amountIn1.mul(5).div(100))
        })

        it('should update lastPurchaseTime', async () => {
            const { deflation, weth, oracle } = await setupTests()
            
            const poolKey = { 
                currency0: AddressZero, 
                currency1: weth.address, 
                fee: 0, 
                tickSpacing: MAX_TICK_SPACING, 
                hooks: oracle.address 
            }
            await oracle.initializeObservations(poolKey)
            
            await weth.deposit({ value: parseEther("1") })
            await weth.transfer(deflation.address, parseEther("1"))
            
            expect(await deflation.lastPurchaseTime(weth.address)).to.be.eq(0)
            
            await deflation.buyToken(weth.address, parseEther("0.1"))
            
            const lastPurchaseTime = await deflation.lastPurchaseTime(weth.address)
            expect(lastPurchaseTime).to.be.gt(0)
            
            const block = await hre.ethers.provider.getBlock('latest')
            expect(lastPurchaseTime).to.be.eq(block.timestamp)
        })

        it('should reset discount after purchase', async () => {
            const { deflation, weth, oracle } = await setupTests()
            
            const poolKey = { 
                currency0: AddressZero, 
                currency1: weth.address, 
                fee: 0, 
                tickSpacing: MAX_TICK_SPACING, 
                hooks: oracle.address 
            }
            await oracle.initializeObservations(poolKey)
            
            await weth.deposit({ value: parseEther("10") })
            await weth.transfer(deflation.address, parseEther("10"))
            
            // Make first purchase
            await deflation.buyToken(weth.address, parseEther("0.1"))
            
            // Travel time to build up discount
            await timeTravel({ days: 7, mine: true })
            
            const discountBefore = await deflation.getCurrentDiscount(weth.address)
            expect(discountBefore).to.be.gt(0)
            
            // Make another purchase
            await deflation.buyToken(weth.address, parseEther("0.1"))
            
            // Discount should be reset to 0
            const discountAfter = await deflation.getCurrentDiscount(weth.address)
            expect(discountAfter).to.be.eq(0)
        })

        it('should emit TokenPurchased event', async () => {
            const { deflation, weth, oracle } = await setupTests()
            
            const poolKey = { 
                currency0: AddressZero, 
                currency1: weth.address, 
                fee: 0, 
                tickSpacing: MAX_TICK_SPACING, 
                hooks: oracle.address 
            }
            await oracle.initializeObservations(poolKey)
            
            await weth.deposit({ value: parseEther("1") })
            await weth.transfer(deflation.address, parseEther("1"))
            
            const amountOut = parseEther("0.5")
            const discount = await deflation.getCurrentDiscount(weth.address)
            
            await expect(
                deflation.buyToken(weth.address, amountOut)
            ).to.emit(deflation, "TokenPurchased").withArgs(
                user1.address,
                weth.address,
                amountOut,
                // amountIn is calculated in the contract
                await deflation.callStatic.buyToken(weth.address, amountOut),
                discount
            )
        })

        it('should handle multiple different tokens independently', async () => {
            const { deflation, weth, oracle, grgToken } = await setupTests()
            
            const wethPoolKey = { 
                currency0: AddressZero, 
                currency1: weth.address, 
                fee: 0, 
                tickSpacing: MAX_TICK_SPACING, 
                hooks: oracle.address 
            }
            await oracle.initializeObservations(wethPoolKey)
            
            const grgPoolKey = { 
                currency0: AddressZero, 
                currency1: grgToken.address, 
                fee: 0, 
                tickSpacing: MAX_TICK_SPACING, 
                hooks: oracle.address 
            }
            await oracle.initializeObservations(grgPoolKey)
            
            // Fund deflation with both tokens
            await weth.deposit({ value: parseEther("10") })
            await weth.transfer(deflation.address, parseEther("10"))
            await grgToken.transfer(deflation.address, parseEther("100"))
            
            // Buy WETH
            await deflation.buyToken(weth.address, parseEther("1"))
            
            // Travel time
            await timeTravel({ days: 7, mine: true })
            
            // WETH should have discount, but GRG should not
            const wethDiscount = await deflation.getCurrentDiscount(weth.address)
            const grgDiscount = await deflation.getCurrentDiscount(grgToken.address)
            
            expect(wethDiscount).to.be.gt(0)
            expect(grgDiscount).to.be.eq(0)
        })

        it('should revert if calculated GRG amount is 0', async () => {
            const { deflation, weth, oracle } = await setupTests()
            
            const poolKey = { 
                currency0: AddressZero, 
                currency1: weth.address, 
                fee: 0, 
                tickSpacing: MAX_TICK_SPACING, 
                hooks: oracle.address 
            }
            await oracle.initializeObservations(poolKey)
            
            await weth.deposit({ value: parseEther("1") })
            await weth.transfer(deflation.address, parseEther("1"))
            
            // Try to buy a very small amount that would result in 0 GRG after discount
            await expect(
                deflation.buyToken(weth.address, 1)
            ).to.be.revertedWith("GrgAmountIsNull()")
        })
    })
})
