import { expect } from "chai";
import hre, { deployments, waffle } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";

describe("AUniswap", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        const AuthorityInstance = await deployments.get("Authority")
        const Authority = await hre.ethers.getContractFactory("Authority")
        const authority = Authority.attach(AuthorityInstance.address)
        // we never call uniswap adapter directly, therefore do not attach to ABI
        const AUniswapInstance = await deployments.get("AUniswap")
        await authority.setAdapter(AUniswapInstance.address, true)
        // "49404b7c": "unwrapWETH9(uint256,address)",
        // "1c58db4f": "wrapETH(uint256)"
        await authority.addMethod("0x49404b7c", AUniswapInstance.address)
        await authority.addMethod("0x1c58db4f", AUniswapInstance.address)
        const factory = Factory.attach(RigoblockPoolProxyFactory.address)
        const { newPoolAddress } = await factory.callStatic.createPool(
            'testpool',
            'TEST',
            AddressZero
        )
        await factory.createPool('testpool','TEST',AddressZero)
        const Univ3RouterInstance = await deployments.get("MockUniswapRouter");
        const Univ3Router = await hre.ethers.getContractFactory("MockUniswapRouter")
        const univ3Router = Univ3Router.attach(Univ3RouterInstance.address)
        const Univ3Npm = await hre.ethers.getContractFactory("MockUniswapNpm")
        const univ3NpmAddress = await univ3Router.positionManager()
        return {
            aUniswap: AUniswapInstance.address,
            authority,
            newPoolAddress,
            univ3Npm: Univ3Npm.attach(univ3NpmAddress),
        }
    })

    describe("unwrapWETH9", async () => {
        it('should call WETH contract', async () => {
            const { authority, aUniswap, newPoolAddress } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            const amount = parseEther("100")
            await user1.sendTransaction({ to: newPoolAddress, value: amount})
            await pool.wrapETH(amount)
            expect(await hre.ethers.provider.getBalance(newPoolAddress)).to.be.eq(0)
            const rogueRecipient = user2.address
            const rogueBalance = await hre.ethers.provider.getBalance(rogueRecipient)
            let encodedUnwrapData
            const unwrapAmount = 50
            encodedUnwrapData = pool.interface.encodeFunctionData(
                'unwrapWETH9(uint256,address)',
                [unwrapAmount, rogueRecipient]
            )
            await expect(authority.addMethod("0x49404b7c", aUniswap)).to.be.revertedWith("SELECTOR_EXISTS_ERROR")
            await user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedUnwrapData})
            // unwrapped token returned to pool regardless recipient input
            expect(await hre.ethers.provider.getBalance(rogueRecipient)).to.be.eq(rogueBalance)
            expect(await hre.ethers.provider.getBalance(newPoolAddress)).to.be.eq(unwrapAmount)
            encodedUnwrapData = pool.interface.encodeFunctionData(
                'unwrapWETH9(uint256)',
                [50]
            )
            await authority.addMethod("0x49616997", aUniswap)
            await user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedUnwrapData})
        })
    })
})
