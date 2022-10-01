import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { getAddress } from "ethers/lib/utils";
import { utils } from "ethers";
import { timeTravel } from "../utils/utils";

describe("ReentrancyGuard", async () => {
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
        await factory.createPool('testpool', 'TEST', AddressZero)
        const pool = await hre.ethers.getContractAt(
            "RigoblockV3Pool",
            newPoolAddress
        )
        return {
            factory,
            pool
        }
    });

    describe("nonReentrant", async () => {
        it('should fail when trying to burn', async () => {
            const { factory, pool } = await setupTests()
            const TestReentrancyAttack = await hre.ethers.getContractFactory("TestReentrancyAttack")
            const testReentrancyAttack = await TestReentrancyAttack.deploy(pool.address)
            const etherAmount = parseEther("100")
            await pool.mint(testReentrancyAttack.address, etherAmount, 1, { value: etherAmount })
            const PoolInterface = await hre.ethers.getContractFactory("RigoblockV3Pool")
            const reentrancyAttack = PoolInterface.attach(testReentrancyAttack.address)
            await timeTravel({ seconds: 1, mine: true })
            await expect(reentrancyAttack.burn(etherAmount.div(4), 1))
                .to.be.revertedWith("TEST_REENTRANCY_ATTACK_FAILED_ERROR")
        })
    })
})
