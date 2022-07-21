import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber, Contract } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { timeTravel } from "../utils/utils";
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
        const AuthorityExtensionsInstance = await deployments.get("AuthorityExtensions")
        const AuthorityExtensions = await hre.ethers.getContractFactory("AuthorityExtensions")
        const AStakingInstance = await deployments.get("AStaking")
        const authorityExtensions = AuthorityExtensions.attach(AuthorityExtensionsInstance.address)
        //"a694fc3a": "stake(uint256)"
        await authorityExtensions.whitelistMethod(
            "0xa694fc3a",
            AStakingInstance.address
        )
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
            authorityExtensions
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
            await expect(
                pop.creditPopRewardToStakingProxy(newPoolAddress)
            ).to.emit(stakingProxy, "StakingPoolEarnedRewardsInEpoch").withArgs(2, poolId)
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

    describe("getStakingPoolStatsThisEpoch", async () => {
        // TODO: will return 0 until pool has positive active stake
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
})

export enum StakeStatus {
    Undelegated,
    Delegated,
}

export class StakeInfo {
    constructor(public status: StakeStatus, public poolId: any) {}
}
