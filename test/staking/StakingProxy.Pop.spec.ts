import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber, Contract } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { deployContract, timeTravel } from "../utils/utils";
import { getAddress } from "ethers/lib/utils";

describe("StakingProxy-Pop", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()

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
        //"a694fc3a": "stake(uint256)"
        await authority.addMethod("0xa694fc3a", AStakingInstance.address)
        await authority.addMethod("0x4aace835", AStakingInstance.address)
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
            authority,
            factory,
            stakingProxy,
            grgTransferProxyAddress,
            newPoolAddress,
            poolId
        }
    });

    describe("creditPopRewardToStakingProxy", async () => {
        it('should revert if locked balances are null', async () => {
            const { stakingProxy, pop, grgToken, grgTransferProxyAddress, newPoolAddress, poolId } = await setupTests()
            const amount = parseEther("100")
            await grgToken.approve(grgTransferProxyAddress, amount)
            await stakingProxy.stake(amount)
            await stakingProxy.createStakingPool(newPoolAddress)
            const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId)
            const toInfo = new StakeInfo(StakeStatus.Delegated, poolId)
            await stakingProxy.moveStake(fromInfo, toInfo, amount)
            await expect(
                pop.creditPopRewardToStakingProxy(newPoolAddress)
            ).to.be.revertedWith("POP_STAKING_POOL_BALANCES_NULL_ERROR")
        })

        it('should revert if caller not pop', async () => {
            const { stakingProxy, pop, grgToken, newPoolAddress } = await setupTests()
            const amount = parseEther("100")
            await grgToken.transfer(newPoolAddress, amount)
            // must define pool as pool address on adapter instance
            const Pool = await hre.ethers.getContractFactory("AStaking")
            const pool = Pool.attach(newPoolAddress)
            await pool.stake(amount)
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            await expect(
                pop.creditPopRewardToStakingProxy(newPoolAddress)
            ).to.be.revertedWith("STAKING_ONLY_CALLABLE_BY_POP_ERROR")
        })

        it('should revert if staking pool does not exist', async () => {
            const { stakingProxy, newPoolAddress } = await setupTests()
            await stakingProxy.addAuthorizedAddress(user1.address)
            await stakingProxy.addPopAddress(user2.address)
            await expect(
                stakingProxy.connect(user2).creditPopReward(newPoolAddress, 100)
            ).to.be.revertedWith("STAKING_NULL_POOL_ID_ERROR")
            await stakingProxy.createStakingPool(newPoolAddress)
            await expect(
                stakingProxy.connect(user2).creditPopReward(newPoolAddress, 100)
            ).to.be.revertedWith("STAKING_STAKE_BELOW_MINIMUM_ERROR")
        })

        it('should revert if stake below minimum', async () => {
            const { stakingProxy, pop, grgToken, newPoolAddress, poolId } = await setupTests()
            const amount = parseEther("50")
            await grgToken.transfer(newPoolAddress, amount)
            const Pool = await hre.ethers.getContractFactory("AStaking")
            const pool = Pool.attach(newPoolAddress)
            await expect(pool.stake(0)).to.be.revertedWith("STAKE_AMOUNT_NULL_ERROR")
            await pool.stake(amount)
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            await stakingProxy.addAuthorizedAddress(user1.address)
            await stakingProxy.addPopAddress(pop.address)
            await expect(
                pop.creditPopRewardToStakingProxy(newPoolAddress)
            ).to.be.revertedWith("STAKING_STAKE_BELOW_MINIMUM_ERROR")
        })

        it('should credit pop rewards for existing pool', async () => {
            const { stakingProxy, pop, grgToken, newPoolAddress, poolId } = await setupTests()
            const amount = parseEther("100")
            await grgToken.transfer(newPoolAddress, amount)
            // pool address on adapter interface
            const Pool = await hre.ethers.getContractFactory("AStaking")
            const pool = Pool.attach(newPoolAddress)
            // will automatically create staking pool if doesn't exist (pool is staking pal)
            await pool.stake(amount)
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            await stakingProxy.addAuthorizedAddress(user1.address)
            await stakingProxy.addPopAddress(pop.address)
            const newEpochPoolStats = await stakingProxy.getStakingPoolStatsThisEpoch(poolId)
            expect(newEpochPoolStats.feesCollected).to.be.eq(0)
            await expect(
                pop.creditPopRewardToStakingProxy(newPoolAddress)
            ).to.emit(stakingProxy, "StakingPoolEarnedRewardsInEpoch").withArgs(2, poolId)
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            await timeTravel({ days: 14, mine:true })
            await expect(
                stakingProxy.endEpoch()
            ).to.be.revertedWith("STAKING_MISSING_POOLS_TO_BE_FINALIZED_ERROR")
        })

        it('should not credit null pop rewards for existing pool', async () => {
            const { stakingProxy, grgToken, pop, newPoolAddress, grgTransferProxyAddress, poolId } = await setupTests()
            await stakingProxy.addAuthorizedAddress(user1.address)
            await stakingProxy.addPopAddress(pop.address)
            const amount = parseEther("100")
            await grgToken.approve(grgTransferProxyAddress, amount)
            await stakingProxy.stake(amount)
            await stakingProxy.createStakingPool(newPoolAddress)
            const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId)
            const toInfo = new StakeInfo(StakeStatus.Delegated, poolId)
            await stakingProxy.moveStake(fromInfo, toInfo, amount)
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            await expect(
                pop.creditPopRewardToStakingProxy(newPoolAddress)
            ).to.be.revertedWith("POP_STAKING_POOL_BALANCES_NULL_ERROR")
            await grgToken.transfer(newPoolAddress, amount)
            const Pool = await hre.ethers.getContractFactory("AStaking")
            const pool = Pool.attach(newPoolAddress)
            await pool.stake(parseEther("1"))
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            await pool.undelegateStake(parseEther("1"))
            await expect(
                pop.creditPopRewardToStakingProxy(newPoolAddress)
            ).to.emit(stakingProxy, "StakingPoolEarnedRewardsInEpoch").withArgs(3, poolId)
            let newEpochPoolStats
            newEpochPoolStats = await stakingProxy.getStakingPoolStatsThisEpoch(poolId)
            expect(newEpochPoolStats.feesCollected).to.be.eq(parseEther("1"))
            // we can call credit reward multiple times but it won't change reward
            await pop.creditPopRewardToStakingProxy(newPoolAddress)
            newEpochPoolStats = await stakingProxy.getStakingPoolStatsThisEpoch(poolId)
            expect(newEpochPoolStats.feesCollected).to.be.eq(parseEther("1"))
        })
    })

    describe("finalize", async () => {
        it('should finalize with multiple pools', async () => {
            const { factory, stakingProxy, grgToken, pop, newPoolAddress, grgTransferProxyAddress, poolId } = await setupTests()
            await stakingProxy.addAuthorizedAddress(user1.address)
            await stakingProxy.addPopAddress(pop.address)
            const amount = parseEther("200")
            await grgToken.transfer(newPoolAddress, amount)
            const Pool = await hre.ethers.getContractFactory("AStaking")
            const pool = Pool.attach(newPoolAddress)
            await pool.stake(parseEther("100"))
            const pool2Data = await factory.callStatic.createPool(
                'testpool2',
                'TEST',
                AddressZero
            )
            await factory.createPool('testpool2','TEST',AddressZero)
            await grgToken.transfer(pool2Data.newPoolAddress, amount)
            const pool2 = Pool.attach(pool2Data.newPoolAddress)
            await pool2.stake(parseEther("200"))
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            await expect(
                pop.creditPopRewardToStakingProxy(newPoolAddress)
            ).to.emit(stakingProxy, "StakingPoolEarnedRewardsInEpoch").withArgs(2, poolId)
            await expect(
                pop.creditPopRewardToStakingProxy(pool2Data.newPoolAddress)
            ).to.emit(stakingProxy, "StakingPoolEarnedRewardsInEpoch").withArgs(2, pool2Data.poolId)
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            await stakingProxy.finalizePool(poolId)
        })

        it('should credit null reward with rogue pop', async () => {
            const { authority, stakingProxy, grgToken, pop, newPoolAddress, grgTransferProxyAddress, poolId } = await setupTests()
            await stakingProxy.addAuthorizedAddress(user1.address)
            await stakingProxy.addPopAddress(user1.address)
            await authority.setFactory(user1.address, true)
            const RegistryInstance = await deployments.get("PoolRegistry")
            const Registry = await hre.ethers.getContractFactory("PoolRegistry")
            const registry = Registry.attach(RegistryInstance.address)
            const mockName = "mock name"
            const mockBytes32 = hre.ethers.utils.formatBytes32String(mockName)
            const source = `contract MockPool { address public owner = address(1); }`
            const mockPool = await deployContract(user1, source)
            await registry.register(mockPool.address, mockName, "TEST", mockBytes32)
            await stakingProxy.createStakingPool(mockPool.address)
            const amount = parseEther("100")
            await grgToken.approve(grgTransferProxyAddress, amount)
            await stakingProxy.stake(amount)
            const fromInfo = new StakeInfo(StakeStatus.Undelegated, mockBytes32)
            const toInfo = new StakeInfo(StakeStatus.Delegated, mockBytes32)
            await stakingProxy.moveStake(fromInfo, toInfo, amount)
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            await expect(
                stakingProxy.creditPopReward(mockPool.address, 0)
            ).to.emit(stakingProxy, "StakingPoolEarnedRewardsInEpoch").withArgs(2, mockBytes32)
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            await stakingProxy.finalizePool(mockBytes32)
            // test system does not get stuck even in case of rogue pop
            await timeTravel({ days: 14, mine:true })
            // system won't be able to reduce num pools to finalize if reward credited is 0.
            // this condition is excluded by both pop contract which reverts if pool self stake below minimum
            await expect(stakingProxy.endEpoch()).to.be.revertedWith("STAKING_MISSING_POOLS_TO_BE_FINALIZED_ERROR")
        })

        it('should credit null reward on L2s with null token balance on inflation', async () => {
            const { authority, stakingProxy, grgToken, pop, newPoolAddress, grgTransferProxyAddress, poolId } = await setupTests()
            await stakingProxy.addAuthorizedAddress(user1.address)
            await stakingProxy.addPopAddress(pop.address)
            const InflationL2Instance = await deployments.get("InflationL2")
            const InflationL2 = await hre.ethers.getContractFactory("InflationL2")
            const inflationL2 = InflationL2.attach(InflationL2Instance.address)
            await inflationL2.initParams(grgToken.address, stakingProxy.address)
            await grgToken.changeMintingAddress(inflationL2.address)
            const Pool = await hre.ethers.getContractFactory("AStaking")
            const amount = parseEther("100")
            await grgToken.transfer(newPoolAddress, amount)
            const pool = Pool.attach(newPoolAddress)
            await pool.stake(amount)
            await timeTravel({ days: 14, mine:true })
            await expect(stakingProxy.endEpoch())
            .to.emit(stakingProxy, "EpochEnded").withArgs(1, 0, 0, 0, 0)
            .to.emit(stakingProxy, "EpochFinalized").withArgs(1, 0, 0)
            await expect(
                pop.creditPopRewardToStakingProxy(newPoolAddress)
            ).to.emit(stakingProxy, "StakingPoolEarnedRewardsInEpoch").withArgs(2, poolId)
            await timeTravel({ days: 14, mine:true })
            await expect(stakingProxy.endEpoch())
            .to.emit(stakingProxy, "EpochEnded").withArgs(2, 1, 0, amount, amount.mul(9).div(10))
            .to.emit(stakingProxy, "GrgMintEvent").withArgs(0)
            await expect(stakingProxy.finalizePool(poolId))
            // currentEpoch_, poolId, operatorReward, membersReward
            .to.emit(stakingProxy, "RewardsPaid").withArgs(3, poolId, 0, 0)
            // prevEpoch, totalRewardsFinalized, reamining rewards
            .to.emit(stakingProxy, "EpochFinalized").withArgs(2, 0, 0)
            // system does not get stuck even in case of null token balance
            await expect(
                pop.creditPopRewardToStakingProxy(newPoolAddress)
            ).to.emit(stakingProxy, "StakingPoolEarnedRewardsInEpoch").withArgs(3, poolId)
            await timeTravel({ days: 14, mine:true })
            const tokenAmount = parseEther("50000")
            await grgToken.transfer(inflationL2.address, tokenAmount)
            const nextMintAmount = await inflationL2.getEpochInflation()
            await expect(stakingProxy.endEpoch())
            .to.emit(stakingProxy, "EpochEnded").withArgs(3, 1, nextMintAmount, amount, amount.mul(9).div(10))
            .to.emit(stakingProxy, "GrgMintEvent").withArgs(nextMintAmount)
            await expect(stakingProxy.finalizePool(poolId))
            .to.emit(stakingProxy, "RewardsPaid").withArgs(4, poolId, nextMintAmount.mul(7000).div(10000).add(1), nextMintAmount.mul(3000).div(10000))
            .to.emit(stakingProxy, "EpochFinalized").withArgs(3, nextMintAmount, 0)
            const mintedAmount = await grgToken.balanceOf(stakingProxy.address)
            expect(mintedAmount).to.be.not.eq(0)
            await timeTravel({ days: 14, mine:true })
            await expect(stakingProxy.endEpoch())
            .to.emit(stakingProxy, "EpochEnded").withArgs(4, 0, nextMintAmount, 0, 0)
            .to.emit(stakingProxy, "GrgMintEvent").withArgs(nextMintAmount)
        })
    })

    describe("proofOfPerformance", async () => {
        // will return 0 until pool has positive active stake
        it('should return value of pop reward', async () => {
            const { stakingProxy, grgToken, pop, newPoolAddress, grgTransferProxyAddress, poolId } = await setupTests()
            await stakingProxy.addAuthorizedAddress(user1.address)
            await stakingProxy.addPopAddress(pop.address)
            expect(await pop.proofOfPerformance(newPoolAddress)).to.be.eq(0)
            const amount = parseEther("100")
            await grgToken.approve(grgTransferProxyAddress, amount)
            await stakingProxy.stake(amount)
            await stakingProxy.createStakingPool(newPoolAddress)
            const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId)
            const toInfo = new StakeInfo(StakeStatus.Delegated, poolId)
            await stakingProxy.moveStake(fromInfo, toInfo, amount)
            expect(await pop.proofOfPerformance(newPoolAddress)).to.be.eq(0)
            await grgToken.transfer(newPoolAddress, amount)
            const Pool = await hre.ethers.getContractFactory("AStaking")
            const pool = Pool.attach(newPoolAddress)
            await pool.stake(amount)
            expect(await pop.proofOfPerformance(newPoolAddress)).to.be.eq(0)
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            expect(await pop.proofOfPerformance(newPoolAddress)).to.be.eq(amount)
        })
    })

    describe("withdrawDelegatorRewards", async () => {
        it('should withdraw delegator rewards', async () => {
            const { stakingProxy, grgToken, pop, newPoolAddress, grgTransferProxyAddress, poolId } = await setupTests()
            await stakingProxy.addAuthorizedAddress(user1.address)
            await stakingProxy.addPopAddress(pop.address)
            const amount = parseEther("100")
            await grgToken.approve(grgTransferProxyAddress, amount)
            await stakingProxy.stake(amount)
            await stakingProxy.createStakingPool(newPoolAddress)
            const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId)
            const toInfo = new StakeInfo(StakeStatus.Delegated, poolId)
            await stakingProxy.moveStake(fromInfo, toInfo, amount)
            await grgToken.transfer(newPoolAddress, amount)
            const Pool = await hre.ethers.getContractFactory("AStaking")
            const pool = Pool.attach(newPoolAddress)
            await pool.stake(amount)
            let delegatorReward
            delegatorReward = await stakingProxy.computeRewardBalanceOfDelegator(poolId, user1.address)
            expect(delegatorReward).to.be.deep.eq(0)
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            await pop.creditPopRewardToStakingProxy(newPoolAddress)
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            await expect(stakingProxy.withdrawDelegatorRewards(poolId))
                .to.be.revertedWith("STAKING_POOL_NOT_FINALIZED_ERROR")
            let poolOperatorReward
            poolOperatorReward = await stakingProxy.computeRewardBalanceOfOperator(poolId)
            expect(poolOperatorReward).to.be.not.eq(0)
            await stakingProxy.finalizePool(poolId)
            // noop if thepool already finalized
            await stakingProxy.finalizePool(poolId)
            poolOperatorReward = await stakingProxy.computeRewardBalanceOfOperator(poolId)
            // reward is paid to pool operator at pool finalization
            expect(poolOperatorReward).to.be.eq(0)
            delegatorReward = await stakingProxy.computeRewardBalanceOfDelegator(poolId, user1.address)
            await expect(stakingProxy.withdrawDelegatorRewards(poolId))
                .to.emit(grgToken, "Transfer").withArgs(stakingProxy.address, user1.address, delegatorReward)
        })
    })

    describe("getStakingPoolStatsThisEpoch", async () => {
        it('should return staking pool earned rewards', async () => {
            const { stakingProxy, grgToken, pop, poolId, newPoolAddress } = await setupTests()
            await stakingProxy.addAuthorizedAddress(user1.address)
            await stakingProxy.addPopAddress(pop.address)
            const poolStats = await stakingProxy.getStakingPoolStatsThisEpoch(poolId)
            expect(poolStats.feesCollected).to.be.eq(0)
            expect(poolStats.weightedStake).to.be.eq(0)
            expect(poolStats.membersStake).to.be.eq(0)
            const amount = parseEther("100")
            await grgToken.transfer(newPoolAddress, amount)
            const Pool = await hre.ethers.getContractFactory("AStaking")
            const pool = Pool.attach(newPoolAddress)
            await pool.stake(amount)
            // noop if thepool already finalized
            await stakingProxy.finalizePool(poolId)
            await expect(
                pop.creditPopRewardToStakingProxy(newPoolAddress)
            ).to.be.revertedWith("POP_STAKING_POOL_BALANCES_NULL_ERROR")
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            await expect(
                pop.creditPopRewardToStakingProxy(newPoolAddress)
            ).to.emit(stakingProxy, "StakingPoolEarnedRewardsInEpoch").withArgs(2, poolId)
            const newEpochPoolStats = await stakingProxy.getStakingPoolStatsThisEpoch(poolId)
            expect(newEpochPoolStats.feesCollected).to.be.eq(amount)
            expect(newEpochPoolStats.weightedStake).to.be.eq(parseEther("90"))
            expect(newEpochPoolStats.membersStake).to.be.eq(parseEther("100"))
        })
    })

    describe("addPopAddress", async () => {
        it('should revert pop registration if already registered', async () => {
            const { stakingProxy, pop } = await setupTests()
            await expect(
                stakingProxy.addPopAddress(pop.address)
            ).to.be.revertedWith("AUTHORIZABLE_SENDER_NOT_AUTHORIZED_ERROR")
            await expect(
                stakingProxy.connect(user2).addAuthorizedAddress(user2.address)
            ).to.be.revertedWith("CALLER_NOT_OWNER_ERROR")
            await stakingProxy.addAuthorizedAddress(user1.address)
            await expect(
                stakingProxy.addPopAddress(pop.address)
            ).to.emit(stakingProxy, "PopAdded").withArgs(pop.address)
            await expect(
                stakingProxy.addPopAddress(pop.address)
            ).to.be.revertedWith("STAKING_POP_ALREADY_REGISTERED_ERROR")
        })
    })

    describe("removePopAddress", async () => {
        it('should revert removing non-registered pop', async () => {
            const { stakingProxy, pop } = await setupTests()
            await expect(
                stakingProxy.removePopAddress(pop.address)
            ).to.be.revertedWith("AUTHORIZABLE_SENDER_NOT_AUTHORIZED_ERROR")
            await stakingProxy.addAuthorizedAddress(user1.address)
            await expect(
                stakingProxy.removePopAddress(pop.address)
            ).to.be.revertedWith("STAKING_POP_NOT_REGISTERED_ERROR")
            await stakingProxy.addPopAddress(pop.address)
            await expect(
                stakingProxy.removePopAddress(pop.address)
            ).to.emit(stakingProxy, "PopRemoved").withArgs(pop.address)
        })
    })
})

export enum StakeStatus {
    Undelegated,
    Delegated,
}

export class StakeInfo {
    constructor(public status: StakeStatus, public poolId: any) {}
}
