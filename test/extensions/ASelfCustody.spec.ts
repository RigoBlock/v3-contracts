import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber, Contract } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { timeTravel } from "../utils/utils";
import { getAddress } from "ethers/lib/utils";

describe("ASelfCustody", async () => {
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
        const AuthorityCoreInstance = await deployments.get("AuthorityCore")
        const AuthorityCore = await hre.ethers.getContractFactory("AuthorityCore")
        const AStakingInstance = await deployments.get("AStaking")
        const authority = AuthorityCore.attach(AuthorityCoreInstance.address)
        //"a694fc3a": "stake(uint256)"
        await authority.addMethod("0xa694fc3a", AStakingInstance.address)
        const ASelfCustodyInstance = await deployments.get("ASelfCustody")
        await authority.setAdapter(ASelfCustodyInstance.address, true)
        //"318698a7": "transferToSelfCustody(address,address,uint256)"
        await authority.addMethod("0x318698a7", ASelfCustodyInstance.address)
        //"6d6b09e9": "poolGrgShortfall(address)"
        await authority.addMethod("0x6d6b09e9", ASelfCustodyInstance.address)
        //"6ac91666": "GRG_VAULT_ADDRESS()"
        await authority.addMethod("0x6ac91666", ASelfCustodyInstance.address)
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
    })

    describe("transferToSelfCustody", async () => {
        it('should revert without active stake', async () => {
            const { stakingProxy, grgToken, grgVault, newPoolAddress, poolId } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AStaking")
            const pool = Pool.attach(newPoolAddress)
            let amount = parseEther("100")
            await grgToken.transfer(newPoolAddress, amount)
            await pool.stake(amount)
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            const ScPool = await hre.ethers.getContractFactory("ASelfCustody")
            const scPool = ScPool.attach(newPoolAddress)
            expect(await scPool.poolGrgShortfall(newPoolAddress)).to.be.not.eq(0)
            await expect(
                scPool.transferToSelfCustody(user2.address, grgToken.address, 10000)
            ).to.be.revertedWith("ASELFCUSTODY_MINIMUM_GRG_ERROR")
            amount = parseEther("100000")
            await grgToken.transfer(newPoolAddress, amount)
            await pool.stake(amount)
            await expect(
                scPool.poolGrgShortfall(newPoolAddress)
            ).to.be.revertedWith("ASELFCUSTODY_GRG_BALANCE_MISMATCH_ERROR")
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            expect(await scPool.poolGrgShortfall(newPoolAddress)).to.be.eq(0)
            const grgVaultAddress = await scPool.GRG_VAULT_ADDRESS()
            expect(await stakingProxy.getGrgVault()).to.be.eq(grgVaultAddress)
            const delegatedBalance = await stakingProxy.getTotalStakeDelegatedToPool(poolId)
            expect(await grgVault.balanceOf(newPoolAddress)).to.be.eq(delegatedBalance.currentEpochBalance)
            await expect(
                scPool.transferToSelfCustody(user2.address, grgToken.address, 10000)
            ).to.be.revertedWith("ASELFCUSTODY_TRANSFER_FAILED_ERROR")
            await expect(
                scPool.transferToSelfCustody(user2.address, AddressZero, 10000)
            ).to.be.revertedWith("ASELFCUSTODY_BALANCE_NOT_ENOUGH_ERROR")
            await grgToken.transfer(newPoolAddress, 10000)
            await expect(
                scPool.transferToSelfCustody(user2.address, grgToken.address, 0)
            ).to.be.revertedWith("ASELFCUSTODY_NULL_AMOUNT_ERROR")
            await expect(
                scPool.transferToSelfCustody(user2.address, grgToken.address, 10000)
            ).to.emit(scPool, "SelfCustodyTransfer").withArgs(
                newPoolAddress,
                user2.address,
                grgToken.address,
                10000
            ).to.emit(grgToken, "Transfer").withArgs(newPoolAddress, user2.address, 10000)
            const DefaultPool = await hre.ethers.getContractFactory("RigoblockV3Pool")
            const defaultPool = DefaultPool.attach(newPoolAddress)
            // we make sure pool has enough eth
            await defaultPool.mint(user1.address, parseEther("1"), 0, { value: parseEther("1") })
            await expect(
                scPool.transferToSelfCustody(user2.address, AddressZero, 10000)
            ).to.emit(scPool, "SelfCustodyTransfer").withArgs(
                newPoolAddress,
                user2.address,
                AddressZero,
                10000
            )
        })
    })

    describe("poolGrgShortfall", async () => {
        it('should return pool shortfall when caller is not owner', async () => {
            const { stakingProxy, grgToken, grgVault, newPoolAddress, poolId } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AStaking")
            const pool = Pool.attach(newPoolAddress)
            let amount = parseEther("100")
            await grgToken.transfer(newPoolAddress, amount)
            await pool.stake(amount)
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            const ScPool = await hre.ethers.getContractFactory("ASelfCustody")
            const scPool = ScPool.attach(newPoolAddress)
            expect(await scPool.connect(user2).poolGrgShortfall(newPoolAddress)).to.be.not.eq(0)
        })
    })
})
