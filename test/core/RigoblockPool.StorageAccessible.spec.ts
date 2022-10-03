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

        // a string shorter than 32 bytes is saved in location left-aligned and length is stored at the end.
        it('can read pool data', async () => {
            const { pool } = await setupTests()
            // next storage slot is 5 since slot 2 has 3 elements in it.
            const poolData = await pool.getStorageAt(5, 8)
            // this is how the encoded package
            let name = utils.formatBytes32String("testpool")
            let symbol = utils.formatBytes32String("TEST")
            let encodedPack = utils.solidityPack(
                ['uint256', 'uint256', 'uint256', 'uint256', 'uint256', 'uint256', 'uint256', 'uint256'],
                [name, symbol, 0, 0, 0, 0, 0, 0]
            )
            expect(poolData).to.be.not.eq(encodedPack)
            // this is how the variable is actually stored, with last byte overwritten (length) as it is a dynamic string
            name = await hre.ethers.provider.getStorageAt(pool.address, 5)
            symbol = await hre.ethers.provider.getStorageAt(pool.address, 6)
            encodedPack = hre.ethers.utils.AbiCoder.prototype.encode(
                ["tuple(bytes32 name, bytes32 symbol, uint256 unitaryValue, uint256 spread, uint256 totalSupply, uint256 transactionFee, uint32 minPeriod, uint8 decimals)"],
                [{name: name, symbol: symbol, unitaryValue: 0, spread: 0, totalSupply: 0, transactionFee: 0, minPeriod: 0, decimals: 0}]
            )
            expect(poolData).to.be.eq(encodedPack)
        })
    })

    describe("getStorageSlotsAt", async () => {
        it('can read beacon slot', async () => {
            const { factory, pool } = await setupTests()
            const beaconSlot = '0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50'
            const beacon = await pool.getStorageSlotsAt([beaconSlot])
            const encodedPack = utils.solidityPack(['uint256'], [factory.address])
            expect(beacon).to.be.eq(encodedPack)
        })

        it('can read owner slot', async () => {
            const { factory, pool } = await setupTests()
            const owner = await pool.getStorageSlotsAt([0])
            const encodedPack = utils.solidityPack(['uint256'], [await pool.owner()])
            expect(owner).to.be.eq(encodedPack)
        })

        it('can read multiple data', async () => {
            const { factory, pool } = await setupTests()
            const returnString = await pool.getStorageSlotsAt([
                '0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50',
                0
            ])
            const encodedPack = utils.solidityPack(['uint256', 'uint256'], [factory.address, await pool.owner()])
            expect(returnString).to.be.eq(encodedPack)
        })

        it('returns name', async () => {
            const { factory, pool } = await setupTests()
            const name = await pool.getStorageSlotsAt([5])
            // EVM stored string length at last byte if shorter than 31 bytes
            const nameLength = utils.hexDataSlice(name, 31, 32)
            const length = utils.arrayify(nameLength)[0] / 2
            // each character is 2 bytes long
            let nameHex = utils.hexDataSlice(name, 0, length)
            nameHex = utils.toUtf8String(nameHex)
            expect(await pool.name()).to.be.eq(nameHex)
        })

        it('returns symbol', async () => {
            const { factory, pool } = await setupTests()
            const symbol = await pool.getStorageSlotsAt([6])
            // EVM stored string length at last byte if shorter than 31 bytes
            const symbolLength = utils.hexDataSlice(symbol, 31, 32)
            const length = utils.arrayify(symbolLength)[0] / 2
            // each character is 2 bytes long
            let symbolHex = utils.hexDataSlice(symbol, 0, length)
            symbolHex = utils.toUtf8String(symbolHex)
            expect(symbolHex).to.be.eq(await pool.symbol())
        })

        it('can read selected struct data', async () => {
            const { factory, pool } = await setupTests()
            const returnString = await pool.getStorageSlotsAt([0, 3, 5, 6])
            const decodedData = hre.ethers.utils.AbiCoder.prototype.decode([ "address", "address", "bytes32", "bytes32" ], returnString)
            expect(decodedData[0]).to.be.eq(await pool.owner())
            expect(decodedData[1]).to.be.eq(AddressZero)
            const name = await pool.getStorageSlotsAt([5])
            const nameLength = utils.hexDataSlice(name, 31, 32)
            let length = utils.arrayify(nameLength)[0] / 2
            let nameHex = utils.hexDataSlice(name, 0, length)
            nameHex = utils.toUtf8String(nameHex)
            expect(await pool.name()).to.be.eq(nameHex)
            const symbol = await pool.getStorageSlotsAt([6])
            const symbolLength = utils.hexDataSlice(symbol, 31, 32)
            length = utils.arrayify(symbolLength)[0] / 2
            let symbolHex = utils.hexDataSlice(symbol, 0, length)
            symbolHex = utils.toUtf8String(symbolHex)
            expect(symbolHex).to.be.eq(await pool.symbol())
        })
    })
})
