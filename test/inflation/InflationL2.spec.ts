import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber, Contract } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { deployContract, timeTravel } from "../utils/utils";
import { getAddress } from "ethers/lib/utils";

describe("InflationL2", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        const StakingProxyInstance = await deployments.get("StakingProxy")
        const Staking = await hre.ethers.getContractFactory("Staking")
        const RigoTokenInstance = await deployments.get("RigoToken")
        const RigoToken = await hre.ethers.getContractFactory("RigoToken")
        const InflationL2 = await hre.ethers.getContractFactory("InflationL2")
        const inflation = await InflationL2.deploy(RigoTokenInstance.address, StakingProxyInstance.address)
        const rigoToken = RigoToken.attach(RigoTokenInstance.address)
        await rigoToken.changeMintingAddress(inflation.address)
        const factory = Factory.attach(RigoblockPoolProxyFactory.address)
        const { newPoolAddress, poolId } = await factory.callStatic.createPool(
            'testpool',
            'TEST',
            AddressZero
        )
        await factory.createPool('testpool','TEST',AddressZero)
        return {
            inflation, //: Inflation.attach(InflationInstance.address),
            rigoToken, //: RigoToken.attach(RigoTokenInstance.address),
            stakingProxy: Staking.attach(StakingProxyInstance.address),
            newPoolAddress,
            poolId
        }
    });

    describe("mintInflation", async () => {
        it('should revert if caller not staking proxy', async () => {
            const { inflation } = await setupTests()
            await expect(
                inflation.mintInflation()
            ).to.be.revertedWith("CALLER_NOT_STAKING_PROXY_ERROR")
        })

        it('should revert if epoch time shortened but time not enough', async () => {
            const { inflation, stakingProxy } = await setupTests()
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            const minimumPoolStake = parseEther("100") // 100 GRG
            await stakingProxy.addAuthorizedAddress(user1.address)
            await stakingProxy.setParams(
                432001,  //uint256 _epochDurationInSeconds,
                100,    //uint32 _rewardDelegatedStakeWeight,
                minimumPoolStake,    //uint256 _minimumPoolStake,
                2,      //uint32 _cobbDouglasAlphaNumerator,
                3       //uint32 _cobbDouglasAlphaDenominator
            )
            // error in inflation will never be returned as staking will revert first
            await expect(
                stakingProxy.endEpoch()
            ).to.be.revertedWith("STAKING_TIMESTAMP_TOO_LOW_ERROR")
        })

        it('should wait for epoch 2 before first mint', async () => {
            const { inflation, stakingProxy, rigoToken } = await setupTests()
            // _epochEndTime is initialized in storage only at first mint
            expect(await inflation.epochEnded()).to.be.eq(true)
            await expect(
                stakingProxy.endEpoch()
            ).to.be.revertedWith("STAKING_TIMESTAMP_TOO_LOW_ERROR")
            await timeTravel({ days: 14, mine:true })
            await expect(
                stakingProxy.endEpoch()
            ).to.emit(stakingProxy, "EpochFinalized").withArgs(1, 0, 0)
            // since staking proxy still does not call mint on inflation, _epochEndTime is still uninitialized
            expect(await inflation.epochEnded()).to.be.eq(true)
            expect(await rigoToken.balanceOf(stakingProxy.address)).to.be.eq(0)
            await timeTravel({ days: 14, mine:true })
            let nextMintAmount = await inflation.getEpochInflation()
            expect(nextMintAmount).to.be.eq(0)
            await expect(
                stakingProxy.endEpoch()
            ).to.emit(stakingProxy, "GrgMintEvent").withArgs(nextMintAmount)
            .to.emit(stakingProxy, "EpochFinalized").withArgs(2, 0, nextMintAmount)
            expect(await inflation.epochEnded()).to.be.eq(false)
            let mintedAmount = await rigoToken.balanceOf(stakingProxy.address)
            // mint amount returns 0 as contract has null GRG balance
            expect(mintedAmount).to.be.eq(0)
            nextMintAmount = await inflation.getEpochInflation()
            let tokenAmount = parseEther("500")
            await rigoToken.transfer(inflation.address, tokenAmount)
            await timeTravel({ days: 14, mine:true })
            let rewardsAvailable = BigInt(mintedAmount) + BigInt(nextMintAmount)
            await expect(
                stakingProxy.endEpoch()
            ).to.emit(stakingProxy, "EpochFinalized").withArgs(3, 0, tokenAmount)
            .to.emit(stakingProxy, "GrgMintEvent").withArgs(tokenAmount)
            mintedAmount = await rigoToken.balanceOf(stakingProxy.address)
            // because inflation contract balance is lower than reward, the minted amount is lower
            expect(mintedAmount).to.be.lt(rewardsAvailable)
            expect(mintedAmount).to.be.eq(tokenAmount)
            nextMintAmount = await inflation.getEpochInflation()
            // this time we transfer enough GRG to enable full epoch reward
            tokenAmount = parseEther("50000")
            await rigoToken.transfer(inflation.address, tokenAmount)
            await timeTravel({ days: 14, mine:true })
            rewardsAvailable = BigInt(mintedAmount) + BigInt(nextMintAmount)
            await expect(
                stakingProxy.endEpoch()
            ).to.emit(stakingProxy, "EpochFinalized").withArgs(4, 0, rewardsAvailable)
            .to.emit(stakingProxy, "GrgMintEvent").withArgs(nextMintAmount)
            mintedAmount = await rigoToken.balanceOf(stakingProxy.address)
            expect(mintedAmount).to.be.eq(rewardsAvailable)
            expect(mintedAmount).to.be.not.eq(0)
            expect(mintedAmount).to.be.lt(tokenAmount)
        })

        // when deploying on alt-chains we must set rigoblock dao to address 0 in Rigo token after setup
        //  if GRG not standard token without token mint on L2.
        it('should not allow changing rigoblock address in grg after set to 0', async () => {
            const { inflation, stakingProxy, rigoToken } = await setupTests()
            expect(await rigoToken.minter()).to.be.eq(inflation.address)
            await expect(rigoToken.mintToken(AddressZero, 5)).to.be.reverted
            await rigoToken.changeMintingAddress(user2.address)
            await expect(
                rigoToken.connect(user2).mintToken(AddressZero, 5)
            ).to.emit(rigoToken, "TokenMinted").withArgs(AddressZero, 5)
            // GRG does not return rich errors. Note: we set minter to 0 after initial setup
            await rigoToken.changeRigoblockAddress(AddressZero)
            await expect(rigoToken.changeMintingAddress(user1.address)).to.be.reverted
            await expect(rigoToken.mintToken(AddressZero, 5)).to.be.reverted
        })
    })

    describe("timeUntilNextClaim", async () => {
        it('should return 0 before second epoch', async () => {
            const { inflation, stakingProxy } = await setupTests()
            expect(await inflation.timeUntilNextClaim()).to.be.eq(0)
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            expect(await inflation.timeUntilNextClaim()).to.be.eq(0)
        })

        it('should return positive amount after first claim, 0 after 14 days', async () => {
            const { inflation, stakingProxy } = await setupTests()
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            // after first epoch end will mint for the first time
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            expect(await inflation.timeUntilNextClaim()).to.be.not.eq(0)
            await timeTravel({ days: 14, mine:true })
            expect(await inflation.timeUntilNextClaim()).to.be.eq(0)
        })
    })

    describe("getEpochInflation", async () => {
        it('should return 0 before second epoch', async () => {
            const { inflation, stakingProxy } = await setupTests()
            // first epoch required to activate stake
            expect(await inflation.getEpochInflation()).to.be.eq(0)
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            expect(await inflation.getEpochInflation()).to.be.eq(0)
        })

        it('should return epoch inflation after first claim', async () => {
            const { inflation, stakingProxy, rigoToken } = await setupTests()
            // first epoch finalization will not mint as no active stake would be possible
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            expect(await inflation.getEpochInflation()).to.be.not.eq(0)
            const grgSupply = await rigoToken.totalSupply()
            const epochInflation = Number(grgSupply) * 2 / 100 * 14 / 365
            expect(Number(await inflation.getEpochInflation())).to.be.eq(epochInflation)
            // fixed amount per epoch regardless time of claim
            await timeTravel({ days: 7, mine:true })
            expect(Number(await inflation.getEpochInflation())).to.be.eq(epochInflation)
        })
    })
})
