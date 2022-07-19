import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { BigNumber, Contract } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { timeTravel } from "../utils/utils";
import { getAddress } from "ethers/lib/utils";

describe("Inflation", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        const StakingProxyInstance = await deployments.get("StakingProxy")
        const Staking = await hre.ethers.getContractFactory("Staking")
        const InflationInstance = await deployments.get("Inflation")
        const Inflation = await hre.ethers.getContractFactory("Inflation")
        const RigoTokenInstance = await deployments.get("RigoToken")
        const RigoToken = await hre.ethers.getContractFactory("RigoToken")
        const factory = Factory.attach(RigoblockPoolProxyFactory.address)
        const { newPoolAddress, poolId } = await factory.callStatic.createPool(
            'testpool',
            'TEST',
            AddressZero
        )
        await factory.createPool('testpool','TEST',AddressZero)
        return {
            inflation: Inflation.attach(InflationInstance.address),
            rigoToken: RigoToken.attach(RigoTokenInstance.address),
            stakingProxy: Staking.attach(StakingProxyInstance.address),
            newPoolAddress,
            poolId
        }
    });

    describe("mintInflation", async () => {
        it('should revert if caller not staking proxy', async () => {
            const { inflation } = await setupTests()
            await expect(
                inflation.mintInflation()
            ).to.be.revertedWith("CALLER_NOT_STAKING_PROXY_ERROR")
        })

        it('should wait for epoch 2 before first mint', async () => {
            const { inflation, stakingProxy, rigoToken } = await setupTests()
            expect(await inflation.epochEnded()).to.be.eq(true)
            await expect(
                stakingProxy.endEpoch()
            ).to.be.revertedWith("STAKING_TIMESTAMP_TOO_LOW_ERROR")
            await timeTravel({ days: 14, mine:true })
            await expect(
                stakingProxy.endEpoch()
            ).to.emit(stakingProxy, "EpochFinalized").withArgs(1, 0, 0)
            expect(await rigoToken.balanceOf(stakingProxy.address)).to.be.eq(0)
            await timeTravel({ days: 14, mine:true })
            await expect(
                stakingProxy.endEpoch()
            ).to.emit(stakingProxy, "GrgMintEvent")
            expect(await rigoToken.balanceOf(stakingProxy.address)).to.be.not.eq(0)
        })

        // when deploying on alt-chains we must set rigoblock dao to address 0 in Rigo token after setup
        it('should not allow changin rigoblock address in grg after set to 0', async () => {
            const { inflation, stakingProxy, rigoToken } = await setupTests()
            await expect(rigoToken.changeMintingAddress(user2.address)).to.be.reverted
            // following tests will always fail as we set rigoblock address to 0 in grg token after initial setup
            //await expect(inflation.connect(user2).mintInflation(40000)).to.be.reverted
            //expect(await rigoToken.balanceOf(user2.address)).to.be.eq(40000)
        })
    })
})
