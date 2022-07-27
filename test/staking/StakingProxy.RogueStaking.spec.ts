import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber, Contract } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { deployContract, timeTravel } from "../utils/utils";
import { getAddress } from "ethers/lib/utils";

describe("StakingProxy", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        const StakingProxyInstance = await deployments.get("StakingProxy")
        const Staking = await hre.ethers.getContractFactory("Staking")
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
            newPoolAddress,
            poolId
        }
    });

    describe("endEpoch", async () => {
        // this test should assure that a rogue upgrade of staking implementation won't affect token issuance
        it('should revert in inflation on time anomalies', async () => {
            const { inflation, stakingProxy, rigoToken } = await setupTests()
            const StakingProxyInstance = await deployments.get("StakingProxy")
            const StakingProxy = await hre.ethers.getContractFactory("StakingProxy")
            const proxy = StakingProxy.attach(StakingProxyInstance.address)
            // we must preserve storage in order to overwrite the correct storage slot
            // unfortunately we must declare all preceding variables
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
                uint32 public rewardDelegatedStakeWeight; // 1e15
                uint256 public minimumPoolStake; // 1e19
                uint32 public cobbDouglasAlphaNumerator; // 2
                uint32 public cobbDouglasAlphaDenominator; // 3
                address public inflation;
                struct PoolStats { uint256 feesCollected; uint256 weightedStake; uint256 membersStake; }
                struct AggregatedStats { uint256 rewardsAvailable; uint256 numPoolsToFinalize; uint256 totalFeesCollected; uint256 totalWeightedStake; uint256 totalRewardsFinalized; }
                struct StoredBalance { uint64 currentEpoch; uint96 currentEpochBalance; uint96 nextEpochBalance; }
                struct Pool { address operator; address stakingPal; uint32 operatorShare; uint32 stakingPalShare; }
                struct Fraction { uint256 numerator; uint256 denominator; }
                function init() public {}
                function setDuration(uint256 _duration) public { epochDurationInSeconds = _duration; }
                function setStaking(address _staking) public { stakingContract = _staking; }
                function setInflation(address _inflation) public { inflation = _inflation; }
                function endEpoch() public returns (uint256) {
                    bytes4 selector = bytes4(keccak256(bytes("mintInflation()")));
                    bytes memory encodedCall = abi.encodeWithSelector(selector);
                    (bool success, bytes memory data) = inflation.call(encodedCall);
                    if (!success) { revert(string(data)); } return uint256(bytes32(data));
                }
                function getInflation() public view returns (uint256) {
                    bytes4 selector = bytes4(keccak256(bytes("getEpochInflation()")));
                    bytes memory encodedCall = abi.encodeWithSelector(selector);
                    ( , bytes memory data) = inflation.staticcall(encodedCall);
                    return uint256(bytes32(data));
                }
                function getParams() external view returns (uint256, uint32, uint256, uint32, uint32) {
                    return (epochDurationInSeconds, 1, 1, 1, 1);
                }
            }`
            const rogueImplementation = await deployContract(user1, source)
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
    })

    describe("attachStakingContract", async () => {
        it('should not attach staking with invalid params', async () => {
            const { inflation, stakingProxy, rigoToken } = await setupTests()
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
            await proxy.addAuthorizedAddress(user1.address)
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
            const { inflation, stakingProxy, rigoToken } = await setupTests()
            const StakingProxyInstance = await deployments.get("StakingProxy")
            const StakingProxy = await hre.ethers.getContractFactory("StakingProxy")
            const proxy = StakingProxy.attach(StakingProxyInstance.address)
            const source = `
            contract RogueStaking {
                function init() public { revert("STAKING_INIT_FAILED_ERROR"); }
            }`
            const rogueImplementation = await deployContract(user1, source)
            await proxy.addAuthorizedAddress(user1.address)
            await proxy.detachStakingContract()
            const rogueProxy = rogueImplementation.attach(proxy.address)
            await expect(
                proxy.attachStakingContract(rogueImplementation.address)
            ).to.be.revertedWith("STAKING_INIT_FAILED_ERROR")
        })
    })
})
