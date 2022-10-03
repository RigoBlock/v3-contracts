import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";

describe("AUniswap", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const AuthorityInstance = await deployments.get("Authority")
        const Authority = await hre.ethers.getContractFactory("Authority")
        const authority = Authority.attach(AuthorityInstance.address)
        const EWhitelist = await hre.ethers.getContractFactory("EWhitelist")
        const eWhitelist = await EWhitelist.deploy(authority.address)
        return {
            authority,
            EWhitelist,
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

        // since EWhitelist has its own storage, we want to assert that, even in the case of a malicious governance takeover,
        // a pool would not be able to overwrite whilist storage variable to own storage, i.e. overwrite slot(0), reserved for owner address.
        it('should revert where could overwrite storage', async () => {
            const { eWhitelist, EWhitelist, authority } = await setupTests()
            const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
            const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
            const factory = Factory.attach(RigoblockPoolProxyFactory.address)
            const { newPoolAddress } = await factory.callStatic.createPool('testpool', 'TEST', AddressZero)
            await factory.createPool('testpool', 'TEST', AddressZero)
            let pool = await hre.ethers.getContractAt("RigoblockV3Pool", newPoolAddress)
            expect(await pool.owner()).to.be.eq(user1.address)
            let poolOwner = hre.ethers.utils.solidityPack(['uint256'], [await pool.owner()])
            expect(await pool.getStorageAt(0, 1)).to.be.eq(poolOwner)
            // we define a boolean as an array of zeroes ending with a 1
            const isWhitelisted = hre.ethers.utils.solidityPack(['uint256'], [1])
            // data location of mapping at slot 0 is keccak256(address(rigoToken) . uint256(0))
            // keccak256(abi.encode(0x195E302c22386B08049e1C87fb793984C696Fe84, 0))
            const whitelistSlot = '0xb2baaf2d0a228f0e42ce70643c606fdf851c9556431029487799f3b600e6f932'
            expect(await pool.getStorageAt(whitelistSlot, 1)).to.be.not.eq(isWhitelisted)
            pool = EWhitelist.attach(newPoolAddress)
            // an attack would entail successful governance takeover, i.e. control of majority of GRG active voting power,
            // setting attacker address as whitelist, then setting a pool as whitelister, setting the "whitelistToken" selector
            // and finally overwriting storage. Because EWhitelist.slot(0) is a mapping, the new token would not be approved
            // in the whitelist contract, but at location n in the pool storage, which is not otherwise accessible as slot(0)
            // is reserved for the owner. While this is a possible attack, it is extremely expensive and would not have side effects.
            await authority.setAdapter(eWhitelist.address, true)
            await authority.setWhitelister(newPoolAddress, true)
            const rigoToken = await deployments.get("RigoToken")
            // "6247f6f2": "whitelistToken(uint256)"
            await authority.addMethod("0x6247f6f2", eWhitelist.address)
            await pool.whitelistToken(rigoToken.address)
            expect(await eWhitelist.isWhitelistedToken(rigoToken.address)).to.be.not.eq(true)
            pool = await hre.ethers.getContractAt("RigoblockV3Pool", newPoolAddress)
            expect(await pool.owner()).to.be.eq(user1.address)
            poolOwner = hre.ethers.utils.solidityPack(['uint256'], [await pool.owner()])
            expect(await pool.getStorageAt(0, 1)).to.be.eq(poolOwner)
            expect(await pool.getStorageAt(whitelistSlot, 1)).to.be.eq(isWhitelisted)
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
