import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";

describe("AUniswap", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const AuthorityCoreInstance = await deployments.get("AuthorityCore")
        const AuthorityCore = await hre.ethers.getContractFactory("AuthorityCore")
        const authority = AuthorityCore.attach(AuthorityCoreInstance.address)
        const EWhitelist = await hre.ethers.getContractFactory("EWhitelist")
        const eWhitelist = await EWhitelist.deploy(authority.address)
        return {
            authority,
            eWhitelist
        }
    })

    describe("whitelistToken", async () => {
        it('should revert if caller not authorized', async () => {
            const { eWhitelist } = await setupTests()
            await expect(eWhitelist.connect(user2).whitelistToken(AddressZero))
                .to.be.revertedWith("EWHITELIST_CALLER_NOT_WHITELISTER_ERROR")
        })

        it('should revert if token already whitelisted', async () => {
            const { eWhitelist } = await setupTests()
            await expect(eWhitelist.whitelistToken(AddressZero))
                .to.emit(eWhitelist, "Whitelisted").withArgs(AddressZero, true)
            await expect(eWhitelist.whitelistToken(AddressZero))
                .to.be.revertedWith("EWHITELIST_TOKEN_ALREADY_WHITELISTED_ERROR")
        })
    })

    describe("removeToken", async () => {
        it('should revert if caller not authorized', async () => {
            const { eWhitelist } = await setupTests()
            await expect(eWhitelist.connect(user2).removeToken(AddressZero))
                .to.be.revertedWith("EWHITELIST_CALLER_NOT_WHITELISTER_ERROR")
        })

        it('should revert if token already whitelisted', async () => {
            const { eWhitelist } = await setupTests()
            await expect(eWhitelist.removeToken(AddressZero))
                .to.be.revertedWith("EWHITELIST_TOKEN_ALREADY_REMOVED_ERROR")
            await eWhitelist.whitelistToken(AddressZero)
            await expect(eWhitelist.removeToken(AddressZero))
                .to.emit(eWhitelist, "Whitelisted").withArgs(AddressZero, false)
            await expect(eWhitelist.removeToken(AddressZero))
                .to.be.revertedWith("EWHITELIST_TOKEN_ALREADY_REMOVED_ERROR")
        })
    })

    describe("batchUpdateTokens", async () => {
        it('should revert if caller not authorized', async () => {
            const { eWhitelist } = await setupTests()
            await expect(eWhitelist.connect(user2).batchUpdateTokens(
                [AddressZero, AddressZero],
                [true, true]
            )).to.be.revertedWith("EWHITELIST_CALLER_NOT_WHITELISTER_ERROR")
            // will revert as we are trying to whitelist the same token twice
            await expect(eWhitelist.batchUpdateTokens(
                [AddressZero, AddressZero],
                [true, true]
            )).to.be.revertedWith("EWHITELIST_TOKEN_ALREADY_WHITELISTED_ERROR")
            await expect(eWhitelist.batchUpdateTokens(
                [AddressZero, AddressZero],
                [true, false]
            )).to.emit(eWhitelist, "Whitelisted").withArgs(AddressZero, true)
            .to.emit(eWhitelist, "Whitelisted").withArgs(AddressZero, false)
            const Weth = await hre.ethers.getContractFactory("WETH9")
            const weth = await Weth.deploy()
            await expect(eWhitelist.batchUpdateTokens(
                [AddressZero, weth.address],
                [true, true]
            )).to.emit(eWhitelist, "Whitelisted").withArgs(AddressZero, true)
            .to.emit(eWhitelist, "Whitelisted").withArgs(weth.address, true)
        })
    })

    describe("getAuthority", async () => {
        it('should return authority address', async () => {
            const { eWhitelist, authority } = await setupTests()
            expect(await eWhitelist.connect(user2).getAuthority())
                .to.be.eq(authority.address)
        })
    })
})
