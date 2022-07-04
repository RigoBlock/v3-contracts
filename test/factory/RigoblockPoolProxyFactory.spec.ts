import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { BigNumber, Contract } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { getAddress } from "ethers/lib/utils";

describe("ProxyFactory", async () => {
    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        return {
          factory: Factory.attach(RigoblockPoolProxyFactory.address),
          addresslog: RigoblockPoolProxyFactory.address
        }
    });

    describe("createDrago", async () => {
        it('should revert with space before pool name', async () => {
            const { factory, addresslog } = await setupTests()
            // TODO: factory address should not change with deterministic deployment
            console.log(addresslog)
            await expect(
                factory.createDrago(' testpool2', 'TEST2')
            ).to.be.revertedWith("Transaction reverted without a reason")
        })

        it('should revert with space before pool symbol', async () => {
            const { factory } = await setupTests()
            await expect(
                factory.createDrago('testpool3', ' TEST3')
            ).to.be.revertedWith("Transaction reverted without a reason")
        })

        it('should create address when creating pool', async () => {
            const { factory } = await setupTests()
            const poolAddress = await factory.createDrago('testpool', 'TEST')
            expect(poolAddress).to.be.not.eq(AddressZero)
        })
    })
})
