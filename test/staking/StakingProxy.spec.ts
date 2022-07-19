import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { BigNumber, Contract } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { getAddress } from "ethers/lib/utils";

describe("StakingProxy", async () => {
    const [ user1 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        const ResitryInstance = await deployments.get("PoolRegistry")
        const Registry = await hre.ethers.getContractFactory("PoolRegistry")
        const StakingProxyInstance = await deployments.get("StakingProxy")
        const Staking = await hre.ethers.getContractFactory("Staking")
        return {
            factory: Factory.attach(RigoblockPoolProxyFactory.address),
            registry: Registry.attach(ResitryInstance.address),
            stakingProxy: Staking.attach(StakingProxyInstance.address)
        }
    });

    describe("createStakingPool", async () => {
        it('should register an existing Rigoblock pool', async () => {
            const { factory, registry, stakingProxy } = await setupTests()
            await expect(
                stakingProxy.createStakingPool(AddressZero)
            ).to.be.revertedWith("NON_REGISTERED_RB_POOL_ERROR")
            const { newPoolAddress, poolId } = await factory.callStatic.createPool(
                'testpool',
                'TEST',
                AddressZero
            )
            await factory.createPool('testpool', 'TEST', AddressZero)
            await expect(
                stakingProxy.createStakingPool(newPoolAddress)
            ).to.emit(stakingProxy, "StakingPoolCreated").withArgs(poolId, user1.address, 700000)
        })
    })
})
