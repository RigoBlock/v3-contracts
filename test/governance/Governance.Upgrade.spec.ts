import { expect } from "chai";
import { BigNumber } from "ethers";
import hre, { deployments, waffle, ethers } from "hardhat";
import { parseEther } from "@ethersproject/units";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
//import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
//import { getAddress } from "ethers/lib/utils";
import { timeTravel } from "../utils/utils";
import { ProposedAction, StakeInfo, StakeStatus, TimeType } from "../utils/utils";

describe("Governance Upgrades", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()
    const mockBytes = hre.ethers.utils.formatBytes32String('mock')
    const mockAddress = user2.address
    const description = 'gov proposal one'

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('governance-tests')
        const StakingInstance = await deployments.get("StakingProxy")
        const Staking = await hre.ethers.getContractFactory("Staking")
        const GovernanceFactoryInstance = await deployments.get("RigoblockGovernanceFactory")
        const GovernanceFactory = await hre.ethers.getContractFactory("RigoblockGovernanceFactory")
        const ImplementationInstance = await deployments.get("RigoblockGovernance")
        const StrategyInstance = await deployments.get("RigoblockGovernanceStrategy")
        const governanceFactory = GovernanceFactory.attach(GovernanceFactoryInstance.address)
        const governance = await governanceFactory.callStatic.createGovernance(
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
        const MockOwned = await hre.ethers.getContractFactory("MockOwned")
        const mockPool = await MockOwned.deploy()
        const AuthorityInstance = await deployments.get("Authority")
        const Authority = await hre.ethers.getContractFactory("Authority")
        const authority = Authority.attach(AuthorityInstance.address)
        await authority.setFactory(user1.address, true)
        const RegistryInstance = await deployments.get("PoolRegistry")
        const Registry = await hre.ethers.getContractFactory("PoolRegistry")
        const registry = Registry.attach(RegistryInstance.address)
        const poolAddress = mockPool.address
        await registry.register(poolAddress, 'mock pool', 'MOCK', mockBytes)
        const GrgTokenInstance = await deployments.get("RigoToken")
        const GrgToken = await hre.ethers.getContractFactory("RigoToken")
        const GrgTransferProxyInstance = await deployments.get("ERC20Proxy")
        return {
            staking: Staking.attach(StakingInstance.address),
            governanceInstance: Implementation.attach(governance),
            grgToken: GrgToken.attach(GrgTokenInstance.address),
            grgTransferProxyAddress: GrgTransferProxyInstance.address,
            poolId: mockBytes,
            governance,
            poolAddress
        }
    });

    describe("upgradeImplementation", async () => {
        it('should revert with direct call', async () => {
            const { governanceInstance } = await setupTests()
            await expect(
                governanceInstance.upgradeImplementation(user2.address)
            ).to.be.revertedWith("GOV_UPGRADE_APPROVAL_ERROR")
        })
    })

    describe("upgradeThresholds", async () => {
        it('should revert with direct call', async () => {
            const { governanceInstance } = await setupTests()
            await expect(
                governanceInstance.updateThresholds(1, 1)
            ).to.be.revertedWith("GOV_UPGRADE_APPROVAL_ERROR")
        })
    })

    describe("updateGovernanceStrategy", async () => {
        it('should revert with direct call', async () => {
            const { governanceInstance } = await setupTests()
            await expect(
                governanceInstance.updateGovernanceStrategy(user2.address)
            ).to.be.revertedWith("GOV_UPGRADE_APPROVAL_ERROR")
        })
    })
})
