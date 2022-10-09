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
            const { pool } = await setupTests()
            let owner = await pool.getStorageAt(2, 1)
            owner = utils.hexDataSlice(owner, 3, 23)
            expect(owner).to.be.eq((await pool.owner()).toLowerCase())
        })

        it('should read true unlocked boolean', async () => {
            const { pool } = await setupTests()
            let unlocked = await pool.getStorageAt(2, 1)
            unlocked = utils.hexDataSlice(unlocked, 2, 3)
            const encodedPack = utils.solidityPack(['bool'], [true])
            expect(unlocked).to.be.eq(encodedPack)
        })

        // a string shorter than 32 bytes is saved in location left-aligned and length is stored at the end.
        it('can read pool data', async () => {
            const { pool } = await setupTests()
            const poolStruct = await pool.getStorageAt(1, 3)
            // name stored in slot 1 with name length appended at last byte, se if we encode we also must append hex string length.
            const name = utils.hexDataSlice(poolStruct, 0, 32)
            // symbol is stored as bytes8 in order to be packed with other small units
            let symbol = utils.formatBytes32String("TEST")
            symbol = utils.hexDataSlice(symbol, 0, 8)
            const owner = await pool.owner()
            // EVM tickly packs tickls symbol, decimals, owner, unlocked into one uint256 slot
            const encodedPack = utils.solidityPack(
                ['bytes32', 'uint24', 'address', 'uint8', 'bytes8', 'uint256'],
                [name, 1, owner, 18, symbol, AddressZero]
            )
            expect(poolStruct).to.be.eq(encodedPack)
        })

        it('can read pool struct with different base token', async () => {
            const { factory } = await setupTests()
            const grgToken = (await deployments.get("RigoToken")).address
            const { newPoolAddress } = await factory.callStatic.createPool('test pool GRG', 'PDPG', grgToken)
            await factory.createPool('test pool GRG', 'PDPG', grgToken)
            const pool = await hre.ethers.getContractAt("RigoblockV3Pool", newPoolAddress)
            const poolStruct = await pool.getStorageAt(1, 3)
            // name stored in slot 1 with name length appended at last byte, se if we encode we also must append hex string length.
            const name = utils.hexDataSlice(poolStruct, 0, 32)
            // symbol is stored as bytes8 in order to be packed with other small units
            let symbol = utils.formatBytes32String("PDPG")
            symbol = utils.hexDataSlice(symbol, 0, 8)
            const owner = await pool.owner()
            // EVM tickly packs tickls symbol, decimals, owner, unlocked into one uint256 slot
            const encodedPack = utils.solidityPack(
                ['bytes32', 'uint24', 'address', 'uint8', 'bytes8', 'uint256'],
                [name, 1, owner, 18, symbol, grgToken]
            )
            expect(poolStruct).to.be.eq(encodedPack)
        })

        it('can read pool parameters', async () => {
            const { pool } = await setupTests()
            // next storage slot is 4 since Pool has 2 slots reserved in it.
            let poolParams = await pool.getStorageAt(4, 2)
            // we are packing 5 elements, but EVM adds null uint16 to compress 4 elements in first slot
            let encodedPack = utils.solidityPack(
                ['uint16', 'uint48', 'uint16', 'uint16', 'uint160', 'uint256'],
                [0, 0, 0, 0, AddressZero, AddressZero]
            )
            // we assert we are comparing same length null arrays first
            expect(poolParams).to.be.eq(encodedPack)
            await pool.changeMinPeriod(1234)
            await pool.changeSpread(445)
            await pool.setTransactionFee(67)
            await pool.changeFeeCollector(user2.address)
            await pool.setKycProvider(pool.address)
            poolParams = await pool.getStorageAt(4, 2)
            // EVM tightly encodes struct as following, adding 2 null bytes to fill first uint256 slot
            encodedPack = utils.solidityPack(
                ['uint16', 'uint160', 'uint16', 'uint16', 'uint48','uint256'],
                [0, user2.address, 67, 445, 1234, pool.address]
            )
            expect(poolParams).to.be.eq(encodedPack)
        })

        it('can read pool tokens struct', async () => {
            const { pool } = await setupTests()
            // next storage slot is 6 since PoolParams has 2 slots reserved in it.
            let poolParams = await pool.getStorageAt(6, 2)
            // unitary value null in pool storage until set, total supply null until first mint
            let encodedPack = utils.solidityPack(
                ['uint256', 'uint256'],
                [0, 0]
            )
            expect(poolParams).to.be.eq(encodedPack)
            await pool.mint(user2.address, parseEther("10"), 1, { value: parseEther("10") })
            await pool.setUnitaryValue(parseEther("1.1"))
            poolParams = await pool.getStorageAt(6, 2)
            encodedPack = utils.solidityPack(
                ['uint256', 'uint256'],
                [parseEther("1.1"), parseEther("9.5")]
            )
            expect(poolParams).to.be.eq(encodedPack)
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

        it('can read owner', async () => {
            const { pool } = await setupTests()
            let owner = await pool.getStorageSlotsAt([2])
            owner = utils.hexDataSlice(owner, 3, 23)
            const encodedPack = utils.solidityPack(['address'], [await pool.owner()])
            expect(owner).to.be.eq(encodedPack)
        })

        it('can read slots from different structs', async () => {
            const { factory } = await setupTests()
            const grgToken = (await deployments.get("RigoToken")).address
            const { newPoolAddress } = await factory.callStatic.createPool('test pool GRG', 'PDPG', grgToken)
            await factory.createPool('test pool GRG', 'PDPG', grgToken)
            const pool = await hre.ethers.getContractAt("RigoblockV3Pool", newPoolAddress)
            const returnString = await pool.getStorageSlotsAt([
                '0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50',
                3
            ])
            const encodedPack = utils.solidityPack(
                ['uint256', 'uint256'],
                [factory.address, (await pool.getData()).baseToken]
            )
            expect(returnString).to.be.eq(encodedPack)
        })

        it('returns name', async () => {
            const { pool } = await setupTests()
            const name = await pool.getStorageSlotsAt([1])
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
            // EVM packs symbol with unlocked, owner, decimals
            const symbolSlot = await pool.getStorageSlotsAt([2])
            // symbol is bytes8, we only take the first 4 to eliminate padding.
            let symbol = utils.hexDataSlice(symbolSlot, 24, 32)
            symbol = utils.toUtf8String(symbol)
            // slot stores symbol as bytes8, which is returned with padding
            expect(symbol).to.be.eq('TEST\u0000\u0000\u0000\u0000')
            // in order to comparing storage symbol, we must get rid of padding
            let poolSymbol = await pool.symbol()
            expect(poolSymbol).to.be.eq('TEST')
            //poolSymbol = utils.toUtf8Bytes(poolSymbol)
            //poolSymbol = utils.hexlify(poolSymbol)
            // symbol is bytes8, poolSymbol must have same length for comparing
            //poolSymbol = utils.hexDataSlice(poolSymbol, 0, 8)
            //poolSymbol = utils.toUtf8String(poolSymbol)
            //expect(symbol).to.be.eq(poolSymbol)
        })

        it('can read selected struct data', async () => {
            const { factory } = await setupTests()
            // we later want to check symbol length for 3-char symbol, creating new pool
            const { newPoolAddress } = await factory.callStatic.createPool('my new pool', 'PAL', AddressZero)
            await factory.createPool('my new pool', 'PAL', AddressZero)
            const pool = await hre.ethers.getContractAt("RigoblockV3Pool", newPoolAddress)
            const returnString = await pool.getStorageSlotsAt([1, 2, 3, 5, 7])
            const decodedData = hre.ethers.utils.AbiCoder.prototype.decode(
                [ "bytes32", "bytes32", "address", "address", "uint256" ],
                returnString
            )
            // TODO: following values are both null in current pool, must test with non-null values
            expect(decodedData[3]).to.be.eq((await pool.getData()).baseToken)
            expect(decodedData[4]).to.be.eq(await pool.totalSupply())
            let name = decodedData[0]
            const nameLength = utils.hexDataSlice(name, 31, 32)
            const length = utils.arrayify(nameLength)[0] / 2
            name = utils.hexDataSlice(name, 0, length)
            name = utils.toUtf8String(name)
            expect(name).to.be.eq('my new pool')
            expect(name).to.be.eq(await pool.name())
            const symbolSlot = decodedData[1]
            let symbol = utils.hexDataSlice(symbolSlot, 24, 32)
            // symbol is an 8-bytes element
            let poolSymbol = await pool.symbol()
            expect(poolSymbol).to.be.eq('PAL')
            // must add padding to string
            expect(utils.toUtf8String(symbol)).to.be.eq("PAL\u0000\u0000\u0000\u0000\u0000")
        })
    })
})
