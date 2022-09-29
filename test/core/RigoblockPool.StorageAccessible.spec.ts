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
        await factory.createPool('testpool', 'TEST', AddressZero)
        const pool = await hre.ethers.getContractAt(
            "RigoblockV3Pool",
            newPoolAddress
        )
        return {
            factory,
            pool
        }
    });

    // this method is not useful when reading non-null uninitialized params (implementation defaults are used),
    //  i.e. 'unitaryValue', 'spread', 'minPeriod', 'decimals'
    describe("getStorageAt", async () => {
        it('can read beacon', async () => {
            const { factory, pool } = await setupTests()
            const beaconSlot = '0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50'
            const beacon = await pool.getStorageAt(beaconSlot, 1)
            const encodedPack = utils.solidityPack(['uint256'], [factory.address])
            expect(beacon).to.be.eq(encodedPack)
            // encoding as uint256 is same as later encoding as hexZeroPad
            //expect(beacon).to.be.eq(hre.ethers.utils.hexZeroPad(encodedPack, 32))
        })

        it('can read pool owner', async () => {
            const { factory, pool } = await setupTests()
            const owner = await pool.getStorageAt(0, 1)
            const encodedPack = utils.solidityPack(['address'], [await pool.owner()])
            expect(owner).to.be.eq(hre.ethers.utils.hexZeroPad(encodedPack, 32))
        })

        it('should read null locked boolean', async () => {
            const { factory, pool } = await setupTests()
            const locked = await pool.getStorageAt(1, 1)
            const encodedPack = utils.solidityPack(['bool'], [false])
            expect(locked).to.be.eq(hre.ethers.utils.hexZeroPad(encodedPack, 32))
        })

        it('can read admin data', async () => {
            const { pool } = await setupTests()
            const adminData = await pool.getStorageAt(2, 3)
            const encodedPack = utils.solidityPack(
                ['uint256', 'uint256', 'uint256'],
                [AddressZero, AddressZero, AddressZero]
            )
            expect(adminData).to.be.eq(encodedPack)
        })

        // There might be a bug in the solidity compiler, as both name and symbol bytes32 hex last byte are not null
        it('can read pool data', async () => {
            const { pool } = await setupTests()
            // next storage slot is 5 since slot 2 has 3 elements in it.
            const poolData = await pool.getStorageAt(5, 8)
            // this is how the variable should be stored
            let name = utils.formatBytes32String("testpool")
            let symbol = utils.formatBytes32String("TEST")
            let encodedPack = utils.solidityPack(
                ['uint256', 'uint256', 'uint256', 'uint256', 'uint256', 'uint256', 'uint256', 'uint256'],
                [name, symbol, 0, 0, 0, 0, 0, 0]
            )
            expect(poolData).to.be.not.eq(encodedPack)
            // this is how the variable is actually stored, with last byte overwritte (probably overlap)
            name = await hre.ethers.provider.getStorageAt(pool.address, 5)
            symbol = await hre.ethers.provider.getStorageAt(pool.address, 6)
            encodedPack = hre.ethers.utils.AbiCoder.prototype.encode(
                ["tuple(bytes32 name, bytes32 symbol, uint256 unitaryValue, uint256 spread, uint256 totalSupply, uint256 transactionFee, uint32 minPeriod, uint8 decimals)"],
                [{name: name, symbol: symbol, unitaryValue: 0, spread: 0, totalSupply: 0, transactionFee: 0, minPeriod: 0, decimals: 0}]
            )
            expect(poolData).to.be.eq(encodedPack)
        })
    })
})
