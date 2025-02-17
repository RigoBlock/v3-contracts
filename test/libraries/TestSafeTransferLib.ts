import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber, Contract } from "ethers";

describe("TestSafeTransferLib", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async () => {
        const TestSafeTransferLib = await hre.ethers.getContractFactory("TestSafeTransferLib")
        const testSafeTransferLib = await TestSafeTransferLib.deploy()
        return {
            testSafeTransferLib
        }
    })

    describe("testForceApprove", async () => {
        it('should set approval of non-standard ERC20', async () => {
            const { testSafeTransferLib } = await setupTests()
            const amount = parseEther('1')
            await expect(
                testSafeTransferLib.testForceApprove(user2.address, amount)
            ).to.emit(testSafeTransferLib, 'Approval').withArgs(testSafeTransferLib.address, user2.address, amount)
            await expect(
                testSafeTransferLib.testForceApprove(user2.address, amount.div(2))
            ).to.emit(testSafeTransferLib, 'Approval').withArgs(testSafeTransferLib.address, user2.address, amount.div(2))
        })
    })
})
