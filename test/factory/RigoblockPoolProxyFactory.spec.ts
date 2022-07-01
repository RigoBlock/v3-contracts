import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { BigNumber, Contract } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { getAddress } from "ethers/lib/utils";

describe("ProxyFactory", async () => {
    const setupTests = deployments.createFixture(
      async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const RigoblockPoolProxyFactory = await deployments.get('RigoblockPoolProxyFactory')
        return { RigoblockPoolProxyFactory }
    });

    describe("createDrago", async () => {
        it('should revert with space before pool name', async () => {
            const factoryAddress = await setupTests()
            const factoryInstance = await hre.ethers.getContractAt(
                "RigoblockPoolProxyFactory",
                // TODO: fix following as factory address will change if factory code changes
                '0xbe630fE37079781C4c28D8ea43f2D34525a53C36' //rigoblockPoolProxyFactory.address
            )
            //console.log(factoryInstance.address)
            await expect(
                factoryInstance.createDrago(' testpool', 'TEST')
            ).to.be.revertedWith("Transaction reverted without a reason")
        })

        it('should revert with symbol before pool name', async () => {
            const factoryAddress = await setupTests()
            const factoryInstance = await hre.ethers.getContractAt(
                "RigoblockPoolProxyFactory",
                // TODO: fix following as factory address will change if factory code changes
                '0xbe630fE37079781C4c28D8ea43f2D34525a53C36' //rigoblockPoolProxyFactory.address
            )
            await expect(
                factoryInstance.createDrago('testpool', ' TEST')
            ).to.be.revertedWith("Transaction reverted without a reason")
        })
    })
})
