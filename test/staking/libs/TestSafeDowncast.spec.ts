import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber, Contract } from "ethers";

describe("TestSafeDowncast", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async () => {
        const TestSafeDowncast = await hre.ethers.getContractFactory("TestLibSafeDowncast")
        const testSafeDowncast = await TestSafeDowncast.deploy()
        return {
            testSafeDowncast
        }
    })

    describe("downcastToUint96", async () => {
        it('should revert when bigger than uint96', async () => {
            const { testSafeDowncast } = await setupTests()
            const uint100 = BigNumber.from('2').pow(100).sub(1)
            await expect(testSafeDowncast.downcastToUint96(uint100))
                .to.be.revertedWith("VALUE_TOO_LARGE_TO_DOWNCAST_TO_UINT96")
        })
    })

    describe("downcastToUint64", async () => {
        it('should revert when bigger than uint64', async () => {
            const { testSafeDowncast } = await setupTests()
            const uint80 = BigNumber.from('2').pow(80).sub(1)
            await expect(testSafeDowncast.downcastToUint64(uint80))
                .to.be.revertedWith("VALUE_TOO_LARGE_TO_DOWNCAST_TO_UINT64")
        })
    })
})
