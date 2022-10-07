import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";

describe("EWhitelist", async () => {
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
            // slot0 = mapping(address => UserAccount) userAccounts
            // TODO: because first slot is a mapping, it could overwrite the UserAccounts storage if pool address = token address
            // this will happen if whitelisted token = pool, which should never happen unless pools can buy other pools
            let slot0 = hre.ethers.utils.solidityPack(['uint256'], [AddressZero])
            expect(await pool.getStorageAt(0, 1)).to.be.eq(slot0)
            // we define a boolean as an array of zeroes ending with a 1
            const isWhitelisted = hre.ethers.utils.solidityPack(['uint256'], [1])
            const rigoToken = await deployments.get("RigoToken")
            // data location of mapping at slot 0 is keccak256(address(rigoToken) . uint256(0))
            // keccak256(abi.encode(rigoToken.address, slot))
            const tokenWhitelistSlot = '0x03de6a299bc35b64db5b38a8b5dbbc4bab6e4b5a493067f0fbe40d83350a610f'
            const encodedParams = hre.ethers.utils.solidityPack(['uint256', 'uint256'], [rigoToken.address, tokenWhitelistSlot])
            // each whitelisted token is allocated a different randomly-big-eough slot
            const tokenMappingSlot = hre.ethers.utils.keccak256(encodedParams)
            // we assert the storage slot is empty
            expect(await pool.getStorageAt(tokenMappingSlot, 1)).to.be.not.eq(isWhitelisted)
            pool = EWhitelist.attach(newPoolAddress)
            // an attack would entail successful governance takeover, i.e. control of majority of GRG active voting power,
            // setting attacker address as whitelist, then setting a pool as whitelister, setting the "whitelistToken" selector
            // and finally overwriting storage. Because EWhitelist.slot(0) is a mapping, the new token would not be approved
            // in the whitelist contract, but at location n in the pool storage, which would not overwrite pool reserved storage
            // as the location is explicitly selected as a randomly-big-enough value.
            await authority.setAdapter(eWhitelist.address, true)
            await authority.setWhitelister(newPoolAddress, true)
            // "6247f6f2": "whitelistToken(uint256)"
            await authority.addMethod("0x6247f6f2", eWhitelist.address)
            await pool.whitelistToken(rigoToken.address)
            // pool will not be able to whitelist tokens.
            expect(await eWhitelist.isWhitelistedToken(rigoToken.address)).to.be.not.eq(true)
            // "ab37f486": "isWhitelistedToken(address)"
            await authority.addMethod("0xab37f486", eWhitelist.address)
            // pool will be able to whitelist token in its own storage.
            expect(await pool.isWhitelistedToken(rigoToken.address)).to.be.eq(true)
            pool = await hre.ethers.getContractAt("RigoblockV3Pool", newPoolAddress)
            // owner should never be affected
            expect(await pool.owner()).to.be.eq(user1.address)
            // slot0 is reserved for mapping and always empty
            expect(await pool.getStorageAt(0, 1)).to.be.eq(slot0)
            // pool has overwritten to its own storage in a slot that is otherwise not used.
            expect(await pool.getStorageAt(tokenMappingSlot, 1)).to.be.eq(isWhitelisted)
            pool = await hre.ethers.getContractAt("AUniswap", newPoolAddress)
            const AUniswapInstance = await deployments.get("AUniswap")
            await authority.setAdapter(AUniswapInstance.address, true)
            await authority.addMethod("0x472b43f3", AUniswapInstance.address)
            const Weth = await hre.ethers.getContractFactory("WETH9")
            const weth = await Weth.deploy()
            await expect(pool.swapExactTokensForTokens(
                100,
                100,
                [rigoToken.address, weth.address],
                newPoolAddress
            )).to.be.revertedWith("AUNISWAP_TOKEN_NOT_WHITELISTED_ERROR")
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
