import { expect } from "chai";
import { BigNumber } from "ethers";
import hre, { deployments, waffle, ethers } from "hardhat";
import { parseEther } from "@ethersproject/units";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { signEip712Message } from "../utils/eip712sig";
import { timeTravel, stakeProposalThreshold, ProposalState, ProposedAction, StakeInfo, StakeStatus, TimeType, VoteType } from "../utils/utils";

describe("Governance Proxy", async () => {
    const [ user1, user2, user3 ] = waffle.provider.getWallets()
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
            poolAddress,
            strategy: StrategyInstance.address
        }
    });

    describe("initializeGovernance", async () => {
        it('should always revert', async () => {
            const { governanceInstance } = await setupTests()
            expect(await governanceInstance.name()).to.be.eq('Rigoblock Governance')
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
            let outputActions = await governanceInstance.getActions(1)
            expect(String(outputActions)).to.be.eq(String([]))
            // notice: in the event the test suite does not return an error when comparing actions to an empty array
            // further tests down below assert actions are correctly logged at event emission.
            await expect(governanceInstance.propose(actions, description))
                .to.emit(governanceInstance, "ProposalCreated")
                .withArgs(user1.address, proposalId, outputActions, startTime, endTime, description)
            expect(await governanceInstance.proposalCount()).to.be.eq(1)
            outputActions = await governanceInstance.getActions(1)
            const actionTuple = new ProposedAction(outputActions[0].target, outputActions[0].data, BigNumber.from(outputActions[0].value))
            expect(String(actionTuple)).to.be.eq(String(action))
        })

        it('can create valid proposal', async () => {
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
            const data = grgToken.interface.encodeFunctionData('approve(address,uint256)', [user2.address, amount])
            const action = new ProposedAction(grgToken.address, data, BigNumber.from('0'))
            const proposalId = await governanceInstance.callStatic.propose([action], description)
            expect(proposalId).to.be.eq(1)
            const startTime = await staking.callStatic.getCurrentEpochEarliestEndTimeInSeconds()
            const votingPeriod = await governanceInstance.callStatic.votingPeriod()
            const endTime = startTime.add(votingPeriod)
            const actions = [action, action]
            let outputActions = await governanceInstance.getActions(proposalId)
            expect(String(outputActions)).to.be.eq(String([]))
            // we cannot correctly compare struct arrays in events
            await expect(governanceInstance.propose(actions, description))
                .to.emit(governanceInstance, "ProposalCreated")
                .withArgs(user1.address, proposalId, [], startTime, endTime, description)
            // therefore, we first check that the actions storage has been updated
            outputActions = await governanceInstance.getActions(proposalId)
            expect(String(outputActions)).to.be.not.eq(String([]))
            const actionTuple = new ProposedAction(outputActions[0].target, outputActions[0].data, BigNumber.from(outputActions[0].value))
            expect(String(actionTuple)).to.be.eq(String(action))
            // after that, we further investigate by creating a new identical proposal
            const txReceipt = await governanceInstance.propose(actions, description)
            const result = await txReceipt.wait()
            outputActions = result.events[0].args.actions
            // we define a new variable
            const actionsTuple = [
                  new ProposedAction(outputActions[0].target, outputActions[0].data, BigNumber.from(outputActions[0].value)),
                  new ProposedAction(outputActions[1].target, outputActions[1].data, BigNumber.from(outputActions[1].value))
            ]
            expect(String(actionsTuple)).to.be.eq(String(actions))
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
        })

        it('should revert after voting period ended', async () => {
            const { governanceInstance, grgToken, grgTransferProxyAddress, poolAddress, poolId, staking } = await setupTests()
            const amount = parseEther("100000")
            await stakeProposalThreshold({amount, grgToken, grgTransferProxyAddress, staking, poolAddress, poolId})
            const zeroBytes = hre.ethers.utils.formatBytes32String('')
            const action = new ProposedAction(AddressZero, zeroBytes, BigNumber.from('0'))
            await timeTravel({ days: 8, mine:true })
            await governanceInstance.propose([action], description)
            // voting starts after 6 days
            await timeTravel({ days: 6, mine:true })
            // voting ends after 7 days from voting start
            await timeTravel({ days: 7, mine:true })
            await expect(
                governanceInstance.connect(user2).castVote(1, VoteType.For)
            ).to.be.revertedWith("VOTING_CLOSED_ERROR")
        })
    })

    describe("castVoteBySignature", async () => {
        it('should revert without proposal', async () => {
            const { governanceInstance, strategy } = await setupTests()
            const proposalId = 1
            const voteType = VoteType.Abstain
            const { signature, domain, types, value} = await signEip712Message({
                governance: governanceInstance.address,
                proposalId: proposalId,
                voteType: voteType
            })
            const { v, r, s } = hre.ethers.utils.splitSignature(signature)
            // we use user2 as signed message should be relayable by anyone
            await expect(
                governanceInstance.connect(user2).castVoteBySignature(proposalId, voteType, v, r ,s)
            ).to.be.revertedWith("VOTING_PROPOSAL_ID_ERROR")
        })

        it('should vote on an existing proposal', async () => {
            const { governanceInstance, grgToken, grgTransferProxyAddress, poolAddress, poolId, staking, strategy } = await setupTests()
            const amount = parseEther("100000")
            await stakeProposalThreshold({amount: amount, grgToken: grgToken, grgTransferProxyAddress: grgTransferProxyAddress, staking: staking, poolAddress: poolAddress, poolId: poolId})
            const data = grgToken.interface.encodeFunctionData('approve(address,uint256)', [user2.address, amount])
            const action = new ProposedAction(grgToken.address, data, BigNumber.from('0'))
            const proposalId = await governanceInstance.callStatic.propose([action], description)
            await governanceInstance.propose([action], description)
            await timeTravel({ days: 14, mine:true })
            const voteType = VoteType.For
            const { signature, domain, types, value} = await signEip712Message({
                governance: governanceInstance.address,
                proposalId: proposalId,
                voteType: voteType
            })
            const { v, r, s } = hre.ethers.utils.splitSignature(signature)
            const structDataHash = hre.ethers.utils._TypedDataEncoder.hash(domain, types, value)
            const signerAddress = hre.ethers.utils.recoverAddress(structDataHash, signature)
            expect(signerAddress).to.be.eq(user1.address)
            const { currentEpochBalance } = await staking.getOwnerStakeByStatus(signerAddress, StakeStatus.Delegated)
            const votingPower = await governanceInstance.getVotingPower(signerAddress)
            expect(currentEpochBalance).to.be.eq(votingPower)
            expect(votingPower).to.be.eq(amount)
            // notice: contract only asserts signatory != address(0) as eip712 signatures on diff. domains always bypass the assertion
            await expect(
                governanceInstance.connect(user2).castVoteBySignature(proposalId, voteType, v, r ,s)
            ).to.emit(governanceInstance, "VoteCast").withArgs(user1.address, proposalId, voteType, votingPower)
        })

        it('should revert on wrong proposal id or vote', async () => {
            const { governanceInstance, grgToken, grgTransferProxyAddress, staking, poolAddress, poolId, strategy } = await setupTests()
            const amount = parseEther("100000")
            await stakeProposalThreshold({amount, grgToken, grgTransferProxyAddress, staking, poolAddress, poolId})
            const data = grgToken.interface.encodeFunctionData('approve(address,uint256)', [user2.address, amount])
            const action = new ProposedAction(grgToken.address, data, BigNumber.from('0'))
            await governanceInstance.propose([action], description)
            const proposalId = 1
            const voteType = VoteType.Abstain
            const { signature, domain, types, value} = await signEip712Message({
                governance: governanceInstance.address,
                proposalId: proposalId,
                voteType: voteType
            })
            const { v, r, s } = hre.ethers.utils.splitSignature(signature)
            await governanceInstance.propose([action], description)
            await timeTravel({ days: 14, mine:true })
            // an invalid signature (we send signature for proposal 1, bypasses signature assertion)
            await expect(
                governanceInstance.connect(user2).castVoteBySignature(proposalId + 1, voteType, v, r, s)
            ).to.be.revertedWith("VOTING_NO_VOTES_ERROR")
            await expect(
                governanceInstance.connect(user2).castVoteBySignature(proposalId, VoteType.For, v, r, s)
            ).to.be.revertedWith("VOTING_NO_VOTES_ERROR")
            await expect(
                governanceInstance.connect(user2).castVoteBySignature(proposalId, voteType, v, r ,s)
            ).to.emit(governanceInstance, "VoteCast").withArgs(user1.address, proposalId, voteType, amount)
        })

        it('should not be replayed', async () => {
            const { governanceInstance, grgToken, grgTransferProxyAddress, staking, poolAddress, poolId, strategy } = await setupTests()
            const amount = parseEther("100000")
            await stakeProposalThreshold({amount, grgToken, grgTransferProxyAddress, staking, poolAddress, poolId})
            const data = grgToken.interface.encodeFunctionData('approve(address,uint256)', [user2.address, amount])
            const action = new ProposedAction(grgToken.address, data, BigNumber.from('0'))
            await governanceInstance.propose([action], description)
            const proposalId = 1
            const voteType = VoteType.Abstain
            const { signature, domain, types, value} = await signEip712Message({
                governance: governanceInstance.address,
                proposalId: proposalId,
                voteType: voteType
            })
            const { v, r, s } = hre.ethers.utils.splitSignature(signature)
            await governanceInstance.propose([action], description)
            await timeTravel({ days: 14, mine:true })
            await expect(
                governanceInstance.connect(user2).castVoteBySignature(proposalId, voteType, v, r ,s)
            ).to.emit(governanceInstance, "VoteCast").withArgs(user1.address, proposalId, voteType, amount)
            // submitting a different vote type will return a different signer that probabilistically won't have votes.
            await expect(
                governanceInstance.connect(user3).castVoteBySignature(proposalId, VoteType.For, v, r, s)
            ).to.be.revertedWith("VOTING_NO_VOTES_ERROR")
            await expect(
                governanceInstance.connect(user3).castVoteBySignature(proposalId, voteType, v, r, s)
            ).to.be.revertedWith("VOTING_ALREADY_VOTED_ERROR")
        })

        it('should be able to vote if has unstaked', async () => {
            const { governanceInstance, grgToken, grgTransferProxyAddress, staking, poolAddress, poolId, strategy } = await setupTests()
            const amount = parseEther("100000")
            await stakeProposalThreshold({amount, grgToken, grgTransferProxyAddress, staking, poolAddress, poolId})
            const data = grgToken.interface.encodeFunctionData('approve(address,uint256)', [user2.address, amount])
            const action = new ProposedAction(grgToken.address, data, BigNumber.from('0'))
            await governanceInstance.propose([action], description)
            const proposalId = 1
            const voteType = VoteType.Abstain
            const { signature, domain, types, value} = await signEip712Message({
                governance: governanceInstance.address,
                proposalId: proposalId,
                voteType: voteType
            })
            const { v, r, s } = hre.ethers.utils.splitSignature(signature)
            await timeTravel({ days: 14, mine:true })
            await staking.endEpoch()
            const fromInfo = new StakeInfo(StakeStatus.Delegated, poolId)
            const toInfo = new StakeInfo(StakeStatus.Undelegated, poolId)
            await staking.moveStake(fromInfo, toInfo, amount)
            await expect(staking.unstake(amount)).to.be.revertedWith("MOVE_STAKE_AMOUNT_HIGHER_THAN_WITHDRAWABLE_ERROR")
            await expect(
                governanceInstance.connect(user2).castVoteBySignature(proposalId, voteType, v, r ,s)
            ).to.emit(governanceInstance, "VoteCast").withArgs(user1.address, proposalId, voteType, amount)
            // we create a new proposal
            await governanceInstance.propose([action], description)
            await timeTravel({ days: 14, mine:true })
            await staking.endEpoch()
            await staking.unstake(amount)
            // an invalid signature (we send signature for proposal 1, bypasses signature assertion)
            await expect(
                governanceInstance.connect(user2).castVoteBySignature(proposalId + 1, voteType, v, r, s)
            ).to.be.revertedWith("VOTING_NO_VOTES_ERROR")
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
            // voting becomes active after 14 days if proposal made at beginning of epoch
            await timeTravel({ days: 14, mine:true })
            await expect(
                governanceInstance.execute(1)
            ).to.be.revertedWith("VOTING_EXECUTION_STATE_ERROR")
            await governanceInstance.castVote(1, VoteType.For)
            // proposal becomes executable after voting period ends
            await timeTravel({ days: 7, mine:true })
            // empty action does not fail
            await expect(
                governanceInstance.execute(1)
            ).to.emit(governanceInstance, "ProposalExecuted").withArgs(1)
        })

        it('should revert during voting period when below quorum', async () => {
            const { governanceInstance, grgToken, grgTransferProxyAddress, poolAddress, poolId, staking } = await setupTests()
            expect(await governanceInstance.proposalCount()).to.be.eq(0)
            expect(await governanceInstance.getVotingPower(user1.address)).to.be.eq(0)
            const amount = parseEther("1000000")
            await grgToken.approve(grgTransferProxyAddress, amount)
            await staking.stake(amount)
            await staking.createStakingPool(poolAddress)
            const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId)
            const toInfo = new StakeInfo(StakeStatus.Delegated, poolId)
            await staking.moveStake(fromInfo, toInfo, amount.div(10).mul(7))
            await timeTravel({ days: 14, mine:true })
            await staking.endEpoch()
            expect(await governanceInstance.getVotingPower(user1.address)).to.be.eq(amount.div(10).mul(7))
            const data = grgToken.interface.encodeFunctionData('approve(address,uint256)', [user2.address, amount])
            const action = new ProposedAction(grgToken.address, data, BigNumber.from('0'))
            await governanceInstance.propose([action], description)
            expect(await governanceInstance.proposalCount()).to.be.eq(1)
            await timeTravel({ days: 14, mine:true })
            await governanceInstance.castVote(1, VoteType.For)
            await expect(
                governanceInstance.execute(1)
            ).to.be.revertedWith("VOTING_EXECUTION_STATE_ERROR")
            await governanceInstance.propose([action], description)
            expect(await governanceInstance.proposalCount()).to.be.eq(2)
            await grgToken.transfer(user2.address, amount)
            await grgToken.connect(user2).approve(grgTransferProxyAddress, amount)
            await staking.connect(user2).stake(amount)
            await staking.connect(user2).moveStake(fromInfo, toInfo, amount.div(10).mul(3))
            await staking.endEpoch()
            await governanceInstance.castVote(2, VoteType.For)
            await governanceInstance.connect(user2).castVote(2, VoteType.Abstain)
            await expect(governanceInstance.connect(user2).castVote(2, VoteType.Abstain))
                .to.be.revertedWith("VOTING_ALREADY_VOTED_ERROR")
            // execution reverts as votes for below quorum
            await expect(
                governanceInstance.execute(2)
            ).to.be.revertedWith("VOTING_EXECUTION_STATE_ERROR")
            const proposals = await governanceInstance.proposals()
            expect(proposals[0].proposal.actionsLength).to.be.eq(1)
            expect(proposals[0].proposal.votesFor).to.be.eq(amount.div(10).mul(7))
            expect(proposals[1].proposal.votesAbstain).to.be.eq(amount.div(10).mul(3))
        })

        it('should revert if quorum not reached)', async () => {
            const { governanceInstance, grgToken, grgTransferProxyAddress, poolAddress, poolId, staking } = await setupTests()
            expect(await governanceInstance.proposalCount()).to.be.eq(0)
            expect(await governanceInstance.getVotingPower(user1.address)).to.be.eq(0)
            const amount = parseEther("100000")
            // stake 100k GRG from user1
            await stakeProposalThreshold({ amount, grgToken, grgTransferProxyAddress, staking, poolAddress, poolId })
            const data = grgToken.interface.encodeFunctionData('approve(address,uint256)', [user2.address, amount])
            const action = new ProposedAction(grgToken.address, data, BigNumber.from('0'))
            await governanceInstance.propose([action], description)
            // stake 100k GRG from user2
            const transferAmount = amount
            await grgToken.transfer(user2.address, transferAmount)
            await grgToken.connect(user2).approve(grgTransferProxyAddress, transferAmount)
            await staking.connect(user2).stake(transferAmount)
            const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId)
            const toInfo = new StakeInfo(StakeStatus.Delegated, poolId)
            await staking.connect(user2).moveStake(fromInfo, toInfo, transferAmount)
            // stake 200k + 1 GRG from user3
            const transferAmount2 = amount.mul(2).add(1)
            await grgToken.transfer(user3.address, transferAmount2)
            await grgToken.connect(user3).approve(grgTransferProxyAddress, transferAmount2)
            await staking.connect(user3).stake(transferAmount2)
            await staking.connect(user3).moveStake(fromInfo, toInfo, transferAmount2)
            await governanceInstance.propose([action], description)
            await timeTravel({ days: 14, mine:true })
            await staking.endEpoch()
            await governanceInstance.castVote(1, VoteType.Abstain)
            await governanceInstance.connect(user2).castVote(1, VoteType.Against)
            await governanceInstance.connect(user3).castVote(2, VoteType.For)
            await expect(
                governanceInstance.execute(1)
            ).to.be.revertedWith("VOTING_EXECUTION_STATE_ERROR")
            await timeTravel({ days: 14, mine:true })
            await staking.endEpoch()
            await expect(
                governanceInstance.execute(1)
            ).to.be.revertedWith("VOTING_EXECUTION_STATE_ERROR")
        })

        it('should revert if quorum reached but not enough support', async () => {
            const { governanceInstance, grgToken, grgTransferProxyAddress, poolAddress, poolId, staking } = await setupTests()
            expect(await governanceInstance.proposalCount()).to.be.eq(0)
            expect(await governanceInstance.getVotingPower(user1.address)).to.be.eq(0)
            const amount = parseEther("1000000")
            // stake 1MM GRG from user1
            await stakeProposalThreshold({ amount, grgToken, grgTransferProxyAddress, staking, poolAddress, poolId })
            const data = grgToken.interface.encodeFunctionData('approve(address,uint256)', [user2.address, amount])
            const action = new ProposedAction(grgToken.address, data, BigNumber.from('0'))
            await governanceInstance.propose([action], description)
            // stake 100k GRG from user2
            const transferAmount = amount.div(10)
            await grgToken.transfer(user2.address, transferAmount)
            await grgToken.connect(user2).approve(grgTransferProxyAddress, transferAmount)
            await staking.connect(user2).stake(transferAmount)
            const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId)
            const toInfo = new StakeInfo(StakeStatus.Delegated, poolId)
            await staking.connect(user2).moveStake(fromInfo, toInfo, transferAmount)
            await timeTravel({ days: 14, mine:true })
            await staking.endEpoch()
            await governanceInstance.castVote(1, VoteType.Abstain)
            await governanceInstance.connect(user2).castVote(1, VoteType.Against)
            await timeTravel({ days: 14, mine:true })
            await staking.endEpoch()
            await expect(
                governanceInstance.execute(1)
            ).to.be.revertedWith("VOTING_EXECUTION_STATE_ERROR")
            // add another voter
            await grgToken.transfer(user3.address, transferAmount.add(1))
            await grgToken.connect(user3).approve(grgTransferProxyAddress, transferAmount.add(1))
            await staking.connect(user3).stake(transferAmount.add(1))
            await staking.connect(user3).moveStake(fromInfo, toInfo, transferAmount.add(1))
            await governanceInstance.propose([action], description)
            await timeTravel({ days: 14, mine:true })
            await staking.endEpoch()
            await governanceInstance.castVote(2, VoteType.Abstain)
            await governanceInstance.connect(user2).castVote(2, VoteType.Against)
            await governanceInstance.connect(user3).castVote(2, VoteType.For)
            const receipt = await governanceInstance.getReceipt(2, user3.address)
            expect(receipt.hasVoted).to.be.eq(true)
            expect(receipt.votes).to.be.eq(transferAmount.add(1))
            expect(Number(receipt.voteType)).to.be.eq(0)
            await expect(governanceInstance.connect(user3).castVote(2, VoteType.Abstain))
                .to.be.revertedWith("VOTING_ALREADY_VOTED_ERROR")
            await timeTravel({ days: 14, mine:true })
            await expect(
                governanceInstance.execute(2)
            ).to.be.revertedWith("VOTING_EXECUTION_STATE_ERROR")
        })

        it('should revert during voting period (unless qualified > of all delegated stake)', async () => {
            const { governanceInstance, grgToken, grgTransferProxyAddress, poolAddress, poolId, staking } = await setupTests()
            expect(await governanceInstance.proposalCount()).to.be.eq(0)
            expect(await governanceInstance.getVotingPower(user1.address)).to.be.eq(0)
            const amount = parseEther("1000000")
            // stake 1MM GRG from user1
            await stakeProposalThreshold({ amount, grgToken, grgTransferProxyAddress, staking, poolAddress, poolId })
            const data = grgToken.interface.encodeFunctionData('approve(address,uint256)', [user2.address, amount])
            const action = new ProposedAction(grgToken.address, data, BigNumber.from('0'))
            await governanceInstance.propose([action], description)
            // stake 100k GRG from user2
            const transferAmount = amount.div(10)
            await grgToken.transfer(user2.address, transferAmount)
            await grgToken.connect(user2).approve(grgTransferProxyAddress, transferAmount)
            await staking.connect(user2).stake(transferAmount)
            const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId)
            const toInfo = new StakeInfo(StakeStatus.Delegated, poolId)
            await staking.connect(user2).moveStake(fromInfo, toInfo, transferAmount)
            // stake 200k + 1 GRG from user3
            const transferAmount2 = transferAmount.mul(2).add(1)
            await grgToken.transfer(user3.address, transferAmount2)
            await grgToken.connect(user3).approve(grgTransferProxyAddress, transferAmount2)
            await staking.connect(user3).stake(transferAmount2)
            await staking.connect(user3).moveStake(fromInfo, toInfo, transferAmount2)
            await timeTravel({ days: 14, mine:true })
            await staking.endEpoch()
            await governanceInstance.castVote(1, VoteType.Abstain)
            await governanceInstance.connect(user2).castVote(1, VoteType.Against)
            await governanceInstance.connect(user3).castVote(1, VoteType.For)
            await expect(
                governanceInstance.execute(1)
            ).to.be.revertedWith("VOTING_EXECUTION_STATE_ERROR")
            await timeTravel({ days: 14, mine:true })
            // reverts as qualified majority but quorum not reached
            await expect(
                governanceInstance.execute(1)
            ).to.be.revertedWith("VOTING_EXECUTION_STATE_ERROR")
        })

        it('should correctly execute an external contract call', async () => {
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
            // finalizePool can be called at any time and will have no impact on state but will emit log
            const data2 = staking.interface.encodeFunctionData('finalizePool(bytes32)', [poolId])
            const action2 = new ProposedAction(staking.address, data2, BigNumber.from('0'))
            await governanceInstance.propose([action, action2], description)
            await timeTravel({ days: 14, mine:true })
            // only 3 types of votes are supported, the 4th will revert
            await expect(governanceInstance.castVote(1, 3)).to.be.reverted
            await governanceInstance.castVote(1, VoteType.For)
            await timeTravel({ days: 14, mine:true })
            const firstAction = (await governanceInstance.getActions(1))[0]
            expect(firstAction.target).to.be.eq(grgToken.address)
            expect(firstAction.value).to.be.eq(0)
            expect(firstAction.data).to.be.eq(data)
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
            await governanceInstance.castVote(1, VoteType.For)
            await timeTravel({ days: 14, mine:true })
            await expect(
                governanceInstance.execute(1)
            ).to.be.revertedWith("Transaction reverted without a reason")
        })

        // executable immediately after support > 2/3 all staked delegated GRG
        it('should be able to execute during voting period when qualified majority', async () => {
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
            expect(await governanceInstance.getProposalState(1)).to.be.eq(ProposalState.Pending)
            await timeTravel({ days: 14, mine:true })
            expect(await governanceInstance.getProposalState(1)).to.be.eq(ProposalState.Active)
            await governanceInstance.castVote(1, VoteType.For)
            // qualified majority will change state to qualified, which can be executed at next block
            expect(await governanceInstance.getProposalState(1)).to.be.eq(ProposalState.Qualified)
            // we do not need to time travel as a new transaction is included in a new block
            await expect(
                governanceInstance.execute(1)
            ).to.emit(grgToken, "Approval").withArgs(governanceInstance.address, user2.address, amount)
            // after execution state will find its final state
            expect(await governanceInstance.getProposalState(1)).to.be.eq(ProposalState.Executed)
        })
    })
})
