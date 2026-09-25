import { expect } from "chai";
import { network } from "hardhat";
import { Contract, ZeroAddress, parseEther } from "ethers";
import { getFixedGasSigners } from "../shared/helper";
import { createFixture } from "../utils/fixtures";
import { deployContract, timeTravel } from "../utils/utils";

describe("RogueStakingProxy", async () => {
  const setupTests = createFixture(["tests-setup"], async ({ get }) => {
    const [user1] = await getFixedGasSigners();
    const { ethers } = await network.getOrCreate();
    const factory = await ethers.getContractAt(
      "RigoblockPoolProxyFactory",
      (await get("RigoblockPoolProxyFactory")).address,
    );
    const rogueImplementation = await ethers.deployContract("RogueStaking");
    const { newPoolAddress, poolId } = await factory.createPool.staticCall(
      "testpool",
      "TEST",
      ZeroAddress,
    );
    await factory.createPool("testpool", "TEST", ZeroAddress);
    return {
      inflation: await ethers.getContractAt(
        "Inflation",
        (await get("Inflation")).address,
      ),
      inflationL2Address: (await get("InflationL2")).address,
      rigoToken: await ethers.getContractAt(
        "RigoToken",
        (await get("RigoToken")).address,
      ),
      stakingProxy: await ethers.getContractAt(
        "Staking",
        (await get("StakingProxy")).address,
      ),
      stakingProxyAddress: (await get("StakingProxy")).address,
      rogueImplementation,
      newPoolAddress,
      poolId,
      user1,
    };
  });

  describe("endEpoch", async () => {
    // this test should assure that a rogue upgrade of staking implementation won't affect token issuance
    it("should revert in inflation on time anomalies", async () => {
      const {
        inflation,
        stakingProxy,
        rigoToken,
        rogueImplementation,
        stakingProxyAddress,
        user1,
      } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const proxy = await ethers.getContractAt(
        "StakingProxy",
        stakingProxyAddress,
      );
      const rogueProxy = await ethers.getContractAt(
        "RogueStaking",
        stakingProxyAddress,
      );
      await proxy.addAuthorizedAddress(user1.address);
      await expect(proxy.detachStakingContract()).to.emit(
        proxy,
        "StakingContractDetachedFromProxy",
      );
      await expect(stakingProxy.endEpoch()).to.be.revertedWith(
        "STAKING_ADDRESS_NULL_ERROR",
      );
      await expect(
        proxy.attachStakingContract(await rogueImplementation.getAddress()),
      )
        .to.be.emit(proxy, "StakingContractAttachedToProxy")
        .withArgs(await rogueImplementation.getAddress());
      await rogueProxy.setInflation(await inflation.getAddress());
      // max 90 days duration
      await rogueProxy.setDuration(77760001);
      await expect(rogueProxy.endEpoch()).to.be.revertedWith(
        "INFLATION_TIME_ANOMALY_ERROR",
      );
      // min 5 days duration
      await rogueProxy.setDuration(431999);
      await expect(rogueProxy.endEpoch()).to.be.revertedWith(
        "INFLATION_TIME_ANOMALY_ERROR",
      );
      await rogueProxy.setDuration(432000);
      await expect(rogueProxy.endEpoch()).to.emit(rigoToken, "TokenMinted");
      await expect(rogueProxy.endEpoch()).to.be.revertedWith(
        "INFLATION_EPOCH_END_ERROR",
      );
      await timeTravel({ days: 5, mine: true });
      const mintAmount = await rogueProxy.getInflation();
      expect(await rogueProxy.endEpoch.staticCall()).to.be.eq(mintAmount);
      await expect(rogueProxy.endEpoch())
        .to.emit(rigoToken, "TokenMinted")
        .withArgs(stakingProxyAddress, mintAmount);
      await expect(rogueProxy.endEpoch()).to.be.revertedWith(
        "INFLATION_EPOCH_END_ERROR",
      );
    });

    it("should revert in L2 inflation on time anomalies", async () => {
      const {
        stakingProxy,
        stakingProxyAddress,
        inflationL2Address,
        rigoToken,
        rogueImplementation,
        user1,
      } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const proxy = await ethers.getContractAt(
        "StakingProxy",
        stakingProxyAddress,
      );
      await proxy.addAuthorizedAddress(user1.address);
      const rogueProxy = await ethers.getContractAt(
        "RogueStaking",
        stakingProxyAddress,
      );
      await proxy.detachStakingContract();
      await proxy.attachStakingContract(await rogueImplementation.getAddress());
      const inflationL2 = await ethers.getContractAt(
        "InflationL2",
        inflationL2Address,
      );
      await inflationL2.initParams(
        await rigoToken.getAddress(),
        await stakingProxy.getAddress(),
      );
      await rogueProxy.setInflation(inflationL2Address);
      // max 90 days duration
      await rogueProxy.setDuration(77760001);
      await expect(rogueProxy.endEpoch()).to.be.revertedWith(
        "INFLATION_TIME_ANOMALY_ERROR",
      );
      // min 5 days duration
      await rogueProxy.setDuration(431999);
      await expect(rogueProxy.endEpoch()).to.be.revertedWith(
        "INFLATION_TIME_ANOMALY_ERROR",
      );
      await rogueProxy.setDuration(432000);
      await rogueProxy.endEpoch();
      await timeTravel({ days: 5, mine: true });
      const mintAmount = await rogueProxy.getInflation();
      expect(mintAmount).to.be.not.eq(0n);
      // L2 minted tokens are 0 until tokens are transferred to L2 inflation contract
      expect(await rogueProxy.endEpoch.staticCall()).to.be.eq(0n);
      await rogueProxy.endEpoch();
      await expect(rogueProxy.endEpoch()).to.be.revertedWith(
        "INFLATION_EPOCH_END_ERROR",
      );
    });
  });

  describe("attachStakingContract", async () => {
    it("should not attach staking with invalid params", async () => {
      const { stakingProxyAddress, user1 } = await setupTests();
      const { ethers } = await network.getOrCreate();
      // we want to interact with the proxy-specific methods
      const proxy = await ethers.getContractAt(
        "StakingProxy",
        stakingProxyAddress,
      );
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
            }`;
      const rogueImplementation = await deployContract(user1 as any, source);
      // original spec relied on state leaked from earlier tests (user1 authorized);
      // fixtures reset state, so we authorize explicitly to keep the test self-contained
      await proxy.addAuthorizedAddress(user1.address);
      await expect(proxy.detachStakingContract()).to.emit(
        proxy,
        "StakingContractDetachedFromProxy",
      );
      const rogueProxy = new Contract(
        stakingProxyAddress,
        rogueImplementation.interface,
        user1,
      ) as any;
      await expect(rogueProxy.init()).to.be.revertedWith(
        "STAKING_ADDRESS_NULL_ERROR",
      );
      await expect(
        proxy.attachStakingContract(await rogueImplementation.getAddress()),
      ).to.be.revertedWith("STAKING_PROXY_INVALID_EPOCH_DURATION_ERROR");
    });

    it("should revert if staking did not succeed", async () => {
      const { stakingProxyAddress, user1 } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const proxy = await ethers.getContractAt(
        "StakingProxy",
        stakingProxyAddress,
      );
      const source = `
            contract RogueStaking {
                function init() public { revert("STAKING_INIT_FAILED_ERROR"); }
            }`;
      const rogueImplementation = await deployContract(user1 as any, source);
      // original spec relied on state leaked from earlier tests (user1 authorized);
      // fixtures reset state, so we authorize explicitly to keep the test self-contained
      await proxy.addAuthorizedAddress(user1.address);
      await proxy.detachStakingContract();
      await expect(
        proxy.attachStakingContract(await rogueImplementation.getAddress()),
      ).to.be.revertedWith("STAKING_INIT_FAILED_ERROR");
    });
  });

  describe("attachStakingContract", async () => {
    it("should revert if staking did not succeed", async () => {
      const { rogueImplementation, stakingProxyAddress, user1 } =
        await setupTests();
      const { ethers } = await network.getOrCreate();
      // we want to interact with the proxy-specific methods
      const proxy = await ethers.getContractAt(
        "StakingProxy",
        stakingProxyAddress,
      );
      await proxy.addAuthorizedAddress(user1.address);
      await expect(proxy.detachStakingContract()).to.emit(
        proxy,
        "StakingContractDetachedFromProxy",
      );
      await expect(
        proxy.attachStakingContract(await rogueImplementation.getAddress()),
      )
        .to.emit(proxy, "StakingContractAttachedToProxy")
        .withArgs(await rogueImplementation.getAddress());
      const rogueProxy = await ethers.getContractAt(
        "RogueStaking",
        stakingProxyAddress,
      );
      // following assertion will only revert with error, without return if not error
      await proxy.assertValidStorageParams();
      await rogueProxy.setAlphaNum(4);
      await expect(proxy.assertValidStorageParams()).to.be.revertedWith(
        "STAKING_PROXY_INVALID_COBB_DOUGLAS_ALPHA_ERROR",
      );
      await rogueProxy.setAlphaNum(2);
      await proxy.assertValidStorageParams();
      await rogueProxy.setAlphaDenom(0);
      await expect(proxy.assertValidStorageParams()).to.be.revertedWith(
        "STAKING_PROXY_INVALID_COBB_DOUGLAS_ALPHA_ERROR",
      );
      await rogueProxy.setAlphaDenom(3);
      await proxy.assertValidStorageParams();
      await rogueProxy.setStakeWeight(1000001);
      await expect(proxy.assertValidStorageParams()).to.be.revertedWith(
        "STAKING_PROXY_INVALID_STAKE_WEIGHT_ERROR",
      );
      await rogueProxy.setStakeWeight(1000000);
      await proxy.assertValidStorageParams();
      // following assertion should require minimum stake to be higher than 1e18 but deployed staking proxy
      //  cannot be update and it is not critical. It makes sure that a pull with null delegated stake cannot receive rewards.
      await rogueProxy.setMinimumStake(1);
      await expect(proxy.assertValidStorageParams()).to.be.revertedWith(
        "STAKING_PROXY_INVALID_MINIMUM_STAKE_ERROR",
      );
      await rogueProxy.setMinimumStake(parseEther("2"));
      await proxy.assertValidStorageParams();
    });
  });
});
