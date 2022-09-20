import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber, Contract } from "ethers";

describe("TestCobbDouglas", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture()
        const CobbDouglas = await hre.ethers.getContractFactory("TestCobbDouglas")
        const cobbDouglas = await CobbDouglas.deploy()
        return {
            cobbDouglas
        }
    })

    describe("CobbDouglas", async () => {
        it('should return 0 with 0 fee ratio or 0 stake ratio', async () => {
            const { cobbDouglas } = await setupTests()
            let reward
            reward = await cobbDouglas.cobbDouglas(
                100,
                10,
                100,
                20,
                200,
                2,
                3
            )
            expect(reward).to.be.not.eq(0)
            reward = await cobbDouglas.cobbDouglas(
                100,
                0,
                100,
                20,
                200,
                2,
                3
            )
            expect(reward).to.be.deep.eq(0)
            reward = await cobbDouglas.cobbDouglas(
                100,
                10,
                100,
                0,
                200,
                2,
                3
            )
            expect(reward).to.be.deep.eq(0)
        })
    })
})
