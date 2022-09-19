import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber, Contract } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { timeTravel } from "../utils/utils";
import { getAddress } from "ethers/lib/utils";

describe("AStaking", async () => {
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
        const AuthorityCoreInstance = await deployments.get("AuthorityCore")
        const AuthorityCore = await hre.ethers.getContractFactory("AuthorityCore")
        const AStakingInstance = await deployments.get("AStaking")
        const authority = AuthorityCore.attach(AuthorityCoreInstance.address)
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
            poolId
        }
    });

    describe("unstake", async () => {
        it('should revert if null stake', async () => {
            const { stakingProxy, pop, grgToken, newPoolAddress } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AStaking")
            const pool = Pool.attach(newPoolAddress)
            const amount = 100
            await expect(pool.unstake(amount)).to.be.revertedWith("MOVE_STAKE_AMOUNT_HIGHER_THAN_WITHDRAWABLE_ERROR")
        })

        it('should revert if null withdrawable stake', async () => {
            const { stakingProxy, pop, grgToken, newPoolAddress } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AStaking")
            const pool = Pool.attach(newPoolAddress)
            const amount = parseEther("100")
            await grgToken.transfer(newPoolAddress, amount)
            await pool.stake(amount)
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            await expect(pool.unstake(amount)).to.be.revertedWith("MOVE_STAKE_AMOUNT_HIGHER_THAN_WITHDRAWABLE_ERROR")
        })

        it('should unstake withdrawable amount', async () => {
            const { stakingProxy, pop, grgToken, newPoolAddress } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AStaking")
            const pool = Pool.attach(newPoolAddress)
            const amount = parseEther("100")
            await grgToken.transfer(newPoolAddress, amount)
            await pool.stake(amount)
            await pool.undelegateStake(amount)
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            await expect(pool.unstake(amount.mul(2))).to.be.revertedWith("MOVE_STAKE_AMOUNT_HIGHER_THAN_WITHDRAWABLE_ERROR")
            await expect(pool.unstake(amount)).to.emit(stakingProxy, "Unstake").withArgs(newPoolAddress, amount)
        })
    })

    // TODO: test withdraw positive reward
    describe("withdraw rewards", async () => {
        it('withdraw delegator rewards', async () => {
            const { stakingProxy, pop, grgToken, newPoolAddress } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AStaking")
            const pool = Pool.attach(newPoolAddress)
            // transaction will success if null rewards
            await pool.withdrawDelegatorRewards()
        })
    })
})
