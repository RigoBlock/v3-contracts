import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import { parseEther } from "@ethersproject/units";
import "@nomiclabs/hardhat-ethers";
//import { AddressZero } from "@ethersproject/constants";
//import { BigNumber, Contract } from "ethers";
//import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
//import { getAddress } from "ethers/lib/utils";
import { ProposedAction, TimeType } from "../utils/utils";

describe("Governance Proxy", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()
    const mockBytes = hre.ethers.utils.formatBytes32String('mock')
    const mockAddress = user2.address

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('governance-tests')
        const StakingInstance = await deployments.get("Staking")
        const Staking = await hre.ethers.getContractFactory("Staking")
        const GovernanceFactoryInstance = await deployments.get("RigoblockGovernanceFactory")
        const GovernanceFactory = await hre.ethers.getContractFactory("RigoblockGovernanceFactory")
        const ImplementationInstance = await deployments.get("RigoblockGovernance")
        const StrategyInstance = await deployments.get("RigoblockGovernanceStrategy")
        const governanceFactory = GovernanceFactory.attach(GovernanceFactoryInstance.address)
        const { governance } = await governanceFactory.callStatic.createGovernance(
            ImplementationInstance.address,
            StrategyInstance.address,
            parseEther("100000"), // 100k GRG
            parseEther("1000000"), // 1MM GRG
            TimeType.Timestamp,
            'Rigoblock Governance'
        )
        await governanceFactory.createGovernance(
            ImplementationInstance.address,
            StrategyInstance.address,
            parseEther("100000"), // 100k GRG
            parseEther("1000000"), // 1MM GRG
            TimeType.Timestamp,
            'Rigoblock Governance')
        const Implementation = await hre.ethers.getContractFactory("RigoblockGovernance")
        const mockBytes = hre.ethers.utils.formatBytes32String('mock')
        const mockAddress = user2.address
        const AuthorityInstance = await deployments.get("Authority")
        const Authority = await hre.ethers.getContractFactory("Authority")
        const authority = Authority.attach(AuthorityInstance.address)
        await authority.setFactory(user1.address, true)
        const RegistryInstance = await deployments.get("PoolRegistry")
        const Registry = await hre.ethers.getContractFactory("PoolRegistry")
        const registry = Registry.attach(RegistryInstance.address)
        await registry.register(mockAddress, 'mock pool', 'MOCK', mockBytes)
        return {
            staking: Staking.attach(StakingInstance.address),
            governanceInstance: Implementation.attach(governance),
            governance
        }
    });

    describe.skip("propose", async () => {
        it('should revert with direct call', async () => {
            const { governanceInstance } = await setupTests()
            const mockBytes = hre.ethers.utils.formatBytes32String('mock')
            const action = new ProposedAction(user2.address, mockBytes, 0)
            await expect(governanceInstance.propose([action],'this proposal should always fail'))
            await expect(
                governanceInstance.propose([action],'propose and see')
            ).to.be.revertedWith("reverted_without_a_reason")
        })
    })

    describe.skip("castVote", async () => {
        it('should revert with direct call', async () => {
            const { governanceInstance } = await setupTests()
            await expect(
                governanceInstance.castVote(1)
            ).to.be.revertedWith("reverted_without_a_reason")
        })
    })

    describe.skip("castVoteBySignature", async () => {
        it('should revert with direct call', async () => {
            const { governanceInstance } = await setupTests()
            await expect(
                governanceInstance.castVoteBySignature(1)
            ).to.be.revertedWith("reverted_without_a_reason")
        })
    })

    describe.skip("execute", async () => {
        it('should revert with direct call', async () => {
            const { governanceInstance } = await setupTests()
            await expect(
                governanceInstance.execute(1)
            ).to.be.revertedWith("reverted_without_a_reason")
        })
    })

    describe.skip("upgradeImplementation", async () => {
        it('should revert with direct call', async () => {
            const { governanceInstance } = await setupTests()
            await expect(
                governanceInstance.upgradeImplementation(user2.address)
            ).to.be.revertedWith("reverted_without_a_reason")
        })
    })

    describe.skip("upgradeThresholds", async () => {
        it('should revert with direct call', async () => {
            const { governanceInstance } = await setupTests()
            await expect(
                governanceInstance.upgradeThresholds(1, 1)
            ).to.be.revertedWith("reverted_without_a_reason")
        })
    })

    describe.skip("initialize", async () => {
        it('should revert with direct call', async () => {
            const { governanceInstance } = await setupTests()
            await expect(
                governanceInstance.initialize()
            ).to.be.revertedWith("reverted_without_a_reason")
        })
    })

    describe.skip("updateGovernanceStrategy", async () => {
        it('should revert with direct call', async () => {
            const { governanceInstance } = await setupTests()
            await expect(
                governanceInstance.updateGovernanceStrategy(1)
            ).to.be.revertedWith("reverted_without_a_reason")
        })
    })
})

//TODO:
//make a proposal
//vote on a proposal
//fail a proposal
//pass a proposal
//execute a proposal
//upgrade implementation
//upgrade thresholds
// update strategy
