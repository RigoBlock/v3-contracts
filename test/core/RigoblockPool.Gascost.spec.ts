import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber, Contract } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { getAddress } from "ethers/lib/utils";

describe("ProxyGasCost", async () => {
    const [ user1 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        const RigoTokenInstance = await deployments.get("RigoToken")
        const RigoToken = await hre.ethers.getContractFactory("RigoToken")
        return {
            factory: Factory.attach(RigoblockPoolProxyFactory.address),
            grgToken: RigoToken.attach(RigoTokenInstance.address)
        }
    });

    describe("calculateCost", async () => {
        it('should create pool whose size is smaller than 500k gas', async () => {
            const { factory } = await setupTests()
            const txReceipt = await factory.createPool(
                't est pool',
                'TEST',
                AddressZero
            )
            const result = await txReceipt.wait()
            const gasCost = result.cumulativeGasUsed.toNumber()
            console.log(gasCost,'pool with base coin')
            // actual size will be affected in tests coverage (+100K), will require updating
            expect(gasCost).to.be.lt(500000)
        })

        it('should cost less than 500k gas with base token', async () => {
            const { factory, grgToken } = await setupTests()
            const txReceipt = await factory.createPool(
                't est pool',
                'TEST',
                grgToken.address
            )
            const result = await txReceipt.wait()
            const gasCost = result.cumulativeGasUsed.toNumber()
            console.log(gasCost,'pool with base token')
            // actual size will be affected in tests coverage (+100K), will require updating
            expect(gasCost).to.be.lt(500000)
        })

        it('logs gas cost for eth pool mint', async () => {
            const { factory } = await setupTests()
            const { newPoolAddress } = await factory.callStatic.createPool(
                'testpool',
                'TEST',
                AddressZero
            )
            await factory.createPool('testpool', 'TEST', AddressZero)
            const pool = await hre.ethers.getContractAt(
                "SmartPool",
                newPoolAddress
            )
            const etherAmount = parseEther("1")
            let txReceipt = await pool.mint(
                user1.address,
                etherAmount,
                0,
                { value: etherAmount }
            )
            let result = await txReceipt.wait()
            let gasCost = result.cumulativeGasUsed.toNumber()
            console.log(gasCost,'first eth pool mint')
            txReceipt = await pool.mint(
                user1.address,
                etherAmount,
                0,
                { value: etherAmount }
            )
            result = await txReceipt.wait()
            gasCost = result.cumulativeGasUsed.toNumber()
            console.log(gasCost,'second eth pool mint')
        })

        it('logs gas cost for token pool mint', async () => {
            const { factory, grgToken } = await setupTests()
            const { newPoolAddress } = await factory.callStatic.createPool(
                'testpool',
                'TEST',
                grgToken.address
            )
            await factory.createPool('testpool', 'TEST', grgToken.address)
            const pool = await hre.ethers.getContractAt(
                "SmartPool",
                newPoolAddress
            )
            const etherAmount = parseEther("1")
            const numberOfMintOperations = 2
            await grgToken.approve(pool.address, etherAmount.mul(numberOfMintOperations))
            let txReceipt = await pool.mint(
                user1.address,
                etherAmount,
                0
            )
            let result = await txReceipt.wait()
            let gasCost = result.cumulativeGasUsed.toNumber()
            console.log(gasCost,'first token pool mint')
            txReceipt = await pool.mint(
                user1.address,
                etherAmount,
                0
            )
            result = await txReceipt.wait()
            gasCost = result.cumulativeGasUsed.toNumber()
            console.log(gasCost,'second token pool mint')
        })
    })
})
