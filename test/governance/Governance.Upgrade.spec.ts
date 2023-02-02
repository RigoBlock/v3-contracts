import { expect } from "chai";
import { BigNumber } from "ethers";
import hre, { deployments, waffle, ethers } from "hardhat";
import { parseEther } from "@ethersproject/units";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { timeTravel } from "../utils/utils";
import { ProposedAction, StakeInfo, StakeStatus, TimeType, VoteType } from "../utils/utils";

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
        const GrgTransferProxy = await hre.ethers.getContractFactory("ERC20Proxy")
        // we do the setup for creating a proposal, which will be executable during voting epoch as voting from only staker with quorum
        const amount = parseEther("1000000")
        const grgToken = GrgToken.attach(GrgTokenInstance.address)
        const grgTransferProxy = GrgTransferProxy.attach(GrgTransferProxyInstance.address)
        await grgToken.approve(grgTransferProxy.address, amount)
        const staking = Staking.attach(StakingInstance.address)
        await staking.stake(amount)
        await staking.createStakingPool(poolAddress)
        const poolId = mockBytes
        const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId)
        const toInfo = new StakeInfo(StakeStatus.Delegated, poolId)
        await staking.moveStake(fromInfo, toInfo, amount)
        await timeTravel({ days: 14, mine:true })
        await staking.endEpoch()
        return {
            governanceInstance: Implementation.attach(governance),
            implementation: ImplementationInstance.address,
            staking
        }
    });

    describe("upgradeImplementation", async () => {
        it('should revert if not called by governance itself', async () => {
            const { governanceInstance } = await setupTests()
            await expect(
                governanceInstance.upgradeImplementation(user2.address)
            ).to.be.revertedWith("GOV_UPGRADE_APPROVAL_ERROR")
        })

        it('should revert if new implementation same as current', async () => {
            const { governanceInstance, staking, implementation } = await setupTests()
            const data = governanceInstance.interface.encodeFunctionData('upgradeImplementation(address)', [implementation])
            const action = new ProposedAction(governanceInstance.address, data, BigNumber.from('0'))
            await governanceInstance.propose([action], description)
            expect(await governanceInstance.proposalCount()).to.be.eq(1)
            await timeTravel({ days: 14, mine:true })
            await staking.endEpoch()
            await governanceInstance.castVote(1, VoteType.For)
            await expect(governanceInstance.execute(1)).to.be.revertedWith("UPGRADE_SAME_AS_CURRENT_ERROR")
        })

        it('should revert if target not contract', async () => {
            const { governanceInstance, staking } = await setupTests()
            const data = governanceInstance.interface.encodeFunctionData('upgradeImplementation(address)', [user2.address])
            const action = new ProposedAction(governanceInstance.address, data, BigNumber.from('0'))
            await governanceInstance.propose([action], description)
            expect(await governanceInstance.proposalCount()).to.be.eq(1)
            await timeTravel({ days: 14, mine:true })
            await staking.endEpoch()
            await governanceInstance.castVote(1, VoteType.For)
            await expect(governanceInstance.execute(1)).to.be.revertedWith("UPGRADE_NOT_CONTRACT_ERROR")
        })

        it('should upgrade implementation', async () => {
            const { governanceInstance, staking } = await setupTests()
            const data = governanceInstance.interface.encodeFunctionData('upgradeImplementation(address)', [staking.address])
            const action = new ProposedAction(governanceInstance.address, data, BigNumber.from('0'))
            await governanceInstance.propose([action], description)
            expect(await governanceInstance.proposalCount()).to.be.eq(1)
            await timeTravel({ days: 14, mine:true })
            await staking.endEpoch()
            await governanceInstance.castVote(1, VoteType.For)
            await expect(governanceInstance.execute(1)).to.emit(governanceInstance, "Upgraded").withArgs(staking.address)
        })
    })

    describe("upgradeThresholds", async () => {
        it('should revert if not called by governance itself', async () => {
            const { governanceInstance } = await setupTests()
            await expect(
                governanceInstance.upgradeThresholds(1, 1)
            ).to.be.revertedWith("GOV_UPGRADE_APPROVAL_ERROR")
        })
    })

    describe("upgradeStrategy", async () => {
        it('should revert if not called by governance itself', async () => {
            const { governanceInstance } = await setupTests()
            await expect(
                governanceInstance.upgradeStrategy(user2.address)
            ).to.be.revertedWith("GOV_UPGRADE_APPROVAL_ERROR")
        })
    })
})
