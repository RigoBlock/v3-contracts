import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { ProposedAction, TimeType } from "../utils/utils";

describe("Governance Implementation", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('governance-tests')
        const ImplementationInstance = await deployments.get("RigoblockGovernance")
        const Implementation = await hre.ethers.getContractFactory("RigoblockGovernance")
        return {
            implementation: Implementation.attach(ImplementationInstance.address)
        }
    });

    describe("propose", async () => {
        it('should revert with direct call', async () => {
            const { implementation } = await setupTests()
            const mockBytes = hre.ethers.utils.formatBytes32String('mock')
            const action = new ProposedAction(user2.address, mockBytes, 0)
            await expect(implementation.propose([action],'this proposal should always fail'))
                .to.be.reverted
        })
    })

    describe("castVote", async () => {
        it('should revert with direct call', async () => {
            const { implementation } = await setupTests()
            await expect(
                implementation.castVote(1, 1)
            ).to.be.reverted
        })
    })

    describe.skip("castVoteBySignature", async () => {
        it('should revert with direct call', async () => {
            const { implementation } = await setupTests()
            await expect(
                implementation.castVoteBySignature(1)
            ).to.be.reverted
        })
    })

    describe("execute", async () => {
        it('should revert with direct call', async () => {
            const { implementation } = await setupTests()
            await expect(
                implementation.execute(0)
            ).to.be.reverted
        })
    })

    describe("upgradeImplementation", async () => {
        it('should revert with direct call', async () => {
            const { implementation } = await setupTests()
            await expect(
                implementation.upgradeImplementation(user2.address)
            ).to.be.revertedWith("GOV_UPGRADE_APPROVAL_ERROR")
        })
    })

    describe("updateThresholds", async () => {
        it('should revert with direct call', async () => {
            const { implementation } = await setupTests()
            await expect(
                implementation.updateThresholds(1, 1)
            ).to.be.revertedWith("GOV_UPGRADE_APPROVAL_ERROR")
        })
    })

    describe("initializeGovernance", async () => {
        it('should revert with direct call', async () => {
            const { implementation } = await setupTests()
            await expect(
                implementation.initializeGovernance()
            ).to.be.revertedWith("ALREADY_INITIALIZED_ERROR")
        })
    })

    describe("updateGovernanceStrategy", async () => {
        it('should revert with direct call', async () => {
            const { implementation } = await setupTests()
            await expect(
                implementation.updateGovernanceStrategy(user2.address)
            ).to.be.revertedWith("GOV_UPGRADE_APPROVAL_ERROR")
        })
    })
})
