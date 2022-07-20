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
        const grgToken = GrgToken.attach(GrgTokenInstance.address)
        const grgTransferProxyAddress = GrgTransferProxyInstance.address
        const stakingProxy = Staking.attach(StakingProxyInstance.address)
        const factory = Factory.attach(RigoblockPoolProxyFactory.address)
        const { newPoolAddress, poolId } = await factory.callStatic.createPool(
            'testpool',
            'TEST',
            AddressZero
        )
        await factory.createPool('testpool','TEST',AddressZero)
        const amount = parseEther("100")
        await grgToken.approve(grgTransferProxyAddress, amount)
        await stakingProxy.stake(amount)
        await stakingProxy.createStakingPool(newPoolAddress)
        const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId)
        const toInfo = new StakeInfo(StakeStatus.Delegated, poolId)
        await stakingProxy.moveStake(fromInfo, toInfo, amount)
        return {
            grgToken,
            grgVault: GrgVault.attach(GrgVaultInstance.address),
            pop: Pop.attach(PopInstance.address),
            stakingProxy,
            grgTransferProxyAddress,
            newPoolAddress,
            poolId
        }
    });

    describe("creditPopRewardToStakingProxy", async () => {
        it('should revert if locked balances are null', async () => {
            const { stakingProxy, pop, newPoolAddress } = await setupTests()
            await expect(
                pop.creditPopRewardToStakingProxy(newPoolAddress)
            ).to.be.revertedWith("POP_STAKING_POOL_BALANCES_NULL_ERROR")
        })

        it('should credit pop rewards for existing pool', async () => {
            const { stakingProxy, pop, newPoolAddress } = await setupTests()
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            // TODO: pool must stake on itself first, must develop adapter
            await expect(
                pop.creditPopRewardToStakingProxy(newPoolAddress)
            ).to.be.revertedWith("POP_STAKING_POOL_BALANCES_NULL_ERROR")
        })

        it('should revert if pool not registered', async () => {
            const { stakingProxy, pop } = await setupTests()
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            // TODO: pool must stake on itself first, must develop adapter
            await expect(
                pop.creditPopRewardToStakingProxy(AddressZero)
            ).to.be.revertedWith("POP_STAKING_POOL_BALANCES_NULL_ERROR")
        })
    })

    describe("proofOfPerformance", async () => {
        // TODO: will return 0 until pool has positive active stake
        it('should return value of pop reward', async () => {
            const { stakingProxy, pop, newPoolAddress } = await setupTests()
            expect(await pop.proofOfPerformance(newPoolAddress)).to.be.eq(0)
        })
    })

    describe("getStakingPoolStatsThisEpoch", async () => {
        // TODO: will return 0 until pool has positive active stake
        it('should return staking pool earned rewards', async () => {
            const { stakingProxy, poolId } = await setupTests()
            const poolStats = await stakingProxy.getStakingPoolStatsThisEpoch(poolId)
            expect(poolStats.feesCollected).to.be.eq(0)
            expect(poolStats.weightedStake).to.be.eq(0)
            expect(poolStats.membersStake).to.be.eq(0)
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
