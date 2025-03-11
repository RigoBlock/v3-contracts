import { expect } from "chai";
import hre, { deployments, waffle } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";

describe("Authority", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const AuthorityInstance = await deployments.get("Authority")
        const Authority = await hre.ethers.getContractFactory("Authority")
        const authority = Authority.attach(AuthorityInstance.address)
        await authority.setWhitelister(user1.address, false);
        return {
            authority
        }
    });

    describe("addMethod", async () => {
        it('should revert if caller not whitelister', async () => {
            const { authority } = await setupTests()
            const selector = "0xa694fc3a"
            const adapter = user2.address
            await expect(
                authority.addMethod(selector, adapter)
            ).to.be.revertedWith("AUTHORITY_SENDER_NOT_WHITELISTER_ERROR")
        })

        it('should revert if adapter not whitelisted', async () => {
            const { authority } = await setupTests()
            const selector = "0xa694fc3a"
            const adapter = user2.address
            await authority.setWhitelister(user1.address, true)
            await expect(
                authority.addMethod(selector, adapter)
            ).to.be.revertedWith("ADAPTER_NOT_WHITELISTED_ERROR")
        })

        it('should whitelist method', async () => {
            const { authority } = await setupTests()
            const selector = "0xa694fc3a"
            const adapter = user2.address
            await authority.setWhitelister(user1.address, true)
            await authority.setAdapter(adapter, true)
            await expect(
                authority.addMethod(selector, adapter)
            ).to.emit(
                authority, "WhitelistedMethod"
            ).withArgs(user1.address, adapter, selector)
            expect(await authority.getApplicationAdapter(selector)).to.be.eq(adapter)
        })

        it('should revert if method already whitelisted', async () => {
            const { authority } = await setupTests()
            const selector = "0xa694fc3a"
            const adapter = user2.address
            await authority.setWhitelister(user1.address, true)
            await authority.setAdapter(adapter, true)
            await authority.addMethod(selector, adapter)
            await expect(
                authority.addMethod(selector, adapter)
            ).to.be.revertedWith("SELECTOR_EXISTS_ERROR")
        })
    })

    describe("removeMethod", async () => {
        it('should revert if caller not whitelister', async () => {
            const { authority } = await setupTests()
            const selector = "0xa694fc3a"
            const adapter = user2.address
            await expect(
                authority.connect(user2).removeMethod(selector, adapter)
            ).to.be.revertedWith("AUTHORITY_SENDER_NOT_WHITELISTER_ERROR")
        })

        it('should revert if method not whitelisted', async () => {
            const { authority } = await setupTests()
            await authority.setWhitelister(user2.address, true)
            const selector = "0xa694fc3a"
            const adapter = user2.address
            await expect(
                authority.connect(user2).removeMethod(selector, adapter)
            ).to.be.revertedWith("AUTHORITY_METHOD_NOT_APPROVED_ERROR")
        })

        it('should remove method', async () => {
            const { authority } = await setupTests()
            await authority.setWhitelister(user2.address, true)
            const selector = "0xa694fc3a"
            const adapter = user2.address
            await authority.setAdapter(adapter, true)
            await authority.connect(user2).addMethod(selector, adapter)
            await expect(
                authority.connect(user2).removeMethod(selector, adapter)
            ).to.emit(
                authority, "RemovedMethod"
            ).withArgs(user2.address, adapter, selector)
        })
    })

    describe("setWhitelister", async () => {
        it('should revert if caller not owner', async () => {
            const { authority } = await setupTests()
            await expect(
                authority.connect(user2).setWhitelister(user2.address, true)
            ).to.be.revertedWith("OWNED_CALLER_IS_NOT_OWNER_ERROR")
        })

        it('should revert with zero address input', async () => {
            const { authority } = await setupTests()
            await expect(
                authority.setWhitelister(AddressZero, true)
            ).to.be.revertedWith("AUTHORITY_TARGET_NULL_ADDRESS_ERROR")
        })

        it('should revert if adding already added whitelister', async () => {
            const { authority } = await setupTests()
            await authority.setWhitelister(user2.address, true)
            await expect(
                authority.setWhitelister(user2.address, true)
            ).to.be.revertedWith("ALREADY_WHITELISTED_ERROR")
        })

        it('should revert if removing non-added whitelister', async () => {
            const { authority } = await setupTests()
            await expect(
                authority.setWhitelister(user2.address, false)
            ).to.be.revertedWith("NOT_ALREADY_WHITELISTED")
        })

        it('should set whitelister', async () => {
            const { authority } = await setupTests()
            await expect(
                authority.setWhitelister(user2.address, true)
            ).to.emit(
                authority, "PermissionAdded"
            ).withArgs(user1.address, user2.address, Role.Whitelister)
        })

        it('should remove whitelister', async () => {
            const { authority } = await setupTests()
            await authority.setWhitelister(user2.address, true)
            await expect(
                authority.setWhitelister(user2.address, false)
            ).to.emit(
                authority, "PermissionRemoved"
            ).withArgs(user1.address, user2.address, Role.Whitelister)
        })
    })

    describe("setFactory", async () => {
        it('should revert if caller not owner', async () => {
            const { authority } = await setupTests()
            await expect(
                authority.connect(user2).setFactory(user2.address, true)
            ).to.be.revertedWith("OWNED_CALLER_IS_NOT_OWNER_ERROR")
        })

        it('should revert with zero address input', async () => {
            const { authority } = await setupTests()
            await expect(
                authority.setFactory(AddressZero, true)
            ).to.be.revertedWith("AUTHORITY_TARGET_NULL_ADDRESS_ERROR")
        })

        it('should revert if already whitelisted factory', async () => {
            const { authority } = await setupTests()
            await authority.setFactory(user2.address, true)
            await expect(
                authority.setFactory(user2.address, true)
            ).to.be.revertedWith("ALREADY_WHITELISTED_ERROR")
        })

        it('should revert if removing non-whitelisted factory', async () => {
            const { authority } = await setupTests()
            await expect(
                authority.setFactory(user2.address, false)
            ).to.be.revertedWith("NOT_ALREADY_WHITELISTED")
        })

        it('should whitelist factory', async () => {
            const { authority } = await setupTests()
            await expect(
                authority.setFactory(user2.address, true)
            ).to.emit(
                authority, "PermissionAdded"
            ).withArgs(user1.address, user2.address, Role.Factory)
        })

        it('should remove factory', async () => {
            const { authority } = await setupTests()
            await authority.setFactory(user2.address, true)
            await expect(
                authority.setFactory(user2.address, false)
            ).to.emit(
                authority, "PermissionRemoved"
            ).withArgs(user1.address, user2.address, Role.Factory)
        })
    })

    describe("setAdapter", async () => {
        it('should revert if caller not owner', async () => {
            const { authority } = await setupTests()
            await expect(
                authority.connect(user2).setAdapter(user2.address, true)
            ).to.be.revertedWith("OWNED_CALLER_IS_NOT_OWNER_ERROR")
        })

        it('should revert with zero address input', async () => {
            const { authority } = await setupTests()
            await expect(
                authority.setAdapter(AddressZero, true)
            ).to.be.revertedWith("AUTHORITY_TARGET_NULL_ADDRESS_ERROR")
        })

        it('should revert if whitelisting already whitelisted adapter', async () => {
            const { authority } = await setupTests()
            await authority.setAdapter(user2.address, true)
            await expect(
                authority.setAdapter(user2.address, true)
            ).to.be.revertedWith("ALREADY_WHITELISTED_ERROR")
        })

        it('should revert if blacklisting non-whitelisted adapter', async () => {
            const { authority } = await setupTests()
            await expect(
                authority.setAdapter(user2.address, false)
            ).to.be.revertedWith("NOT_ALREADY_WHITELISTED")
        })

        it('should whitelist adapter', async () => {
            const { authority } = await setupTests()
            await expect(
                authority.setAdapter(user2.address, true)
            ).to.emit(
                authority, "PermissionAdded"
            ).withArgs(user1.address, user2.address, Role.Adapter)
            await expect(
                authority.setAdapter(user2.address, false)
            ).to.emit(
                authority, "PermissionRemoved"
            ).withArgs(user1.address, user2.address, Role.Adapter)
        })
    })
})

export enum Role {
    Adapter,
    Factory,
    Whitelister
}
