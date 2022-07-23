import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { deployContract } from "../utils/utils";
import { BigNumber, Contract } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { getAddress } from "ethers/lib/utils";

describe("PoolRegistry", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        const ResitryInstance = await deployments.get("PoolRegistry")
        const Registry = await hre.ethers.getContractFactory("PoolRegistry")
        const AuthorityInstance = await deployments.get("AuthorityCore")
        const Authority = await hre.ethers.getContractFactory("AuthorityCore")
        return {
            factory: Factory.attach(RigoblockPoolProxyFactory.address),
            registry: Registry.attach(ResitryInstance.address),
            authority: Authority.attach(AuthorityInstance.address)
        }
    });

    describe("register", async () => {
        it('should revert if address not whitelisted in authority', async () => {
            const { registry } = await setupTests()
            const mockBytes32 = hre.ethers.utils.formatBytes32String('mock')
            await expect(
                registry.register(AddressZero, 'testpool', 'TEST', mockBytes32)
            ).to.be.revertedWith("REGISTRY_FACTORY_NOT_WHITELISTED_ERROR")
        })

        it('should revert if address already registered', async () => {
            const { authority, registry } = await setupTests()
            await authority.setFactory(user1.address, true)
            const mockBytes32 = hre.ethers.utils.formatBytes32String('mock')
            await registry.register(AddressZero, 'testpool', 'TEST', mockBytes32)
            await expect(
                registry.register(AddressZero, ' testpool', 'TEST', mockBytes32)
            ).to.be.revertedWith("REGISTRY_ADDRESS_ALREADY_TAKEN_ERROR")
        })

        it('should revert if name longer than 32 characters', async () => {
            const { authority, registry } = await setupTests()
            await authority.setFactory(user1.address, true)
            const mockBytes32 = hre.ethers.utils.formatBytes32String('mock')
            const longName = '40 characters are way too long for a name'
            const shortName = 'sho'
            await expect(
                registry.register(AddressZero, longName, 'TEST', mockBytes32)
            ).to.be.revertedWith("REGISTRY_NAME_LENGTH_ERROR")
            await expect(
                registry.register(AddressZero, shortName, 'TEST', mockBytes32)
            ).to.be.revertedWith("REGISTRY_NAME_LENGTH_ERROR")
        })
    })

    describe("setMeta", async () => {
        it('should revert if caller is not pool owner', async () => {
            const { registry } = await setupTests()
            const source = `
            contract Owned {
                address public owner;
                function setOwner(address _owner) public { owner = _owner; }
            }`
            const mockPool = await deployContract(user2, source)
            await mockPool.setOwner(user2.address)
            const key = hre.ethers.utils.formatBytes32String('mock')
            const value = hre.ethers.utils.formatBytes32String('value')
            await expect(
                registry.setMeta(mockPool.address, key, value)
            ).to.be.revertedWith("REGISTRY_CALLER_IS_NOT_POOL_OWNER_ERROR")
        })

        it('should revert if pool not registered', async () => {
            const { registry, authority } = await setupTests()
            const source = `
            contract Owned {
                address public owner;
                function setOwner(address _owner) public { owner = _owner; }
            }`
            const mockPool = await deployContract(user1, source)
            await mockPool.setOwner(user2.address)
            const poolAddress = mockPool.address
            const poolId = hre.ethers.utils.formatBytes32String('mockId')
            const key = hre.ethers.utils.formatBytes32String('mock')
            const value = hre.ethers.utils.formatBytes32String('value')
            await expect(
                registry.connect(user2).setMeta(poolAddress, key, value)
            ).to.be.revertedWith("REGISTRY_ADDRESS_NOT_REGISTERED_ERROR")
            await authority.setFactory(user1.address, true)
            await registry.register(poolAddress, 'testName', 'TEST', poolId)
            await expect(
                registry.connect(user2).setMeta(poolAddress, key, value)
            ).to.emit(registry, "MetaChanged").withArgs(poolAddress, key, value)
            expect(await registry.getMeta(poolAddress, key)).to.be.eq(value)
        })
    })

    describe("setAuthority", async () => {
        it('should revert if caller not dao address', async () => {
            const { factory, registry } = await setupTests()
            await expect(
                registry.connect(user2).setAuthority(AddressZero)
            ).to.be.revertedWith("REGISTRY_CALLER_NOT_DAO_ERROR")
            const authorityAddress = await registry.authority()
            await expect(
                registry.setAuthority(authorityAddress)
            ).to.be.revertedWith("REGISTRY_SAME_INPUT_ADDRESS_ERROR")
            await expect(
                registry.setAuthority(user1.address)
            ).to.be.revertedWith("REGISTRY_NEW_AUTHORITY_NOT_CONTRACT_ERROR")
            await expect(
                registry.setAuthority(AddressZero)
            ).to.be.revertedWith("REGISTRY_NEW_AUTHORITY_NOT_CONTRACT_ERROR")
            await expect(
                registry.setAuthority(factory.address)
            ).to.emit(registry, "AuthorityChanged").withArgs(factory.address)
            expect(await registry.authority()).to.be.eq(factory.address)
        })
    })

    describe("setRigoblockDao", async () => {
        it('should revert if caller not dao address', async () => {
            const { factory, registry } = await setupTests()
            await expect(
                registry.connect(user2).setRigoblockDao(AddressZero)
            ).to.be.revertedWith("REGISTRY_CALLER_NOT_DAO_ERROR")
            const daoAddress = await registry.rigoblockDaoAddress()
            await expect(
                registry.setRigoblockDao(daoAddress)
            ).to.be.revertedWith("REGISTRY_SAME_INPUT_ADDRESS_ERROR")
            await expect(
                registry.setRigoblockDao(user2.address)
            ).to.be.revertedWith("REGISTRY_NEW_DAO_NOT_CONTRACT_ERROR")
            await expect(
                registry.setRigoblockDao(AddressZero)
            ).to.be.revertedWith("REGISTRY_NEW_DAO_NOT_CONTRACT_ERROR")
            await expect(
                registry.setRigoblockDao(factory.address)
            ).to.emit(registry, "RigoblockDaoChanged").withArgs(factory.address)
            expect(await registry.rigoblockDaoAddress()).to.be.eq(factory.address)
        })
    })
})
