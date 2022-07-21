import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { BigNumber, Contract } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { getAddress } from "ethers/lib/utils";

describe("StakingProxy", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        const StakingProxyInstance = await deployments.get("StakingProxy")
        const Staking = await hre.ethers.getContractFactory("Staking")
        const factory = Factory.attach(RigoblockPoolProxyFactory.address)
        const { newPoolAddress, poolId } = await factory.callStatic.createPool(
            'testpool',
            'TEST',
            AddressZero
        )
        await factory.createPool('testpool','TEST',AddressZero)
        return {
            stakingProxy: Staking.attach(StakingProxyInstance.address),
            newPoolAddress,
            poolId
        }
    });

    describe("createStakingPool", async () => {
        it('should revert with non registered pool', async () => {
            const { stakingProxy, newPoolAddress, poolId } = await setupTests()
            await expect(
                stakingProxy.createStakingPool(AddressZero)
            ).to.be.revertedWith("NON_REGISTERED_RB_POOL_ERROR")
        })

        it('should create staking pool for an existing Rigoblock pool', async () =>  {
            const { stakingProxy, newPoolAddress, poolId } = await setupTests()
            await expect(
                stakingProxy.createStakingPool(newPoolAddress)
            ).to.emit(stakingProxy, "StakingPoolCreated").withArgs(poolId, user1.address, 700000)
        })

        it('should revert if pool already registered', async () =>  {
            const { stakingProxy, newPoolAddress, poolId } = await setupTests()
            await stakingProxy.createStakingPool(newPoolAddress)
            await expect(
                stakingProxy.createStakingPool(newPoolAddress)
            ).to.be.revertedWith("STAKING_POOL_ALREADY_EXISTS_ERROR")
        })
    })

    describe("setStakingPalAddress", async () => {
        it('should revert if caller not pool operator', async () => {
            const { stakingProxy, newPoolAddress, poolId } = await setupTests()
            await stakingProxy.createStakingPool(newPoolAddress)
            await expect(
                stakingProxy.connect(user2).setStakingPalAddress(poolId, AddressZero)
            ).to.be.revertedWith("CALLER_NOT_OPERATOR_ERROR")
        })

        it('should revert if null input address', async () => {
            const { stakingProxy, newPoolAddress, poolId } = await setupTests()
            await stakingProxy.createStakingPool(newPoolAddress)
            await expect(
                stakingProxy.setStakingPalAddress(poolId, AddressZero)
            ).to.be.revertedWith("STAKING_PAL_NULL_OR_SAME_ERROR")
        })

        // TODO: this test will fail if we do not initialize staking pal if same as owner to save gas
        it('should revert if pal address is same', async () => {
            const { stakingProxy, newPoolAddress, poolId } = await setupTests()
            await stakingProxy.createStakingPool(newPoolAddress)
            await expect(
                stakingProxy.setStakingPalAddress(poolId, user1.address)
            ).to.be.revertedWith("STAKING_PAL_NULL_OR_SAME_ERROR")
        })

        it('shoud set new staking pal', async () => {
            const { stakingProxy, newPoolAddress, poolId } = await setupTests()
            await stakingProxy.createStakingPool(newPoolAddress)
            await stakingProxy.setStakingPalAddress(poolId, user2.address)
            const poolData = await stakingProxy.getStakingPool(poolId)
            expect(poolData.stakingPal).to.be.eq(user2.address)
        })
    })

    describe("decreaseStakingPoolOperatorShare", async () => {
        it('should revert if caller not pool operator', async () => {
            const { stakingProxy, newPoolAddress, poolId } = await setupTests()
            await stakingProxy.createStakingPool(newPoolAddress)
            await expect(
                stakingProxy.connect(user2).decreaseStakingPoolOperatorShare(poolId, 500000)
            ).to.be.revertedWith("CALLER_NOT_OPERATOR_ERROR")
        })

        // since value initialized at 700k in Rigoblock staking, this condition should never be readched
        it('should revert if value higher than max', async () => {
            const { stakingProxy, newPoolAddress, poolId } = await setupTests()
            await stakingProxy.createStakingPool(newPoolAddress)
            await expect(
                stakingProxy.decreaseStakingPoolOperatorShare(poolId, 1000001)
            ).to.be.revertedWith("OPERATOR_SHARE_BIGGER_THAN_MAX_ERROR")
        })

        it('should revert if value higher than current', async () => {
            const { stakingProxy, newPoolAddress, poolId } = await setupTests()
            await stakingProxy.createStakingPool(newPoolAddress)
            await expect(
                stakingProxy.decreaseStakingPoolOperatorShare(poolId, 700001)
            ).to.be.revertedWith("OPERATOR_SHARE_BIGGER_THAN_CURRENT_ERROR")
        })

        it('should emit log when successful', async () => {
            const { stakingProxy, newPoolAddress, poolId } = await setupTests()
            await stakingProxy.createStakingPool(newPoolAddress)
            await expect(
                stakingProxy.decreaseStakingPoolOperatorShare(poolId, 500000)
            ).to.emit(stakingProxy, "OperatorShareDecreased").withArgs(
                poolId,
                700000,
                500000
            )
        })
    })

    describe("init", async () => {
        it('should revert if already initialized', async () => {
            const { stakingProxy } = await setupTests()
            await expect(
                stakingProxy.init()
            ).to.be.revertedWith("AUTHORIZABLE_SENDER_NOT_AUTHORIZED_ERROR")
            await stakingProxy.addAuthorizedAddress(user1.address)
            await expect(
                stakingProxy.init()
            ).to.be.revertedWith("STAKING_SCHEDULER_ALREADY_INITIALIZED_ERROR")
        })
    })
})
