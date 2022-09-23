import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { getAddress } from "ethers/lib/utils";
import { utils } from "ethers";

describe("MixinStorageAccessible", async () => {
    const [ user1, user2, user3 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        const factory = Factory.attach(RigoblockPoolProxyFactory.address)
        const { newPoolAddress } = await factory.callStatic.createPool(
            'testpool',
            'TEST',
            AddressZero
        )
        await factory.createPool('testpool','TEST',AddressZero)
        const pool = await hre.ethers.getContractAt(
            "RigoblockV3Pool",
            newPoolAddress
        )
        return {
            factory,
            pool
        }
    });

    describe("getStorageAt", async () => {
        it('can read beacon', async () => {
            const { factory, pool } = await setupTests()
            const beaconSlot = '0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50'
            const beacon = await pool.getStorageAt(beaconSlot, 1)
            const encodedPack = utils.solidityPack(['address'], [factory.address])
            expect(beacon).to.be.eq(hre.ethers.utils.hexZeroPad(encodedPack, 32))
        })

        it('can read pool owner', async () => {
            const { factory, pool } = await setupTests()
            const owner = await pool.getStorageAt(0, 1)
            const encodedPack = utils.solidityPack(['address'], [await pool.owner()])
            expect(owner).to.be.eq(hre.ethers.utils.hexZeroPad(encodedPack, 32))
        })

        it('can read admin data', async () => {
            const { pool } = await setupTests()
            const adminData = await pool.getStorageAt(2, 3)
            const encodedPack = utils.solidityPack(
                ['address', 'address', 'address'],
                [AddressZero, AddressZero, AddressZero]
            )
            expect(adminData).to.be.eq(hre.ethers.utils.hexZeroPad(encodedPack, 96))
        })

        // TODO: reform pool data and move name and symbol to private variables (or internal) as strings are not encoded correctly by ethers
        it.skip('can read pool data', async () => {
            const { pool } = await setupTests()
            const poolData = await pool.getStorageAt(3, 8)
            //const name = utils.formatBytes32String('testpool')
            //const symbol = utils.formatBytes32String('TEST')
            const encodedPack = hre.ethers.utils.solidityPack(
                ['string', 'string', 'uint256', 'uint256', 'uint256', 'uint256', 'uint32', 'uint8'],
                ['testpool', 'TEST', 0, 0, 0, 0, 0, 0]
            )
            console.log(poolData)
            expect(poolData).to.be.eq(hre.ethers.utils.hexZeroPad(encodedPack, 256))
        })
    })
})
