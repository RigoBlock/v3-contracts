import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero, MaxUint256 } from "@ethersproject/constants";

describe("AMulticall", async () => {
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
        const AMulticallInstance = await deployments.get("AMulticall")
        const AMulticall = await hre.ethers.getContractFactory("AMulticall")
        const aMulticall = AMulticall.attach(AMulticallInstance.address)
        const EUpgrade = await hre.ethers.getContractFactory("EUpgrade")
        const eUpgrade = await EUpgrade.deploy(FactoryInstance.address)
        await authority.setAdapter(aMulticall.address, true)
        await authority.setAdapter(eUpgrade.address, true)
        // "ac9650d8": "multicall(bytes[])"
        await authority.addMethod("0xac9650d8", AMulticallInstance.address)
        // "5ae401dc": "multicall(uint256,bytes[])"
        await authority.addMethod("0x5ae401dc", AMulticallInstance.address)
        // "1f0464d1": "multicall(bytes32,bytes[])"
        await authority.addMethod("0x1f0464d1", AMulticallInstance.address)
        // "466f3dc3": "upgradeImplementation()"
        await authority.addMethod("0x466f3dc3", eUpgrade.address)
        return {
            authority,
            aMulticall,
            pool,
            factory
        }
    })

    describe("multicall", async () => {
        // as a call gets re-routed to the contract, a direct call will be reverted in the implementing methods.
        it('should allow direct call', async () => {
            const { aMulticall, pool } = await setupTests()
            const encodedSetOwnerData = pool.interface.encodeFunctionData('setOwner', [user2.address])
            const encodedMulticallData = aMulticall.interface.encodeFunctionData(
                'multicall(bytes[])',
                [ [encodedSetOwnerData] ]
            )
            // a direct call to the extension always fails
            await expect(
                user1.sendTransaction({ to: aMulticall.address, value: 0, data: encodedMulticallData})
            ).to.be.reverted
        })

        it('should revert if method not implemented', async () => {
            const { aMulticall, authority, factory, pool } = await setupTests()
            const encodedSetImplementation = factory.interface.encodeFunctionData('setImplementation', [user2.address])
            let encodedMulticallData = pool.interface.encodeFunctionData(
                'multicall(bytes[])',
                [ [encodedSetImplementation] ]
            )
            // txn will always revert in fallback: setImplementation is not mapped,
            // pool fallback reverts with PoolMethodNotAllowed, AMulticall forwards the underlying revert reason.
            await expect(
                user1.sendTransaction({ to: pool.address, value: 0, data: encodedMulticallData})
            ).to.be.revertedWith("PoolMethodNotAllowed")
            // if a rogue adapter could be added by the governance, but that is part of the protocol rules.
            await authority.setAdapter(factory.address, true)
            // "d784d426": "setImplementation(address)"
            await authority.addMethod("0xd784d426", factory.address)
            await expect(
                user1.sendTransaction({ to: pool.address, value: 0, data: encodedMulticallData})
            ).to.be.reverted
            // however, an adapter <> selector mapping misconfiguration will result in revert
            await authority.removeMethod("0xd784d426", factory.address)
            await authority.addMethod("0xd784d426", aMulticall.address)
            await expect(
                user1.sendTransaction({ to: pool.address, value: 0, data: encodedMulticallData})
            ).to.be.reverted
        })

        it('should prevent skipping owner check', async () => {
            const { factory, pool } = await setupTests()
            // when the method is called by a wallet other than the pool owner, the ExtensionsMap prompts the fallback 
            // to forward a `staticcall` to the target extension. Therefore, instead of being executed in the context
            // of the pool proxy, it gets executed in the EUpgrade contract and is thus reverted as a direct call is not allowed.
            await expect(pool.connect(user2).upgradeImplementation())
                .to.be.revertedWith('EUpgradeDirectCall')
            await factory.setImplementation(factory.address)
            const encodedUpgradeData = pool.interface.encodeFunctionData('upgradeImplementation')
            const encodedMulticallData = pool.interface.encodeFunctionData(
                'multicall(bytes[])',
                [ [encodedUpgradeData] ]
            )
            // in the non-owner staticcall path the inner delegatecall target is the adapter itself,
            // so no rich revert reason is produced; the transaction still reverts.
            await expect(
                user2.sendTransaction({ to: pool.address, value: 0, data: encodedMulticallData})
            ).to.be.reverted
            await expect(
                user1.sendTransaction({ to: pool.address, value: 0, data: encodedMulticallData})
            ).to.emit(pool, "Upgraded").withArgs(factory.address)
        })

        it('should allow owner to set a new owner', async () => {
            const { pool } = await setupTests()
            await expect(pool.connect(user2).setOwner(user2.address))
                .to.be.revertedWith('PoolCallerIsNotOwner')
            const encodedSetOwnerData = pool.interface.encodeFunctionData('setOwner', [user2.address])
            let encodedMulticallData = pool.interface.encodeFunctionData(
                'multicall(bytes[])',
                [ [encodedSetOwnerData] ]
            )
            // in the non-owner staticcall path the inner delegatecall target is the adapter itself,
            // so no rich revert reason is produced; the transaction still reverts.
            await expect(
                user2.sendTransaction({ to: pool.address, value: 0, data: encodedMulticallData})
            ).to.be.reverted
            await expect(
                user1.sendTransaction({ to: pool.address, value: 0, data: encodedMulticallData})
            ).to.emit(pool, "NewOwner").withArgs(user1.address, user2.address)
        })

        it('should upgrade implementation', async () => {
            const { factory, pool } = await setupTests()
            await factory.setImplementation(factory.address)
            const encodedUpgradeData = pool.interface.encodeFunctionData('upgradeImplementation')
            const encodedMulticallData = pool.interface.encodeFunctionData(
                'multicall(bytes[])',
                [ [encodedUpgradeData] ]
            )
            // in the non-owner staticcall path the inner delegatecall target is the adapter itself,
            // so no rich revert reason is produced; the transaction still reverts.
            await expect(
                user2.sendTransaction({ to: pool.address, value: 0, data: encodedMulticallData})
            ).to.be.reverted
            await expect(
                user1.sendTransaction({ to: pool.address, value: 0, data: encodedMulticallData})
            ).to.emit(pool, "Upgraded").withArgs(factory.address)
        })

        // reentrancy is blocked in the methods' implementations, where needed.
        it('should not prevent reentrancy', async () => {
            const { pool } = await setupTests()
            const encodedSetOwnerData = pool.interface.encodeFunctionData('setOwner', [user2.address])
            const encodedMulticallData = pool.interface.encodeFunctionData(
                'multicall(bytes[])',
                [ [encodedSetOwnerData] ]
            )
            const recursiveMulticallData = pool.interface.encodeFunctionData(
                'multicall(bytes[])',
                [ [encodedMulticallData] ]
            )
            await expect(
                user2.sendTransaction({ to: pool.address, value: 0, data: recursiveMulticallData})
            ).to.be.reverted
            await expect(
                user1.sendTransaction({ to: pool.address, value: 0, data: recursiveMulticallData})
            ).to.emit(pool, "NewOwner").withArgs(user1.address, user2.address)
        })

        it('should revert on recursive call with unknown method', async () => {
            const { authority, factory, pool } = await setupTests()
            await authority.setAdapter(factory.address, true)
            // "d784d426": "setImplementation(address)"
            await authority.addMethod("0xd784d426", factory.address)
            const unknownData = factory.interface.encodeFunctionData('setImplementation', [user2.address])
            const encodedMulticallData = pool.interface.encodeFunctionData(
                'multicall(bytes[])',
                [ [unknownData] ]
            )
            const recursiveMulticallData = pool.interface.encodeFunctionData(
                'multicall(bytes[])',
                [ [encodedMulticallData] ]
            )
            await expect(
                user2.sendTransaction({ to: pool.address, value: 0, data: recursiveMulticallData})
            ).to.be.reverted
            await expect(
                user1.sendTransaction({ to: pool.address, value: 0, data: recursiveMulticallData})
            ).to.be.reverted
        })

        it('should propagate custom errors from inner calls', async () => {
            const { factory, pool } = await setupTests()
            const encodedUpgradeData = pool.interface.encodeFunctionData('upgradeImplementation')
            const encodedMulticallData = pool.interface.encodeFunctionData(
                'multicall(bytes[])',
                [ [encodedUpgradeData] ]
            )
            // implementation has not changed, so upgrade reverts with a custom error
            await expect(
                user1.sendTransaction({ to: pool.address, value: 0, data: encodedMulticallData})
            ).to.be.revertedWith("EUpgradeImplementationIsSameAsCurrent")
        })

        it('should support multicall with deadline', async () => {
            const { pool } = await setupTests()
            const encodedSetOwnerData = pool.interface.encodeFunctionData('setOwner', [user2.address])
            const encodedMulticallData = pool.interface.encodeFunctionData(
                'multicall(uint256,bytes[])',
                [MaxUint256, [encodedSetOwnerData]]
            )
            await expect(
                user1.sendTransaction({ to: pool.address, value: 0, data: encodedMulticallData})
            ).to.emit(pool, "NewOwner").withArgs(user1.address, user2.address)
        })

        it('should support multicall with previousBlockhash', async () => {
            const { pool } = await setupTests()
            const previousBlock = await waffle.provider.getBlock('latest')
            const encodedSetOwnerData = pool.interface.encodeFunctionData('setOwner', [user2.address])
            const encodedMulticallData = pool.interface.encodeFunctionData(
                'multicall(bytes32,bytes[])',
                [previousBlock.hash, [encodedSetOwnerData]]
            )
            await expect(
                user1.sendTransaction({ to: pool.address, value: 0, data: encodedMulticallData})
            ).to.emit(pool, "NewOwner").withArgs(user1.address, user2.address)
        })
    })
})
