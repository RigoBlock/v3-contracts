import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import { parseEther } from "@ethersproject/units";
import "@nomiclabs/hardhat-ethers";
import { TimeType } from "../utils/utils";

describe("Governance Factory", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()
    const mockBytes = hre.ethers.utils.formatBytes32String('mock')
    const mockAddress = user2.address

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('governance-tests')
        const GovernanceFactoryInstance = await deployments.get("RigoblockGovernanceFactory")
        const GovernanceFactory = await hre.ethers.getContractFactory("RigoblockGovernanceFactory")
        const governanceFactory = GovernanceFactory.attach(GovernanceFactoryInstance.address)
        const ImplementationInstance = await deployments.get("RigoblockGovernance")
        const StrategyInstance = await deployments.get("RigoblockGovernanceStrategy")
        return {
            implementation: ImplementationInstance.address,
            strategy: StrategyInstance.address,
            governanceFactory
        }
    });

    describe("createGovernance", async () => {
        it('should not allow deploying governance if params verification fails', async () => {
            const { governanceFactory, implementation, strategy } = await setupTests()
            // will revert if strategy contract does not implement method assertValidInitParams
            await expect(
                governanceFactory.createGovernance(
                    implementation,
                    implementation,
                    parseEther("100000"),
                    parseEther("1000000"),
                    TimeType.Timestamp,
                    'Rigoblock Governance'
                )
            ).to.be.revertedWith('VM Exception while processing transaction: reverted with panic code 0x1')
            // will revert without reason if assertion in strategy contract fails
            await expect(
                governanceFactory.createGovernance(
                    implementation,
                    strategy,
                    parseEther("10000000"),
                    parseEther("1000000"),
                    TimeType.Timestamp,
                    'Rigoblock Governance'
                )
            ).to.be.revertedWith('VM Exception while processing transaction: reverted with panic code 0x1')
            await expect(
                governanceFactory.createGovernance(
                    implementation,
                    strategy,
                    parseEther("100000"),
                    parseEther("1000000"),
                    TimeType.Timestamp,
                    'Any Governance'
                )
            ).to.be.revertedWith('VM Exception while processing transaction: reverted with panic code 0x1')
        })

        it('should emit event when creating new governance', async () => {
            const { governanceFactory, implementation, strategy } = await setupTests()
            // inputs validation in rigoblock strategy reverts without error, but other strategies could revert with error
            const governance = await governanceFactory.callStatic.createGovernance(
                implementation,
                strategy,
                parseEther("100000"),
                parseEther("1000000"),
                TimeType.Timestamp,
                'Rigoblock Governance'
            )
            await expect(
                governanceFactory.createGovernance(
                    implementation,
                    strategy,
                    parseEther("100000"),
                    parseEther("1000000"),
                    TimeType.Timestamp,
                    'Rigoblock Governance'
                )
            ).to.emit(governanceFactory, "GovernanceCreated").withArgs(governance)
        })
    })
})
