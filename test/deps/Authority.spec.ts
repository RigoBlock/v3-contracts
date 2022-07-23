import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { BigNumber, Contract } from "ethers";
import { getAddress } from "ethers/lib/utils";

describe("Authority", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const AuthorityInstance = await deployments.get("AuthorityCore")
        const Authority = await hre.ethers.getContractFactory("AuthorityCore")
        const authority = Authority.attach(AuthorityInstance.address)
        await authority.setWhitelister(user1.address, false);
        return {
            authority
        }
    });

    describe("setAuthority", async () => {
        it('should revert if caller not owner', async () => {
            const { authority } = await setupTests()
            await expect(
                authority.connect(user2).setAuthority(user2.address, true)
            ).to.be.revertedWith("OWNED_CALLER_IS_NOT_OWNER_ERROR")
        })

        it('should revert if whitelisting already whitelisted authority', async () => {
            const { authority } = await setupTests()
            await authority.setAuthority(user2.address, true)
            await expect(
                authority.setAuthority(user2.address, true)
            ).to.be.revertedWith("ALREADY_WHITELISTED_ERROR")
        })

        it('should revert if blacklisting non-whitelisted authority', async () => {
            const { authority } = await setupTests()
            await expect(
                authority.setAuthority(user2.address, false)
            ).to.be.revertedWith("NOT_ALREADY_WHITELISTED")
        })

        it('should whitelist authority', async () => {
            const { authority } = await setupTests()
            await expect(
                authority.setAuthority(user2.address, true)
            ).to.emit(authority, "PermissionAdded").withArgs(user1.address, user2.address, Role.Authority)
        })

        it('should remove authority', async () => {
            const { authority } = await setupTests()
            await authority.setAuthority(user2.address, true)
            await expect(
                authority.setAuthority(user2.address, false)
            ).to.emit(authority, "PermissionRemoved").withArgs(user1.address, user2.address, Role.Authority)
        })
    })

    describe("setWhitelister", async () => {
        it('should revert if caller not owner', async () => {
            const { authority } = await setupTests()
            await expect(
                authority.connect(user2).setWhitelister(user2.address, true)
            ).to.be.revertedWith("OWNED_CALLER_IS_NOT_OWNER_ERROR")
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
            ).to.emit(authority, "PermissionAdded").withArgs(user1.address, user2.address, Role.Whitelister)
        })

        it('should remove whitelister', async () => {
            const { authority } = await setupTests()
            await authority.setWhitelister(user2.address, true)
            await expect(
                authority.setWhitelister(user2.address, false)
            ).to.emit(authority, "PermissionRemoved").withArgs(user1.address, user2.address, Role.Whitelister)
        })
    })

    describe("whitelistFactory", async () => {
        it('should revert if caller not owner', async () => {
            const { authority } = await setupTests()
            await expect(
                authority.connect(user2).whitelistFactory(user2.address, true)
            ).to.be.revertedWith("OWNED_CALLER_IS_NOT_OWNER_ERROR")
        })

        it('should revert if whitelisting already whitelisted adapter', async () => {
            const { authority } = await setupTests()
            await authority.whitelistFactory(user2.address, true)
            await expect(
                authority.whitelistFactory(user2.address, true)
            ).to.be.revertedWith("ALREADY_WHITELISTED_ERROR")
        })

        it('should revert if blacklisting non-whitelisted adapter', async () => {
            const { authority } = await setupTests()
            await expect(
                authority.whitelistFactory(user2.address, false)
            ).to.be.revertedWith("NOT_ALREADY_WHITELISTED")
        })

        it('should whitelist factory', async () => {
            const { authority } = await setupTests()
            await expect(
                authority.whitelistFactory(user2.address, true)
            ).to.emit(authority, "PermissionAdded").withArgs(user1.address, user2.address, Role.Factory)
        })

        it('should remove factory', async () => {
            const { authority } = await setupTests()
            await authority.whitelistFactory(user2.address, true)
            await expect(
                authority.whitelistFactory(user2.address, false)
            ).to.emit(authority, "PermissionRemoved").withArgs(user1.address, user2.address, Role.Factory)
        })
    })

    describe("whitelistAdapter", async () => {
        it('should revert if caller not owner', async () => {
            const { authority } = await setupTests()
            await expect(
                authority.connect(user2).whitelistAdapter(user2.address, true)
            ).to.be.revertedWith("OWNED_CALLER_IS_NOT_OWNER_ERROR")
        })

        it('should revert if whitelisting already whitelisted adapter', async () => {
            const { authority } = await setupTests()
            await authority.whitelistAdapter(user2.address, true)
            await expect(
                authority.whitelistAdapter(user2.address, true)
            ).to.be.revertedWith("ALREADY_WHITELISTED_ERROR")
        })

        it('should revert if blacklisting non-whitelisted adapter', async () => {
            const { authority } = await setupTests()
            await expect(
                authority.whitelistAdapter(user2.address, false)
            ).to.be.revertedWith("NOT_ALREADY_WHITELISTED")
        })

        it('should whitelist adapter', async () => {
            const { authority } = await setupTests()
            await expect(
                authority.whitelistAdapter(user2.address, true)
            ).to.emit(authority, "PermissionAdded").withArgs(user1.address, user2.address, Role.Adapter)
            await expect(
                authority.whitelistAdapter(user2.address, false)
            ).to.emit(authority, "PermissionRemoved").withArgs(user1.address, user2.address, Role.Adapter)
        })
    })

    describe("whitelistMethod", async () => {
        it('should revert if caller not whitelister', async () => {
            const { authority } = await setupTests()
            const selector = "0xa694fc3a"
            const adapter = user2.address
            await expect(
                authority.whitelistMethod(selector, adapter)
            ).to.be.revertedWith("AUTHORITY_SENDER_NOT_WHITELISTER_ERROR")
        })

        it('should revert if adapter not whitelisted', async () => {
            const { authority } = await setupTests()
            const selector = "0xa694fc3a"
            const adapter = user2.address
            await authority.setWhitelister(user1.address, true)
            await expect(
                authority.whitelistMethod(selector, adapter)
            ).to.be.revertedWith("ADAPTER_NOT_WHITELISTED_ERROR")
        })

        it('should whitelist method', async () => {
            const { authority } = await setupTests()
            const selector = "0xa694fc3a"
            const adapter = user2.address
            await authority.setWhitelister(user1.address, true)
            await authority.whitelistAdapter(adapter, true)
            await expect(
                authority.whitelistMethod(selector, adapter)
            ).to.emit(authority, "WhitelistedMethod").withArgs(selector, adapter)
            expect(await authority.getApplicationAdapter(selector)).to.be.eq(adapter)
        })
    })

    describe("setExtensionsAuthority", async () => {
        it('should revert if caller not owner', async () => {
            const { authority } = await setupTests()
            await expect(
                authority.connect(user2).setExtensionsAuthority(user2.address)
            ).to.be.revertedWith("OWNED_CALLER_IS_NOT_OWNER_ERROR")
            await expect(
                authority.setExtensionsAuthority(user2.address)
            ).to.emit(authority, "NewExtensionsAuthority").withArgs(user2.address)
            expect(await authority.getAuthorityExtensions()).to.be.eq(user2.address)
        })
    })
})

export enum Role {
    Adapter,
    Authority,
    Factory,
    Whitelister
}
