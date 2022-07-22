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
        const ResitryInstance = await deployments.get("PoolRegistry")
        const Registry = await hre.ethers.getContractFactory("PoolRegistry")
        return {
            factory: Factory.attach(RigoblockPoolProxyFactory.address),
            registry: Registry.attach(ResitryInstance.address)
        }
    });

    describe("createPool", async () => {
        it('should revert with space before pool name', async () => {
            const { factory, registry } = await setupTests()
            await expect(
                factory.createPool(' testpool', 'TEST', AddressZero)
            ).to.be.revertedWith("LIBSANITIZE_SPACE_AT_BEGINNING_ERROR")
        })

        it('should revert with space after pool name', async () => {
            const { factory } = await setupTests()
            await expect(
                factory.createPool('testpool ', 'TEST', AddressZero)
            ).to.be.revertedWith("LIBSANITIZE_SPACE_AT_END_ERROR")
        })

        it('should revert with special character in pool name', async () => {
            const { factory } = await setupTests()
            await expect(
                factory.createPool('test+pool', 'TEST', AddressZero)
            ).to.be.revertedWith("LIBSANITIZE_SPECIAL_CHARACTER_ERROR")
        })

        it('should revert with space before pool symbol', async () => {
            const { factory } = await setupTests()
            await expect(
                factory.createPool('testpool2', ' TEST', AddressZero)
            ).to.be.revertedWith("LIBSANITIZE_SPACE_AT_BEGINNING_ERROR")
        })

        it('should create address when creating pool', async () => {
            const { factory, registry } = await setupTests()
            const { newPoolAddress, poolId } = await factory.callStatic.createPool(
                'testpool',
                'TEST',
                AddressZero
            )
            const bytes32symbol = hre.ethers.utils.formatBytes32String('testpool')
            const bytes32name = hre.ethers.utils.formatBytes32String('TEST')
            await expect(
                factory.createPool('testpool','TEST', AddressZero)
            ).to.emit(registry, "Registered").withArgs(
                factory.address,
                newPoolAddress,
                bytes32symbol,
                bytes32name,
                poolId
            )
            expect(
                await registry.getPoolIdFromAddress(newPoolAddress)
            ).to.be.eq(poolId)
        })

        it('should create pool with space not first or last character', async () => {
            const { factory } = await setupTests()
            const { newPoolAddress } = await factory.callStatic.createPool(
                't est pool',
                'TEST',
                AddressZero
            )
            const txReceipt = await factory.createPool(
                't est pool',
                'TEST',
                AddressZero
            )
            const pool = await hre.ethers.getContractAt(
                "RigoblockV3Pool",
                newPoolAddress
            )
            const result = await txReceipt.wait()
            // 3 logs are emitted at pool creation, could expect exact event.withArgs
            expect(result.events[2].args.poolAddress).to.be.eq(newPoolAddress)
        })

        it('should create pool with uppercase character in name', async () => {
            const { factory } = await setupTests()
            await expect(
                factory.createPool('testPool', 'TEST', AddressZero)
            ).to.emit(factory, "PoolCreated")
        })

        it('should revert when contract exists already', async () => {
            const { factory } = await setupTests()
            await factory.createPool('duplicateName', 'TEST', AddressZero)
            await expect(
                factory.createPool('duplicateName', 'TEST', AddressZero)
            ).to.be.revertedWith("FACTORY_LIBRARY_CREATE2_FAILED_ERROR")
        })

        it('should create pool with duplicate name', async () => {
            const { factory, registry } = await setupTests()
            await expect(
                factory.createPool('duplicateName', 'TEST', AddressZero)
            ).to.emit(factory, "PoolCreated")
            await expect(
                factory.createPool('duplicateName', 'TEST2', AddressZero)
            ).to.emit(factory, "PoolCreated")
        })

        it('should create pool with duplicate symbol', async () => {
            const { factory, registry } = await setupTests()
            await factory.createPool('someName', 'TEST', AddressZero)
            await expect(
              factory.createPool('someOtherName', 'TEST', AddressZero)
            ).to.emit(factory, "PoolCreated")
        })

        it('should revert with symbol longer than 5 characters', async () => {
            const { factory } = await setupTests()
            await expect(
                factory.createPool('testpool2', 'TOOLONG', AddressZero)
            ).to.be.revertedWith("REGISTRY_SYMBOL_LENGTH_ERROR")
        })

        it('should revert with symbol shorter than 3 characters', async () => {
            const { factory } = await setupTests()
            await expect(
                factory.createPool('testpool2', 'TS', AddressZero)
            ).to.be.revertedWith("REGISTRY_SYMBOL_LENGTH_ERROR")
        })

        it('should revert with lowercase symbol', async () => {
            const { factory } = await setupTests()
            await expect(
                factory.createPool('testpool2', 'test', AddressZero)
            ).to.be.revertedWith("LIBSANITIZE_UPPERCASE_CHARACTER_ERROR")
        })
    })

    describe("setImplementation", async () => {
        it('should revert if caller not dao address', async () => {
            const { factory, registry } = await setupTests()
            const [ user1, user2 ] = waffle.provider.getWallets()
            await expect(
                factory.connect(user2).setImplementation(AddressZero)
            ).to.be.revertedWith("FACTORY_CALLER_NOT_DAO_ERROR")
            await expect(
                factory.setImplementation(user1.address)
            ).to.be.revertedWith("FACTORY_NEW_IMPLEMENTATION_NOT_CONTRACT_ERROR")
            await expect(
                factory.setImplementation(AddressZero)
            ).to.be.revertedWith("FACTORY_NEW_IMPLEMENTATION_NOT_CONTRACT_ERROR")
            await expect(
                factory.setImplementation(registry.address)
            ).to.emit(factory, "Upgraded").withArgs(registry.address)
            expect(await factory.implementation()).to.be.eq(registry.address)
        })
    })

    describe("setRegistry", async () => {
        it('should revert if caller not dao address', async () => {
            const { factory, registry } = await setupTests()
            const [ user1, user2 ] = waffle.provider.getWallets()
            await expect(
                factory.connect(user2).setRegistry(AddressZero)
            ).to.be.revertedWith("FACTORY_CALLER_NOT_DAO_ERROR")
            await expect(
                factory.setRegistry(user1.address)
            ).to.be.revertedWith("FACTORY_NEW_REGISTRY_NOT_CONTRACT_ERROR")
            await expect(
                factory.setRegistry(AddressZero)
            ).to.be.revertedWith("FACTORY_NEW_REGISTRY_NOT_CONTRACT_ERROR")
            // TODO: check if should prevent same address input, as no hard would be done
            await expect(
                factory.setRegistry(factory.address)
            ).to.emit(factory, "RegistryUpgraded").withArgs(factory.address)
            expect(await factory.getRegistry()).to.be.eq(factory.address)
            // pool registry will always emit return error on failure
            await expect(
                factory.createPool('testpool', 'TEST', AddressZero)
            ).to.be.reverted
        })
    })
})
