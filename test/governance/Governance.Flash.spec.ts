import { expect } from "chai";
import { BigNumber } from "ethers";
import hre, { deployments, waffle, ethers } from "hardhat";
import { parseEther } from "@ethersproject/units";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { signEip712Message } from "../utils/eip712sig";
import { timeTravel, stakeProposalThreshold, ProposalState, ProposedAction, StakeInfo, StakeStatus, TimeType, VoteType } from "../utils/utils";

describe("Governance Flash Attack", async () => {
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
            parseEther("400000"), // 400K GRG
            TimeType.Timestamp,
            'Rigoblock Governance'
        )
        await governanceFactory.createGovernance(
            ImplementationInstance.address,
            StrategyInstance.address,
            parseEther("100000"), // 100k GRG
            parseEther("400000"), // 400K GRG
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

    // a flash attack would still require staking proposal GRG (100k) but would allow upgrading i.e. staking implementation
    //  in order to unstake before staking epoch ends.
    describe("simulate flash attack", async () => {
        it('should not be able to execute during voting period', async () => {
            const { governanceInstance, grgToken, grgTransferProxyAddress, poolAddress, poolId, staking } = await setupTests()
            // we stake the minimum amount to make a proposal
            let amount = parseEther("100000")
            // stake 100k GRG from user1
            await stakeProposalThreshold({ amount, grgToken, grgTransferProxyAddress, staking, poolAddress, poolId })
            const data = grgToken.interface.encodeFunctionData('approve(address,uint256)', [user2.address, amount])
            const action = new ProposedAction(grgToken.address, data, BigNumber.from('0'))
            // at the beginning of the new epoch, we make a proposal which can be voted on in 14 days
            // after the end of the new epoch, we make a proposal which can be voted from current block + 1
            await timeTravel({ days: 14, mine:true })
            await governanceInstance.propose([action], description)
            // we move forward 2 seconds to make sure proposal can be voted on
            await timeTravel({ seconds: 2, mine:true })
            // after the end of the epoch, we  flash borrow and stake GRG in order to gain quorum and > 2/3 of all stake
            amount = parseEther("400000")
            await grgToken.transfer(user2.address, amount)
            await grgToken.connect(user2).approve(grgTransferProxyAddress, amount)
            await staking.connect(user2).stake(amount)
            const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId)
            const toInfo = new StakeInfo(StakeStatus.Delegated, poolId)
            await staking.connect(user2).moveStake(fromInfo, toInfo, amount)
            await staking.endEpoch()
            // voting is active since it has just started
            await governanceInstance.connect(user2).castVote(1, VoteType.For)
            // voting is closed as we have reached qualified consensus (proposal cannot fail under any circumstance)
            await expect(governanceInstance.connect(user2).castVote(1, VoteType.For))
                .to.be.revertedWith("VOTING_CLOSED_ERROR")
            // transaction will be executed as it is in a new block. We keep this test as we want to catch an error should
            //  future upgrades modify this logic. Relevant as moving the voting end 1 block forward instead of same block
            //  as qualifying vote would create an attack vector with limited impact where voters keep postponing voting end.
            await expect(
                governanceInstance.connect(user2).execute(1)
            ).to.emit(grgToken, "Approval")
        })
    })

    describe("flash attack", async () => {
        it('should not be able to execute during voting period', async () => {
            const { governanceInstance, grgToken, grgTransferProxyAddress, poolAddress, poolId, staking } = await setupTests()
            // we stake the minimum amount to make a proposal
            let amount = parseEther("100000")
            // stake 100k GRG from user1
            await stakeProposalThreshold({ amount, grgToken, grgTransferProxyAddress, staking, poolAddress, poolId })
            const data = grgToken.interface.encodeFunctionData('approve(address,uint256)', [user2.address, amount])
            const action = new ProposedAction(grgToken.address, data, BigNumber.from('0'))
            // at the beginning of the new epoch, we make a proposal which can be voted on in 14 days
            // after the end of the new epoch, we make a proposal which can be voted from current block + 1
            await timeTravel({ days: 14, mine:true })
            await governanceInstance.propose([action], description)
            // we move forward 2 seconds to make sure proposal can be voted on
            await timeTravel({ seconds: 2, mine:true })
            // after the end of the epoch, we  flash borrow and stake GRG in order to gain quorum and > 2/3 of all stake
            amount = parseEther("400000")
            const FlashGovernance = await hre.ethers.getContractFactory("FlashGovernance")
            const flashGovernance = await FlashGovernance.deploy(staking.address, governanceInstance.address, grgTransferProxyAddress)
            // we allow the flash governance to move GRG
            await grgToken.approve(flashGovernance.address, amount)
            await expect(flashGovernance.flashAttack(poolId, amount))
                .to.emit(governanceInstance, "VoteCast").withArgs(flashGovernance.address, 1, VoteType.For, amount)
                .to.emit(flashGovernance, "CatchStringEvent").withArgs("VOTING_CLOSED_ERROR")
                .to.emit(flashGovernance, "CatchStringEvent").withArgs("VOTING_EXECUTION_STATE_ERROR")
                .to.emit(flashGovernance, "CatchStringEvent").withArgs("MOVE_STAKE_AMOUNT_HIGHER_THAN_WITHDRAWABLE_ERROR")
                // will revert without reason in old ERC20
                .to.emit(flashGovernance, "ReturnDataEvent").withArgs("0x")
            // during the next block, transaction will be executed
            await expect(
                governanceInstance.connect(user2).execute(1)
            ).to.emit(grgToken, "Approval")
        })
    })
})
