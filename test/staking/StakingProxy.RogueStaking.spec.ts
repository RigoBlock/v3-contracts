import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber, Contract } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { deployContract, timeTravel } from "../utils/utils";
import { getAddress } from "ethers/lib/utils";

describe("RogueStakingProxy", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        const StakingProxyInstance = await deployments.get("StakingProxy")
        const Staking = await hre.ethers.getContractFactory("Staking")
        const RogueStaking = await hre.ethers.getContractFactory("RogueStaking")
        const rogueImplementation = await RogueStaking.deploy()
        const InflationInstance = await deployments.get("Inflation")
        const Inflation = await hre.ethers.getContractFactory("Inflation")
        const RigoTokenInstance = await deployments.get("RigoToken")
        const RigoToken = await hre.ethers.getContractFactory("RigoToken")
        const factory = Factory.attach(RigoblockPoolProxyFactory.address)
        const { newPoolAddress, poolId } = await factory.callStatic.createPool(
            'testpool',
            'TEST',
            AddressZero
        )
        await factory.createPool('testpool','TEST',AddressZero)
        return {
            inflation: Inflation.attach(InflationInstance.address),
            rigoToken: RigoToken.attach(RigoTokenInstance.address),
            stakingProxy: Staking.attach(StakingProxyInstance.address),
            rogueImplementation,
            newPoolAddress,
            poolId
        }
    });

    describe("endEpoch", async () => {
        // this test should assure that a rogue upgrade of staking implementation won't affect token issuance
        it('should revert in inflation on time anomalies', async () => {
            const { inflation, stakingProxy, rigoToken, rogueImplementation } = await setupTests()
            const StakingProxyInstance = await deployments.get("StakingProxy")
            const StakingProxy = await hre.ethers.getContractFactory("StakingProxy")
            const proxy = StakingProxy.attach(StakingProxyInstance.address)
            const rogueProxy = rogueImplementation.attach(proxy.address)
            await proxy.addAuthorizedAddress(user1.address)
            await expect(
                proxy.detachStakingContract()
            ).to.emit(proxy, "StakingContractDetachedFromProxy")
            await expect(stakingProxy.endEpoch()).to.be.revertedWith("STAKING_ADDRESS_NULL_ERROR")
            await expect(
                proxy.attachStakingContract(rogueImplementation.address)
            ).to.be.emit(proxy, "StakingContractAttachedToProxy").withArgs(rogueImplementation.address)
            await rogueProxy.setInflation(inflation.address)
            // max 90 days duration
            await rogueProxy.setDuration(77760001)
            await expect(rogueProxy.endEpoch()).to.be.revertedWith("INFLATION_TIME_ANOMALY_ERROR")
            // min 5 days duration
            await rogueProxy.setDuration(431999)
            await expect(rogueProxy.endEpoch()).to.be.revertedWith("INFLATION_TIME_ANOMALY_ERROR")
            await rogueProxy.setDuration(432000)
            await expect(rogueProxy.endEpoch()).to.emit(rigoToken, "TokenMinted")
            await expect(rogueProxy.endEpoch()).to.be.reverted
            await timeTravel({ days: 5, mine:true })
            const mintAmount = await rogueProxy.getInflation()
            expect(await rogueProxy.callStatic.endEpoch()).to.be.eq(mintAmount)
            await expect(rogueProxy.endEpoch()).to.emit(rigoToken, "TokenMinted").withArgs(proxy.address, mintAmount)
            await expect(rogueProxy.endEpoch()).to.be.revertedWith("INFLATION_EPOCH_END_ERROR")
        })

        it('should revert in L2 inflation on time anomalies', async () => {
            const { inflation, stakingProxy, rigoToken, rogueImplementation } = await setupTests()
            const StakingProxyInstance = await deployments.get("StakingProxy")
            const StakingProxy = await hre.ethers.getContractFactory("StakingProxy")
            const proxy = StakingProxy.attach(StakingProxyInstance.address)
            await proxy.addAuthorizedAddress(user1.address)
            const rogueProxy = rogueImplementation.attach(proxy.address)
            await proxy.detachStakingContract()
            await proxy.attachStakingContract(rogueImplementation.address)
            const InflationL2Instance = await deployments.get("InflationL2")
            const InflationL2 = await hre.ethers.getContractFactory("InflationL2")
            const inflationL2 = InflationL2.attach(InflationL2Instance.address)
            await inflationL2.initParams(rigoToken.address, stakingProxy.address)
            await rogueProxy.setInflation(inflationL2.address)
            // max 90 days duration
            await rogueProxy.setDuration(77760001)
            await expect(rogueProxy.endEpoch()).to.be.revertedWith("INFLATION_TIME_ANOMALY_ERROR")
            // min 5 days duration
            await rogueProxy.setDuration(431999)
            await expect(rogueProxy.endEpoch()).to.be.revertedWith("INFLATION_TIME_ANOMALY_ERROR")
            await rogueProxy.setDuration(432000)
            await rogueProxy.endEpoch()
            await timeTravel({ days: 5, mine:true })
            const mintAmount = await rogueProxy.getInflation()
            expect(mintAmount).to.be.not.eq(0)
            // L2 minted tokens are 0 until tokens are transferred to L2 inflation contract
            expect(await rogueProxy.callStatic.endEpoch()).to.be.eq(0)
            await rogueProxy.endEpoch()
            await expect(rogueProxy.endEpoch()).to.be.revertedWith("INFLATION_EPOCH_END_ERROR")
        })
    })

    describe("attachStakingContract", async () => {
        it('should not attach staking with invalid params', async () => {
            // we want to interact with the proxy-specific methods
            const StakingProxyInstance = await deployments.get("StakingProxy")
            const StakingProxy = await hre.ethers.getContractFactory("StakingProxy")
            const proxy = StakingProxy.attach(StakingProxyInstance.address)
            const source = `
            contract RogueStaking {
                address public owner;
                mapping(address => bool) public authorized;
                address[] public authorities;
                address public stakingContract;
                mapping(uint8 => StoredBalance) internal _globalStakeByStatus;
                mapping(uint8 => mapping(address => StoredBalance)) internal _ownerStakeByStatus;
                mapping(address => mapping(bytes32 => StoredBalance)) internal _delegatedStakeToPoolByOwner;
                mapping(bytes32 => StoredBalance) internal _delegatedStakeByPoolId;
                mapping(address => bytes32) public poolIdByRbPoolAccount;
                mapping(bytes32 => Pool) internal _poolById;
                mapping(bytes32 => uint256) public rewardsByPoolId;
                uint256 public currentEpoch;
                uint256 public currentEpochStartTimeInSeconds;
                mapping(bytes32 => mapping(uint256 => Fraction)) internal _cumulativeRewardsByPool;
                mapping(bytes32 => uint256) internal _cumulativeRewardsByPoolLastStored;
                mapping(address => bool) public validPops;
                uint256 public epochDurationInSeconds;
                struct StoredBalance { uint64 currentEpoch; uint96 currentEpochBalance; uint96 nextEpochBalance; }
                struct Pool { address operator; address stakingPal; uint32 operatorShare; uint32 stakingPalShare; }
                struct Fraction { uint256 numerator; uint256 denominator; }
                function init() public { epochDurationInSeconds = 0; }
            }`
            const rogueImplementation = await deployContract(user1, source)
            //await proxy.addAuthorizedAddress(user1.address)
            await expect(
                proxy.detachStakingContract()
            ).to.emit(proxy, "StakingContractDetachedFromProxy")
            const rogueProxy = rogueImplementation.attach(proxy.address)
            await expect(rogueProxy.init()).to.be.revertedWith("STAKING_ADDRESS_NULL_ERROR")
            await expect(
                proxy.attachStakingContract(rogueImplementation.address)
            ).to.be.revertedWith("STAKING_PROXY_INVALID_EPOCH_DURATION_ERROR")
        })

        it('should revert if staking did not succeed', async () => {
            const StakingProxyInstance = await deployments.get("StakingProxy")
            const StakingProxy = await hre.ethers.getContractFactory("StakingProxy")
            const proxy = StakingProxy.attach(StakingProxyInstance.address)
            const source = `
            contract RogueStaking {
                function init() public { revert("STAKING_INIT_FAILED_ERROR"); }
            }`
            const rogueImplementation = await deployContract(user1, source)
            //await proxy.addAuthorizedAddress(user1.address)
            await proxy.detachStakingContract()
            const rogueProxy = rogueImplementation.attach(proxy.address)
            await expect(
                proxy.attachStakingContract(rogueImplementation.address)
            ).to.be.revertedWith("STAKING_INIT_FAILED_ERROR")
        })
    })

    describe("attachStakingContract", async () => {
        it('should revert if staking did not succeed', async () => {
            const { rogueImplementation } = await setupTests()
            // we want to interact with the proxy-specific methods
            const StakingProxyInstance = await deployments.get("StakingProxy")
            const StakingProxy = await hre.ethers.getContractFactory("StakingProxy")
            const proxy = StakingProxy.attach(StakingProxyInstance.address)
            await proxy.addAuthorizedAddress(user1.address)
            await expect(
                proxy.detachStakingContract()
            ).to.emit(proxy, "StakingContractDetachedFromProxy")
            await expect(proxy.attachStakingContract(rogueImplementation.address))
                .to.emit(proxy, "StakingContractAttachedToProxy").withArgs(rogueImplementation.address)
            const rogueProxy = rogueImplementation.attach(proxy.address)
            // following assertion will only revert with error, without return if not error
            await proxy.assertValidStorageParams()
            await rogueProxy.setAlphaNum(4)
            await expect(proxy.assertValidStorageParams())
                .to.be.revertedWith("STAKING_PROXY_INVALID_COBB_DOUGLAS_ALPHA_ERROR")
            await rogueProxy.setAlphaNum(2)
            await proxy.assertValidStorageParams()
            await rogueProxy.setAlphaDenom(0)
            await expect(proxy.assertValidStorageParams())
                .to.be.revertedWith("STAKING_PROXY_INVALID_COBB_DOUGLAS_ALPHA_ERROR")
            await rogueProxy.setAlphaDenom(3)
            await proxy.assertValidStorageParams()
            await rogueProxy.setStakeWeight(1000001)
            await expect(proxy.assertValidStorageParams())
                .to.be.revertedWith("STAKING_PROXY_INVALID_STAKE_WEIGHT_ERROR")
            await rogueProxy.setStakeWeight(1000000)
            await proxy.assertValidStorageParams()
            // following assertion should require minimum stake to be higher than 1e18 but deployed staking proxy
            //  cannot be update and it is not critical. It makes sure that a pull with null delegated stake cannot receive rewards.
            await rogueProxy.setMinimumStake(1)
            await expect(proxy.assertValidStorageParams())
                .to.be.revertedWith("STAKING_PROXY_INVALID_MINIMUM_STAKE_ERROR")
            await rogueProxy.setMinimumStake(parseEther("2"))
            await proxy.assertValidStorageParams()
        })
    })
})
