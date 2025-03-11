import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber, Contract } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { timeTravel, ProposedAction, TimeType, VoteType } from "../utils/utils";
import { getAddress } from "ethers/lib/utils";

describe("AGovernance", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()
    const description = 'gov proposal one'

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        const GrgTokenInstance = await deployments.get("RigoToken")
        const GrgToken = await hre.ethers.getContractFactory("RigoToken")
        const GrgVaultInstance = await deployments.get("GrgVault")
        const GrgVault = await hre.ethers.getContractFactory("GrgVault")
        const PopInstance = await deployments.get("ProofOfPerformance")
        const Pop = await hre.ethers.getContractFactory("ProofOfPerformance")
        const StakingProxyInstance = await deployments.get("StakingProxy")
        const Staking = await hre.ethers.getContractFactory("Staking")
        const GrgTransferProxyInstance = await deployments.get("ERC20Proxy")
        const grgTransferProxyAddress = GrgTransferProxyInstance.address
        const AuthorityInstance = await deployments.get("Authority")
        const Authority = await hre.ethers.getContractFactory("Authority")
        const AStakingInstance = await deployments.get("AStaking")
        const authority = Authority.attach(AuthorityInstance.address)
        // "a694fc3a": "stake(uint256)"
        // "4aace835": "undelegateStake(uint256)",
        // "2e17de78": "unstake(uint256)",
        // "b880660b": "withdrawDelegatorRewards()"
        await authority.addMethod("0xa694fc3a", AStakingInstance.address)
        await authority.addMethod("0x4aace835", AStakingInstance.address)
        await authority.addMethod("0x2e17de78", AStakingInstance.address)
        await authority.addMethod("0xb880660b", AStakingInstance.address)
        const factory = Factory.attach(RigoblockPoolProxyFactory.address)
        const { newPoolAddress, poolId } = await factory.callStatic.createPool(
            'testpool',
            'TEST',
            AddressZero
        )
        await factory.createPool('testpool','TEST',AddressZero)
        const stakingProxy = Staking.attach(StakingProxyInstance.address)
        return {
            grgToken: GrgToken.attach(GrgTokenInstance.address),
            grgVault: GrgVault.attach(GrgVaultInstance.address),
            pop: Pop.attach(PopInstance.address),
            stakingProxy,
            grgTransferProxyAddress,
            newPoolAddress,
            poolId,
            authority
        }
    });

    describe("execute", async () => {
        it('should execute a proposal', async () => {
            const { stakingProxy, pop, grgToken, newPoolAddress, authority } = await setupTests()
            const pool = await hre.ethers.getContractAt("IRigoblockPoolExtended", newPoolAddress)
            const amount = parseEther("400000")
            await grgToken.transfer(newPoolAddress, amount)
            await pool.stake(amount)
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            const GovFactory = await hre.ethers.getContractFactory("RigoblockGovernanceFactory")
            const govFactory = await GovFactory.deploy()
            const GovImplementation = await hre.ethers.getContractFactory("RigoblockGovernance")
            const govImplementation = await GovImplementation.deploy()
            const GovStrategy = await hre.ethers.getContractFactory("RigoblockGovernanceStrategy")
            const govStrategy = await GovStrategy.deploy(stakingProxy.address)
            // we deploy from user2 as otherwise governance already exists
            const governance = await govFactory.connect(user2).callStatic.createGovernance(
                govImplementation.address,
                govStrategy.address,
                parseEther("100000"), // 100k GRG
                parseEther("400000"), // 400K GRG
                TimeType.Timestamp,
                'Rigoblock Governance'
            )
            await govFactory.connect(user2).createGovernance(
                govImplementation.address,
                govStrategy.address,
                parseEther("100000"), // 100k GRG
                parseEther("400000"), // 400K GRG
                TimeType.Timestamp,
                'Rigoblock Governance')
            const governanceInstance = GovImplementation.attach(governance)
            const AGovernance = await hre.ethers.getContractFactory("AGovernance")
            const aGovernance = await AGovernance.deploy(governance)
            const data = grgToken.interface.encodeFunctionData('approve(address,uint256)', [user2.address, amount])
            const action = new ProposedAction(grgToken.address, data, BigNumber.from('0'))
            await expect(pool.propose([action], description)).to.be.revertedWith('PoolMethodNotAllowed()')
            // we add the adapter
            await authority.setAdapter(aGovernance.address, true)
            await expect(pool.propose([action], description)).to.be.revertedWith('PoolMethodNotAllowed()')
            // we whitelist the methods
            // "56781388": "castVote(uint256, VoteType)",
            // "fe0d94c1": "execute(uint256)",
            // "367015bb": "propose(Proposal, string)"
            await authority.addMethod("0x56781388", aGovernance.address)
            await authority.addMethod("0xfe0d94c1", aGovernance.address)
            await authority.addMethod("0x367015bb", aGovernance.address)
            // we make a proposal
            await expect(pool.propose([action], description)).to.emit(governanceInstance, "ProposalCreated")
            await timeTravel({ days: 14, mine:true })
            await expect(pool.castVote(1, VoteType.For)).to.emit(governanceInstance, "VoteCast")
                .withArgs(pool.address, 1, VoteType.For, amount)
            await timeTravel({ days: 7, mine:true })
            // must encode call, as execute method is also present in AUniswapRouter and hardhat will not be able to differentiate
            const encodedExecuteData = pool.interface.encodeFunctionData('execute(uint256)', [1])
            
            // txn will always revert in fallback
            await expect(
                user1.sendTransaction({ to: pool.address, value: 0, data: encodedExecuteData})
            ).to.emit(governanceInstance, "ProposalExecuted").withArgs(1)
            //await expect(pool.execute(1)).to.emit(governanceInstance, "ProposalExecuted").withArgs(1)
        })
    })
})
