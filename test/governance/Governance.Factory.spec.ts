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
        it('should emit event when creating new governance', async () => {
            const { governanceFactory, implementation, strategy } = await setupTests()
            // TODO: check if we want to return error in valid parameters assertion
            const { governance } = await governanceFactory.callStatic.createGovernance(
                implementation,
                strategy,
                parseEther("100000"), // 100k GRG
                parseEther("500000"), // 500k GRG
                TimeType.Timestamp,
                'Rigoblock Governance'
            )
            console.log(governance)
            /*await expect(
                governanceFactory.createGovernance(
                    implementation,
                    strategy,
                    parseEther("100000"), // 100k GRG
                    parseEther("500000"), // 500k GRG
                    TimeType.Timestamp,
                    'Rigoblock Governance'
                )
            ).to.emit(governanceFactory, "GovernanceCreated").withArgs(governance)*/
        })
    })
})
