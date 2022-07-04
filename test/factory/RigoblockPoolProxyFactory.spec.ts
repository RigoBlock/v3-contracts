import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { BigNumber, Contract } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { getAddress } from "ethers/lib/utils";

describe("ProxyFactory", async () => {
    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        return {
          factory: Factory.attach(RigoblockPoolProxyFactory.address),
          addresslog: RigoblockPoolProxyFactory.address
        }
    });

    describe("createDrago", async () => {
        it('should revert with space before pool name', async () => {
            const { factory } = await setupTests()
            await expect(
                factory.createDrago(' testpool', 'TEST')
            ).to.be.revertedWith("Transaction reverted without a reason")
        })

        it('should revert with space after pool name', async () => {
            const { factory } = await setupTests()
            await expect(
                factory.createDrago('testpool ', 'TEST')
            ).to.be.revertedWith("Transaction reverted without a reason")
        })

        it('should revert with special character in pool name', async () => {
            const { factory, addresslog } = await setupTests()
            await expect(
                factory.createDrago('test+pool', 'TEST')
            ).to.be.revertedWith("Transaction reverted without a reason")
        })

        it('should revert with space before pool symbol', async () => {
            const { factory } = await setupTests()
            await expect(
                factory.createDrago('testpool2', ' TEST')
            ).to.be.revertedWith("Transaction reverted without a reason")
        })

        // TODO: fix following, as poolAddress is tx hash, not the return value
        it('should create address when creating pool', async () => {
            const { factory } = await setupTests()
            const poolAddress = await factory.createDrago('testpool', 'TEST')
            expect(poolAddress).to.be.not.eq(AddressZero)
        })

        // TODO: fix following, as poolAddress is tx hash, not the return value
        it('should create pool with space not first or last character', async () => {
            const { factory } = await setupTests()
            const poolAddress = await factory.createDrago('t est pool', 'TEST')
            expect(poolAddress).to.be.not.eq(AddressZero)
        })

        // TODO: fix following, as poolAddress is tx hash, not the return value
        it('should create pool with uppercase character in name', async () => {
            const { factory } = await setupTests()
            const poolAddress = await factory.createDrago('testPool', 'TEST')
            expect(poolAddress).to.be.not.eq(AddressZero)
        })

        // TODO: following should revert in registry
        it('should revert with duplicate name', async () => {
            const { factory } = await setupTests()
            await factory.createDrago('duplicateName', 'TEST')
            await expect(
                factory.createDrago('duplicateName', 'TEST')
            ).to.be.revertedWith("PROXY_FACTORY_LIBRARY_DEPLOY_ERROR")
        })

        // TODO: fix following test
        it('should create pool with duplicate symbol', async () => {
            const { factory } = await setupTests()
            await factory.createDrago('someName', 'TEST')
            await expect(
              factory.createDrago('someOtherName', 'TEST')
            ).to.be.revertedWith("Transaction reverted without a reason")
        })

        it('should revert with symbol longer than 5 characters', async () => {
            const { factory } = await setupTests()
            await expect(
                factory.createDrago('testpool2', 'TOOLONG')
            ).to.be.revertedWith("Transaction reverted without a reason")
        })

        it('should revert with symbol SHORTER than 3 characters', async () => {
            const { factory } = await setupTests()
            await expect(
                factory.createDrago('testpool2', 'TS')
            ).to.be.revertedWith("Transaction reverted without a reason")
        })

        it('should revert with lowercase symbol', async () => {
            const { factory } = await setupTests()
            await expect(
                factory.createDrago('testpool2', 'test')
            ).to.be.revertedWith("Transaction reverted without a reason")
        })
    })
})
