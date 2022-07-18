import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { BigNumber, Contract } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { getAddress } from "ethers/lib/utils";

describe("ProxyGasCost", async () => {
    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        const ResitryInstance = await deployments.get("PoolRegistry")
        const Registry = await hre.ethers.getContractFactory("PoolRegistry")
        const RigoTokenInstance = await deployments.get("RigoToken")
        const RigoToken = await hre.ethers.getContractFactory("RigoToken")
        return {
            factory: Factory.attach(RigoblockPoolProxyFactory.address),
            registry: Registry.attach(ResitryInstance.address),
            grgToken: RigoToken.attach(RigoTokenInstance.address)
        }
    });

    describe("calculateCost", async () => {
        it('should create pool whose size is smaller than 500k gas', async () => {
            const { factory, registry } = await setupTests()
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
            const { factory, registry, grgToken } = await setupTests()
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
    })
})
