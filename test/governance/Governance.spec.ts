import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import { BigNumber } from "ethers";
import "@nomiclabs/hardhat-ethers";
import { signEip712Message } from "../utils/eip712sig";
import { ProposedAction, TimeType, VoteType } from "../utils/utils";

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
            const action = new ProposedAction(user2.address, mockBytes, BigNumber.from('0'))
            // will revert as strategy is set to address 0, therefore is not able to return voting power
            await expect(implementation.propose([action],'this proposal should always fail'))
                .to.be.revertedWith("Transaction reverted: function returned an unexpected amount of data")
        })
    })

    describe("castVote", async () => {
        it('should revert with direct call', async () => {
            const { implementation } = await setupTests()
            const proposalId = 1
            const voteType = VoteType.Abstain
            // we won't be able to vote as no proposal can exist on the implementation
            await expect(
                implementation.castVote(proposalId, voteType)
            ).to.be.revertedWith("VOTING_PROPOSAL_ID_ERROR")
        })
    })

    describe("castVoteBySignature", async () => {
        it('should revert with direct call', async () => {
            const { implementation } = await setupTests()
            const proposalId = 1
            const voteType = VoteType.Abstain
            const { signature, domain, types, value} = await signEip712Message({
                governance: implementation.address,
                proposalId: proposalId,
                voteType: voteType
            })
            const { v, r, s } = hre.ethers.utils.splitSignature(signature)
            // we won't be able to vote as no proposal can exist on the implementation
            await expect(
                implementation.connect(user2).castVoteBySignature(proposalId, voteType, v, r ,s)
            ).to.be.revertedWith("VOTING_PROPOSAL_ID_ERROR")
        })
    })

    describe("execute", async () => {
        it('should revert with direct call', async () => {
            const { implementation } = await setupTests()
            // we will never be able to execute a proposal that does not exist
            const proposalId = 1
            await expect(
                implementation.execute(proposalId)
            ).to.be.revertedWith("VOTING_PROPOSAL_ID_ERROR")
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

    describe("upgradeStrategy", async () => {
        it('should revert with direct call', async () => {
            const { implementation } = await setupTests()
            await expect(
                implementation.upgradeStrategy(user2.address)
            ).to.be.revertedWith("GOV_UPGRADE_APPROVAL_ERROR")
        })
    })
})
