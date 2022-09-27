import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { BigNumber, Contract } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { getAddress } from "ethers/lib/utils";

describe("Staking", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        const StakingInstance = await deployments.get("Staking")
        const Staking = await hre.ethers.getContractFactory("Staking")
        const factory = Factory.attach(RigoblockPoolProxyFactory.address)
        const { newPoolAddress, poolId } = await factory.callStatic.createPool(
            'testpool',
            'TEST',
            AddressZero
        )
        await factory.createPool('testpool','TEST',AddressZero)
        return {
            staking: Staking.attach(StakingInstance.address),
            newPoolAddress
        }
    });

    describe("createStakingPool", async () => {
        it('should revert with non registered pool', async () => {
            const { staking, newPoolAddress } = await setupTests()
            await expect(
                staking.createStakingPool(newPoolAddress)
            ).to.be.revertedWith("STAKING_DIRECT_CALL_NOT_ALLOWED_ERROR")
        })
    })

    describe("stake", async () => {
        it('should revert with non registered pool', async () => {
            const { staking } = await setupTests()
            await expect(
                staking.stake(1)
            ).to.be.revertedWith("GRG_VAULT_ONLY_CALLABLE_BY_STAKING_PROXY_ERROR")
        })
    })

    describe("endEpoch", async () => {
        it('should revert with non registered pool', async () => {
            const { staking } = await setupTests()
            // will revert as not initilized
            await expect(
                staking.endEpoch()
            ).to.be.revertedWith("LIBSAFEMATH_SUBTRACTION_UNDERFLOW_ERROR")
        })
    })

    describe("init", async () => {
        it('should revert as caller not authorized', async () => {
            const { staking } = await setupTests()
            await expect(
                staking.init()
            ).to.be.revertedWith("AUTHORIZABLE_SENDER_NOT_AUTHORIZED_ERROR")
        })
    })

    describe("addAuthorizedAddress", async () => {
        it('should revert without error', async () => {
            const { staking } = await setupTests()
            await expect(staking.addAuthorizedAddress(user1.address))
                .to.be.revertedWith("CALLER_NOT_OWNER_ERROR")
        })
    })

    describe("transferOwnership", async () => {
        it('should revert without error', async () => {
            const { staking } = await setupTests()
            await expect(staking.transferOwnership(AddressZero)).to.be.revertedWith("CALLER_NOT_OWNER_ERROR")
        })
    })
})
