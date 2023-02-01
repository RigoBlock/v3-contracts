import { expect } from "chai";
import { BigNumber } from "ethers";
import hre, { deployments, waffle, ethers } from "hardhat";
import { parseEther } from "@ethersproject/units";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
//import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
//import { getAddress } from "ethers/lib/utils";
import { timeTravel } from "../utils/utils";
import { ProposedAction, StakeInfo, StakeStatus, TimeType, VoteType } from "../utils/utils";

describe("Governance Proxy", async () => {
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

    describe("initializeGovernance", async () => {
        it('should always revert', async () => {
            const { governanceInstance } = await setupTests()
            await expect(
                governanceInstance.initializeGovernance()
            ).to.be.revertedWith("ALREADY_INITIALIZED_ERROR")
        })
    })

    describe("propose", async () => {
        it('should revert with null stake', async () => {
            const { governanceInstance } = await setupTests()
            const mockBytes = hre.ethers.utils.formatBytes32String('mock')
            const action = new ProposedAction(user2.address, mockBytes, BigNumber.from('0'))
            await expect(
                governanceInstance.propose([action],'gov proposal one')
            ).to.be.revertedWith("GOV_LOW_VOTING_POWER")
        })

        it('should revert with empty actions', async () => {
            const { governanceInstance, grgToken, grgTransferProxyAddress, poolAddress, poolId, staking } = await setupTests()
            const amount = parseEther("100000")
            await grgToken.approve(grgTransferProxyAddress, amount)
            await staking.stake(amount)
            await staking.createStakingPool(poolAddress)
            const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId)
            const toInfo = new StakeInfo(StakeStatus.Delegated, poolId)
            await staking.moveStake(fromInfo, toInfo, amount)
            await timeTravel({ days: 14, mine:true })
            await staking.endEpoch()
            await expect(
                governanceInstance.propose([],'gov proposal one')
            ).to.be.revertedWith("GOV_NO_ACTIONS_ERROR")
        })

        it('can create invalid proposal', async () => {
            const { governanceInstance, grgToken, grgTransferProxyAddress, poolAddress, poolId, staking } = await setupTests()
            const amount = parseEther("100000")
            await grgToken.approve(grgTransferProxyAddress, amount)
            await staking.stake(amount)
            await staking.createStakingPool(poolAddress)
            const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId)
            const toInfo = new StakeInfo(StakeStatus.Delegated, poolId)
            await staking.moveStake(fromInfo, toInfo, amount)
            await timeTravel({ days: 14, mine:true })
            await staking.endEpoch()
            const zeroBytes = hre.ethers.utils.formatBytes32String('')
            const action = new ProposedAction(AddressZero, zeroBytes, BigNumber.from('0'))
            let actions = [action, action, action, action, action, action, action, action, action, action, action]
            await expect(
                governanceInstance.propose(actions, description)
            ).to.be.revertedWith("GOV_TOO_MANY_ACTIONS_ERROR")
            const proposalId = await governanceInstance.callStatic.propose([action], description)
            expect(proposalId).to.be.eq(1)
            const startTime = await staking.callStatic.getCurrentEpochEarliestEndTimeInSeconds()
            const votingPeriod = await governanceInstance.callStatic.votingPeriod()
            // 7 days
            expect(votingPeriod).to.be.eq(604800)
            const endTime = startTime.add(votingPeriod)
            actions = [action, action]
            await expect(
                governanceInstance.propose(actions, description)
            ).to.emit(governanceInstance, "ProposalCreated")
            // TODO: look into log as logged actions seem not equal to actions
            //.withArgs(user1.address, proposalId, actions, startTime, endTime, description)
        })
    })

    describe("castVote", async () => {
        it('should revert with non active proposal', async () => {
            const { governanceInstance, grgToken, grgTransferProxyAddress, poolAddress, poolId, staking } = await setupTests()
            // proposal does not exist
            await expect(
                governanceInstance.castVote(1, VoteType.For)
            ).to.be.revertedWith("VOTING_PROPOSAL_ID_ERROR")
            const amount = parseEther("100000")
            await grgToken.approve(grgTransferProxyAddress, amount)
            await staking.stake(amount)
            await staking.createStakingPool(poolAddress)
            const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId)
            const toInfo = new StakeInfo(StakeStatus.Delegated, poolId)
            await staking.moveStake(fromInfo, toInfo, amount)
            await timeTravel({ days: 14, mine:true })
            await staking.endEpoch()
            const zeroBytes = hre.ethers.utils.formatBytes32String('')
            const action = new ProposedAction(AddressZero, zeroBytes, BigNumber.from('0'))
            await governanceInstance.propose([action], description)
            await expect(
                governanceInstance.castVote(1, VoteType.For)
            ).to.be.revertedWith("VOTING_CLOSED_ERROR")
        })

        it('should revert without voting power', async () => {
            const { governanceInstance, grgToken, grgTransferProxyAddress, poolAddress, poolId, staking } = await setupTests()
            const amount = parseEther("100000")
            await grgToken.approve(grgTransferProxyAddress, amount)
            await staking.stake(amount)
            await staking.createStakingPool(poolAddress)
            const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId)
            const toInfo = new StakeInfo(StakeStatus.Delegated, poolId)
            await staking.moveStake(fromInfo, toInfo, amount)
            await timeTravel({ days: 14, mine:true })
            await staking.endEpoch()
            const zeroBytes = hre.ethers.utils.formatBytes32String('')
            const action = new ProposedAction(AddressZero, zeroBytes, BigNumber.from('0'))
            await governanceInstance.propose([action], description)
            await expect(
                governanceInstance.connect(user2).castVote(1, VoteType.For)
            ).to.be.revertedWith("VOTING_CLOSED_ERROR")
            await timeTravel({ days: 14, mine:true })
            await staking.endEpoch()
            await expect(
                governanceInstance.connect(user2).castVote(1, VoteType.For)
            ).to.be.revertedWith("VOTING_NO_VOTES_ERROR")
            await expect(
                governanceInstance.castVote(1, VoteType.For)
            ).to.emit(governanceInstance, "VoteCast").withArgs(user1.address, 1, VoteType.For, amount)
            await expect(
                governanceInstance.castVote(1, VoteType.For)
            ).to.be.revertedWith("VOTING_ALREADY_VOTED_ERROR")
            // TODO: expect non-empty receipt
        })
    })

    // TODO: encode EIP-712 signature
    describe.skip("castVoteBySignature", async () => {
        it('should revert with direct call', async () => {
            const { governanceInstance } = await setupTests()
            await expect(
                governanceInstance.castVoteBySignature(1)
            ).to.be.revertedWith("reverted_without_a_reason")
        })
    })

    describe("execute", async () => {
        it('should revert with invalid state', async () => {
            const { governanceInstance, grgToken, grgTransferProxyAddress, poolAddress, poolId, staking } = await setupTests()
            await expect(
                governanceInstance.execute(1)
            ).to.be.revertedWith("VOTING_PROPOSAL_ID_ERROR")
            const amount = parseEther("1000000")
            await grgToken.approve(grgTransferProxyAddress, amount)
            await staking.stake(amount)
            await staking.createStakingPool(poolAddress)
            const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId)
            const toInfo = new StakeInfo(StakeStatus.Delegated, poolId)
            await staking.moveStake(fromInfo, toInfo, amount)
            await timeTravel({ days: 14, mine:true })
            await staking.endEpoch()
            const zeroBytes = hre.ethers.utils.formatBytes32String('')
            const action = new ProposedAction(AddressZero, zeroBytes, BigNumber.from('0'))
            await governanceInstance.propose([action], description)
            await expect(
                governanceInstance.execute(1)
            ).to.be.revertedWith("VOTING_EXECUTION_STATE_ERROR")
            await timeTravel({ days: 14, mine:true })
            await staking.endEpoch()
            await governanceInstance.castVote(1, VoteType.For)
            await expect(
                governanceInstance.execute(1)
            ).to.be.revertedWith("VOTING_EXECUTION_STATE_ERROR")
            await timeTravel({ days: 14, mine:true })
            await staking.endEpoch()
            // empty action does not fail
            await expect(
                governanceInstance.execute(1)
            ).to.emit(governanceInstance, "ProposalExecuted").withArgs(1)
            // TODO: test that proposal is immediately executable if votes for > 2/3 total staked grg
            // TODO: test that it reverts if does not reach quorum
            // TODO: test that can pass with majority of votes Abstain
        })

        it('should correctly executes on an external contract', async () => {
            const { governanceInstance, grgToken, grgTransferProxyAddress, poolAddress, poolId, staking } = await setupTests()
            const amount = parseEther("1000000")
            await grgToken.approve(grgTransferProxyAddress, amount)
            await staking.stake(amount)
            await staking.createStakingPool(poolAddress)
            const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId)
            const toInfo = new StakeInfo(StakeStatus.Delegated, poolId)
            await staking.moveStake(fromInfo, toInfo, amount)
            await timeTravel({ days: 14, mine:true })
            await staking.endEpoch()
            const data = grgToken.interface.encodeFunctionData('approve(address,uint256)', [user2.address, amount])
            const action = new ProposedAction(grgToken.address, data, BigNumber.from('0'))
            await governanceInstance.propose([action], description)
            await timeTravel({ days: 14, mine:true })
            await staking.endEpoch()
            await governanceInstance.castVote(1, VoteType.For)
            await timeTravel({ days: 14, mine:true })
            await staking.endEpoch()
            await expect(
                governanceInstance.execute(1)
            ).to.emit(grgToken, "Approval").withArgs(governanceInstance.address, user2.address, amount)
        })

        it('reverts if error in execution', async () => {
            const { governanceInstance, grgToken, grgTransferProxyAddress, poolAddress, poolId, staking } = await setupTests()
            const amount = parseEther("1000000")
            await grgToken.approve(grgTransferProxyAddress, amount)
            await staking.stake(amount)
            await staking.createStakingPool(poolAddress)
            const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId)
            const toInfo = new StakeInfo(StakeStatus.Delegated, poolId)
            await staking.moveStake(fromInfo, toInfo, amount)
            await timeTravel({ days: 14, mine:true })
            await staking.endEpoch()
            const zeroBytes = hre.ethers.utils.formatBytes32String('')
            const action = new ProposedAction(grgToken.address, zeroBytes, BigNumber.from('0'))
            await governanceInstance.propose([action], description)
            await timeTravel({ days: 14, mine:true })
            await staking.endEpoch()
            await governanceInstance.castVote(1, VoteType.For)
            await timeTravel({ days: 14, mine:true })
            await staking.endEpoch()
            await expect(
                governanceInstance.execute(1)
            ).to.be.revertedWith("GOV_ACTION_EXECUTION_ERROR")
        })
    })
})
