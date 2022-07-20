import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber, Contract } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { getAddress } from "ethers/lib/utils";

describe("StakingProxy-Stake", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        const GrgTokenInstance = await deployments.get("RigoToken")
        const GrgToken = await hre.ethers.getContractFactory("RigoToken")
        const GrgVaultInstance = await deployments.get("GrgVault")
        const GrgVault = await hre.ethers.getContractFactory("GrgVault")
        const StakingProxyInstance = await deployments.get("StakingProxy")
        const Staking = await hre.ethers.getContractFactory("Staking")
        const GrgTransferProxyInstance = await deployments.get("ERC20Proxy")
        const factory = Factory.attach(RigoblockPoolProxyFactory.address)
        const { newPoolAddress, poolId } = await factory.callStatic.createPool(
            'testpool',
            'TEST',
            AddressZero
        )
        await factory.createPool('testpool','TEST',AddressZero)
        return {
            grgToken: GrgToken.attach(GrgTokenInstance.address),
            grgVault: GrgVault.attach(GrgVaultInstance.address),
            stakingProxy: Staking.attach(StakingProxyInstance.address),
            grgTransferProxyAddress: GrgTransferProxyInstance.address,
            newPoolAddress,
            poolId
        }
    });

    describe("stake", async () => {
        it('should stake 100 GRG', async () => {
            const { grgToken, stakingProxy, grgTransferProxyAddress, grgVault } = await setupTests()
            const amount = parseEther("100")
            await grgToken.approve(grgTransferProxyAddress, amount)
            await expect(
                stakingProxy.stake(amount)).to.emit(grgVault, "Deposit"
            ).withArgs(user1.address, amount)
        })

        // pool initialization in epoch will fail if all pool delegated below minimum
        it('should allow staking below minimum', async () => {
            const { grgToken, stakingProxy, grgTransferProxyAddress } = await setupTests()
            const amount = parseEther("0.1")
            await grgToken.approve(grgTransferProxyAddress, amount)
            await expect(
                stakingProxy.stake(amount)).to.emit(stakingProxy, "Stake"
            ).withArgs(user1.address, amount)
        })

        it('should revert if allowance not set to staking proxy', async () => {
            const { grgToken, stakingProxy, grgTransferProxyAddress, newPoolAddress, poolId } = await setupTests()
            const amount = parseEther("100")
            await expect(
                stakingProxy.stake(amount)
            ).to.be.revertedWith("TRANSFER_FAILED")
            await grgToken.approve(grgTransferProxyAddress, amount)
            await expect(
                stakingProxy.stake(amount)).to.emit(stakingProxy, "Stake"
            ).withArgs(user1.address, amount)
        })

        it('should revert if GRG balance not enough', async () => {
            const { grgToken, stakingProxy, grgTransferProxyAddress, newPoolAddress, poolId } = await setupTests()
            const amount = parseEther("100")
            await grgToken.connect(user2).approve(grgTransferProxyAddress, amount)
            await expect(
                stakingProxy.stake(amount)
            ).to.be.revertedWith("TRANSFER_FAILED")
            await grgToken.transfer(user2.address, amount)
            await expect(
                stakingProxy.connect(user2).stake(amount)).to.emit(stakingProxy, "Stake"
            ).withArgs(user2.address, amount)
        })
    })

    describe("unstake", async () => {
        it('should unstake staked undelegated balance', async () => {
            const { grgToken, stakingProxy, grgTransferProxyAddress, grgVault } = await setupTests()
            const amount = parseEther("100")
            await grgToken.approve(grgTransferProxyAddress, amount)
            await stakingProxy.stake(amount)
            const withdrawAmount = parseEther("50")
            await expect(
                stakingProxy.unstake(withdrawAmount)
            ).to.emit(stakingProxy, "Unstake").withArgs(user1.address, withdrawAmount)
            await expect(
                stakingProxy.unstake(withdrawAmount)
            ).to.emit(grgToken, "Transfer").withArgs(grgVault.address, user1.address, withdrawAmount)
            await expect(
                stakingProxy.unstake(withdrawAmount)
            ).to.be.revertedWith("MOVE_STAKE_AMOUNT_HIGHER_THAN_WITHDRAWABLE_ERROR")
        })
    })

    describe("moveStake", async () => {
        it('should revert if 0 amount delegated', async () => {
            const { grgToken, stakingProxy, grgTransferProxyAddress, newPoolAddress, poolId } = await setupTests()
            const amount = parseEther("100")
            await grgToken.approve(grgTransferProxyAddress, amount)
            await stakingProxy.stake(amount)
            await stakingProxy.createStakingPool(newPoolAddress)
            const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId)
            const toInfo = new StakeInfo(StakeStatus.Delegated, poolId)
            await expect(
              stakingProxy.moveStake(fromInfo, toInfo, 0)
            ).to.be.revertedWith("MOVE_STAKE_AMOUNT_NULL_ERROR")
        })

        it('should revert if stake status remains undelegated', async () => {
            const { grgToken, stakingProxy, grgTransferProxyAddress, newPoolAddress, poolId } = await setupTests()
            const amount = parseEther("100")
            await grgToken.approve(grgTransferProxyAddress, amount)
            await stakingProxy.stake(amount)
            await stakingProxy.createStakingPool(newPoolAddress)
            const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId)
            const toInfo = new StakeInfo(StakeStatus.Undelegated, poolId)
            await expect(
              stakingProxy.moveStake(fromInfo, toInfo, amount)
            ).to.be.revertedWith("MOVE_STAKE_UNDELEGATED_STATUS_UNCHANGED_ERROR")
        })

        it('should delegate staked amount', async () => {
            const { grgToken, stakingProxy, grgTransferProxyAddress, newPoolAddress, poolId } = await setupTests()
            const amount = parseEther("100")
            await grgToken.approve(grgTransferProxyAddress, amount)
            await stakingProxy.stake(amount)
            await stakingProxy.createStakingPool(newPoolAddress)
            const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId)
            const toInfo = new StakeInfo(StakeStatus.Delegated, poolId)
            await expect(
              stakingProxy.moveStake(fromInfo, toInfo, amount)
            ).to.emit(stakingProxy, "MoveStake")
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
