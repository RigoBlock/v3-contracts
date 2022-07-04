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
        const ResitryInstance = await deployments.get("DragoRegistry")
        const Registry = await hre.ethers.getContractFactory("DragoRegistry")
        return {
          factory: Factory.attach(RigoblockPoolProxyFactory.address),
          registry: Registry.attach(ResitryInstance.address)
        }
    });

    describe("createDrago", async () => {
        it('should revert with space before pool name', async () => {
            const { factory, registry } = await setupTests()
            await expect(
                factory.createDrago(' testpool', 'TEST')
            ).to.be.revertedWith("LIBSANITIZE_SPACE_AT_BEGINNING_ERROR")
            expect(await registry.dragoCount()).to.eq(0)
        })

        it('should revert with space after pool name', async () => {
            const { factory } = await setupTests()
            await expect(
                factory.createDrago('testpool ', 'TEST')
            ).to.be.revertedWith("LIBSANITIZE_SPACE_AT_END_ERROR")
        })

        it('should revert with special character in pool name', async () => {
            const { factory } = await setupTests()
            await expect(
                factory.createDrago('test+pool', 'TEST')
            ).to.be.revertedWith("LIBSANITIZE_SPECIAL_CHARACTER_ERROR")
        })

        it('should revert with space before pool symbol', async () => {
            const { factory } = await setupTests()
            await expect(
                factory.createDrago('testpool2', ' TEST')
            ).to.be.revertedWith("LIBSANITIZE_SPACE_AT_BEGINNING_ERROR")
        })

        it('should create address when creating pool', async () => {
            const { factory, registry } = await setupTests()
            const txReceipt = await factory.createDrago('testpool', 'TEST')
            expect(txReceipt.hash).to.be.not.eq(null)
            expect(await registry.dragoCount()).to.eq(1)
        })

        it('should create pool with space not first or last character', async () => {
            const { factory } = await setupTests()
            const txReceipt = await factory.createDrago('t est pool', 'TEST')
            expect(txReceipt.hash).to.be.not.eq(null)
        })

        it('should create pool with uppercase character in name', async () => {
            const { factory } = await setupTests()
            const txReceipt = await factory.createDrago('testPool', 'TEST')
            expect(txReceipt.hash).to.be.not.eq(null)
        })

        it('should revert when contract exists already', async () => {
            const { factory } = await setupTests()
            await factory.createDrago('duplicateName', 'TEST')
            await expect(
                factory.createDrago('duplicateName', 'TEST')
            ).to.be.revertedWith("PROXY_FACTORY_LIBRARY_DEPLOY_ERROR")
        })

        // TODO: should have different address with different symbol and revert in registry.
        it('should revert with duplicate name', async () => {
            const { factory, registry } = await setupTests()
            await factory.createDrago('duplicateName', 'TEST')
            const [ user1 ] = waffle.provider.getWallets()
            console.log(user1.address, await factory.getDragosByAddress(user1.address))
            await expect(
                factory.createDrago('duplicateName', 'TEST2')
            ).to.be.revertedWith("REGISTRY_ADDRESS_ALREADY_TAKEN_ERROR")
        })

        // TODO: check why second pool has same address with different names
        it('should create pool with duplicate symbol', async () => {
            const { factory } = await setupTests()
            await factory.createDrago('someName', 'TEST')
            await expect(
              factory.createDrago('someOtherName', 'TEST')
            ).to.be.revertedWith("REGISTRY_ADDRESS_ALREADY_TAKEN_ERROR")
        })

        it('should revert with symbol longer than 5 characters', async () => {
            const { factory } = await setupTests()
            await expect(
                factory.createDrago('testpool2', 'TOOLONG')
            ).to.be.revertedWith("REGISTRY_SYMBOL_LENGTH_ERROR")
        })

        it('should revert with symbol shorter than 3 characters', async () => {
            const { factory } = await setupTests()
            await expect(
                factory.createDrago('testpool2', 'TS')
            ).to.be.revertedWith("REGISTRY_SYMBOL_LENGTH_ERROR")
        })

        it('should revert with lowercase symbol', async () => {
            const { factory } = await setupTests()
            await expect(
                factory.createDrago('testpool2', 'test')
            ).to.be.revertedWith("LIBSANITIZE_UPPERCASE_CHARACTER_ERROR")
        })
    })
})
