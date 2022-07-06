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
                factory.createPool(' testpool', 'TEST')
            ).to.be.revertedWith("LIBSANITIZE_SPACE_AT_BEGINNING_ERROR")
            expect(await registry.poolsCount()).to.eq(0)
        })

        it('should revert with space after pool name', async () => {
            const { factory } = await setupTests()
            await expect(
                factory.createPool('testpool ', 'TEST')
            ).to.be.revertedWith("LIBSANITIZE_SPACE_AT_END_ERROR")
        })

        it('should revert with special character in pool name', async () => {
            const { factory } = await setupTests()
            await expect(
                factory.createPool('test+pool', 'TEST')
            ).to.be.revertedWith("LIBSANITIZE_SPECIAL_CHARACTER_ERROR")
        })

        it('should revert with space before pool symbol', async () => {
            const { factory } = await setupTests()
            await expect(
                factory.createPool('testpool2', ' TEST')
            ).to.be.revertedWith("LIBSANITIZE_SPACE_AT_BEGINNING_ERROR")
        })

        it('should create address when creating pool', async () => {
            const { factory, registry } = await setupTests()
            await expect(
                factory.createPool('testpool','TEST')
            ).to.emit(registry, "Registered")
            expect(await registry.poolsCount()).to.eq(1)
            const { poolAddress, symbol } = await registry.fromName('testpool')
            // dummy test
            const poolData = await registry.fromAddress(poolAddress)
            expect(poolData.symbol).to.be.eq(symbol)
        })

        it('should return pool owner', async () => {
          const { factory, registry } = await setupTests()
          const template = await factory.callStatic.createPool('testpool','TEST')
          await factory.createPool('testpool', 'TEST')
          const { poolAddress } = await registry.fromName('testpool')
          const pool = await hre.ethers.getContractAt("RigoblockV3Pool", template)
          const [ user1 ] = waffle.provider.getWallets()
          expect(await pool.owner()).to.be.eq(user1.address)
        })

        it('should create pool with space not first or last character', async () => {
            const { factory } = await setupTests()
            const txReceipt = await factory.createPool('t est pool', 'TEST')
            const [ user1 ] = waffle.provider.getWallets()
            const result = await txReceipt.wait()
            const poolsArray = await factory.getPoolsByAddress(user1.address)
            expect(result.events[1].args.owner).to.be.eq(user1.address)
            expect(poolsArray[0]).to.be.eq(result.events[1].args.poolAddress)
        })

        it('should create pool with uppercase character in name', async () => {
            const { factory } = await setupTests()
            // TODO: rename event and method in factory and interface
            await expect(
                factory.createPool('testPool', 'TEST')
            ).to.emit(factory, "PoolCreated")
        })

        it('should revert when contract exists already', async () => {
            const { factory } = await setupTests()
            await factory.createPool('duplicateName', 'TEST')
            await expect(
                factory.createPool('duplicateName', 'TEST')
            ).to.be.revertedWith("FACTORY_LIBRARY_CREATE2_FAILED_ERROR")
        })

        it('should revert with duplicate name', async () => {
            const { factory, registry } = await setupTests()
            await expect(
                factory.createPool('duplicateName', 'TEST')
            ).to.emit(factory, "PoolCreated")
            await expect(
                factory.createPool('duplicateName', 'TEST2')
            ).to.be.revertedWith("REGISTRY_NAME_ALREADY_REGISTERED_ERROR")
        })

        it('should create pool with duplicate symbol', async () => {
            const { factory, registry } = await setupTests()
            await factory.createPool('someName', 'TEST')
            await expect(
              factory.createPool('someOtherName', 'TEST')
            ).to.emit(factory, "PoolCreated")
            expect(await registry.poolsCount()).to.eq(2)
        })

        it('should revert with symbol longer than 5 characters', async () => {
            const { factory } = await setupTests()
            await expect(
                factory.createPool('testpool2', 'TOOLONG')
            ).to.be.revertedWith("REGISTRY_SYMBOL_LENGTH_ERROR")
        })

        it('should revert with symbol shorter than 3 characters', async () => {
            const { factory } = await setupTests()
            await expect(
                factory.createPool('testpool2', 'TS')
            ).to.be.revertedWith("REGISTRY_SYMBOL_LENGTH_ERROR")
        })

        it('should revert with lowercase symbol', async () => {
            const { factory } = await setupTests()
            await expect(
                factory.createPool('testpool2', 'test')
            ).to.be.revertedWith("LIBSANITIZE_UPPERCASE_CHARACTER_ERROR")
        })
    })
})
