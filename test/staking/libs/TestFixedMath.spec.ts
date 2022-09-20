import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber, Contract } from "ethers";

describe("TestFixedMath", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async () => {
        const TestFixedMath = await hre.ethers.getContractFactory("TestLibFixedMath")
        const testFixedMath = await TestFixedMath.deploy()
        return {
            testFixedMath
        }
    })

    describe("mul", async () => {
        it('should overflow with error', async () => {
            const { testFixedMath } = await setupTests()
            const overflowAmount = BigNumber.from('2').pow(200)
            await expect(testFixedMath.mul(overflowAmount, overflowAmount))
                .to.be.revertedWith("MULTIPLICATION_OVERFLOW_ERROR")
        })
    })

    describe("div", async () => {
        it('should revert if dividing by 0', async () => {
            const { testFixedMath } = await setupTests()
            const amount = BigNumber.from('2').pow(20)
            await expect(testFixedMath.div(amount, 0))
                .to.be.revertedWith("DIVISION_BY_ZERO_ERROR")
        })

        it('should overflow with error', async () => {
            const { testFixedMath } = await setupTests()
            const minFidedValue = BigNumber.from('2').pow(255).mul(-1)
            await expect(testFixedMath.div(minFidedValue, -1))
                // won't overflow division as will overflow mul op first
                //.to.be.revertedWith("DIVISION_OVERFLOW_ERROR")
                .to.be.revertedWith("MULTIPLICATION_OVERFLOW_ERROR")
        })
    })

    describe("muldiv", async () => {
        it('should overflow with error', async () => {
            const { testFixedMath } = await setupTests()
            const minFidedValue = BigNumber.from('2').pow(255).mul(-1).div(2)
            await expect(testFixedMath.mulDiv(minFidedValue, 2, -1))
                .to.be.revertedWith("DIVISION_OVERFLOW_ERROR")
        })
    })

    describe("ln", async () => {
        it('should overflow with error', async () => {
            const { testFixedMath } = await setupTests()
            await expect(testFixedMath.ln(-50)).to.be.revertedWith("X_TOO_SMALL_ERROR")
        })

        it('should revert with min exp value', async () => {
            const { testFixedMath } = await setupTests()
            // TODO: must revert with min ln value
            const minExpValue = BigNumber.from('2').pow(255).mul(-1)
            await expect(testFixedMath.ln(minExpValue)).to.be.revertedWith("X_TOO_SMALL_ERROR")
        })

        it('should return log', async () => {
            const { testFixedMath } = await setupTests()
            let ln
            ln = await testFixedMath.ln(parseEther('1.05'))
            expect(ln).to.be.lt(0)
            ln = await testFixedMath.ln(parseEther("0.73"))
            expect(ln).to.be.lt(0)
        })
    })

    describe("exp", async () => {
        it('runs exponent', async () => {
            const { testFixedMath } = await setupTests()
            testFixedMath.exp(-50)
            await expect(testFixedMath.exp(2)).to.be.revertedWith("X_TOO_LARGE_ERROR")
        })
    })

    describe("uintMul", async () => {
        it('runs exponent', async () => {
            const { testFixedMath } = await setupTests()
            await testFixedMath.uintMul(-50, 60)
        })
    })

    describe("toFixed", async () => {
        it('runs exponent', async () => {
            const { testFixedMath } = await setupTests()
            await testFixedMath.toFixed(40, 50)
        })
    })
})
