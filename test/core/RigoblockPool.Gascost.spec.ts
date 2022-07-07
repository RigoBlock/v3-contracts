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
        return {
          factory: Factory.attach(RigoblockPoolProxyFactory.address),
          registry: Registry.attach(ResitryInstance.address)
        }
    });

    describe("calculateCost", async () => {
        it('should create pool with space not first or last character', async () => {
            const { factory, registry } = await setupTests()
            const txReceipt = await factory.createPool('t est pool', 'TEST')
            const [ user1 ] = waffle.provider.getWallets()
            const result = await txReceipt.wait()
            const gasCost = result.cumulativeGasUsed.toNumber()
            console.log(gasCost)
            // TODO: actual size will be affected by tests coverage
            expect(gasCost).to.be.lt(700000)
        })
    })
})
