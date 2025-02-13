import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";

describe("EUpgrade", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const AuthorityInstance = await deployments.get("Authority")
        const Authority = await hre.ethers.getContractFactory("Authority")
        const authority = Authority.attach(AuthorityInstance.address)
        const FactoryInstance = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        const factory = Factory.attach(FactoryInstance.address)
        const { newPoolAddress } = await factory.callStatic.createPool(
            'testpool',
            'TEST',
            AddressZero
        )
        await factory.createPool('testpool', 'TEST', AddressZero)
        const pool = await hre.ethers.getContractAt("IRigoblockPoolExtended", newPoolAddress)
        const EUpgrade = await hre.ethers.getContractFactory("EUpgrade")
        const eUpgrade = await EUpgrade.deploy(FactoryInstance.address)
        await authority.setAdapter(eUpgrade.address, true)
        // "466f3dc3": "upgradeImplementation()"
        await authority.addMethod("0x466f3dc3", eUpgrade.address)
        // "2d6b3a6b": "getBeacon()"
        authority.addMethod("0x2d6b3a6b", eUpgrade.address)
        return {
            authority,
            EUpgrade,
            eUpgrade,
            pool,
            factory,
            newPoolAddress
        }
    })

    describe("upgradeImplementation", async () => {
        it('should revert if called directly', async () => {
            const { eUpgrade } = await setupTests()
            await expect(eUpgrade.upgradeImplementation())
                .to.be.revertedWith('EUpgradeDirectCall()')
        })

        it('should revert if new implementation is same as current', async () => {
            const { pool } = await setupTests()
            await expect(pool.upgradeImplementation())
                .to.be.revertedWith('EUpgradeImplementationIsSameAsCurrent()')
        })

        it('should upgrade implementation', async () => {
            const { factory, pool } = await setupTests()
            await factory.setImplementation(factory.address)
            await expect(pool.upgradeImplementation())
                .to.emit(pool, "Upgraded").withArgs(factory.address)
        })

        // when a user who is not the pool owner tries to upgrade the implementation a staticcall is made to the extension, instead of a delegatecall
        it('should revert if caller is not pool owner', async () => {
            const { factory, pool } = await setupTests()
            await factory.setImplementation(factory.address)
            await expect(pool.connect(user2).upgradeImplementation())
                .to.be.revertedWith('EUpgradeDirectCall()')
        })

        it('should now allow multicall to upgrade for non-owner', async () => {
            const { authority, factory, pool, newPoolAddress } = await setupTests()
            //await factory.setImplementation(factory.address)
            const encodedUpgradeData = pool.interface.encodeFunctionData('upgradeImplementation')
            const MulticallPool = await hre.ethers.getContractFactory("AMulticall")
            const multicallPool = MulticallPool.attach(newPoolAddress)
            authority.setAdapter(multicallPool.address, true)
            // "ac9650d8": "multicall(bytes[])"
            await authority.addMethod("0xac9650d8", multicallPool.address)
            const encodedMulticallData = multicallPool.interface.encodeFunctionData(
                'multicall(bytes[])',
                [ [encodedUpgradeData] ]
            )
            // multicall reverts without a reason
            await expect(
                user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedMulticallData})
            ).to.be.revertedWith('Transaction reverted without a reason')
        })
    })
})
