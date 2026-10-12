import { expect } from "chai";
import { network } from "hardhat";
import { encodeBytes32String, parseEther, zeroPadValue } from "ethers";
import { getFixedGasSigners } from "../shared/helper";
import { createFixture } from "../utils/fixtures";
import {
  ProposedAction,
  StakeInfo,
  StakeStatus,
  TimeType,
  VoteType,
  timeTravel,
} from "../utils/utils";

describe("Governance Upgrades", async () => {
  const description = "gov proposal one";

  const setupTests = createFixture(["governance-tests"], async ({ get }) => {
    const { ethers } = await network.getOrCreate();
    const [user1, user2] = await getFixedGasSigners();
    const staking = await ethers.getContractAt(
      "Staking",
      (await get("StakingProxy")).address,
    );
    const governanceFactory = await ethers.getContractAt(
      "RigoblockGovernanceFactory",
      (await get("RigoblockGovernanceFactory")).address,
    );
    const implementation = (await get("RigoblockGovernance")).address;
    const strategy = (await get("RigoblockGovernanceStrategy")).address;
    const governance = await governanceFactory.createGovernance.staticCall(
      implementation,
      strategy,
      parseEther("100000"), // 100k GRG
      parseEther("1000000"), // 1MM GRG
      TimeType.Timestamp,
      "Rigoblock Governance",
    );
    await governanceFactory.createGovernance(
      implementation,
      strategy,
      parseEther("100000"), // 100k GRG
      parseEther("1000000"), // 1MM GRG
      TimeType.Timestamp,
      "Rigoblock Governance",
    );
    const governanceInstance = await ethers.getContractAt(
      "RigoblockGovernance",
      governance,
    );
    const mockPool = await ethers.deployContract("MockOwned");
    const authority = await ethers.getContractAt(
      "Authority",
      (await get("Authority")).address,
    );
    await authority.setFactory(user1.address, true);
    const registry = await ethers.getContractAt(
      "PoolRegistry",
      (await get("PoolRegistry")).address,
    );
    const poolAddress = await mockPool.getAddress();
    const poolId = encodeBytes32String("mock");
    await registry.register(poolAddress, "mock pool", "MOCK", poolId);
    const grgToken = await ethers.getContractAt(
      "RigoToken",
      (await get("RigoToken")).address,
    );
    const grgTransferProxyAddress = (await get("ERC20Proxy")).address;
    // we do the setup for creating a proposal, which will be executable during voting epoch as voting from only staker with quorum
    const amount = parseEther("1000000");
    await grgToken.approve(grgTransferProxyAddress, amount);
    await staking.stake(amount);
    await staking.createStakingPool(poolAddress);
    const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
    const toInfo = new StakeInfo(StakeStatus.Delegated, poolId);
    await staking.moveStake(fromInfo, toInfo, amount);
    await timeTravel({ days: 14, mine: true });
    await staking.endEpoch();
    return {
      governanceInstance,
      implementation,
      staking,
      strategy,
      user2,
    };
  });

  describe("upgradeImplementation", async () => {
    it("should revert if not called by governance itself", async () => {
      const { governanceInstance, user2 } = await setupTests();
      await expect(
        governanceInstance.upgradeImplementation(user2.address),
      ).to.be.revertedWithCustomError(
        governanceInstance,
        "GovernorOnlyExecutor",
      );
    });

    it("should revert if new implementation same as current", async () => {
      const { governanceInstance, implementation } = await setupTests();
      const data = governanceInstance.interface.encodeFunctionData(
        "upgradeImplementation(address)",
        [implementation],
      );
      const action = new ProposedAction(
        await governanceInstance.getAddress(),
        data,
        0n,
      );
      await governanceInstance.propose([action], description);
      expect(await governanceInstance.proposalCount()).to.be.eq(1n);
      await timeTravel({ days: 14, mine: true });
      await governanceInstance.castVote(1, 1);
      await timeTravel({ days: 7, mine: true });
      await expect(governanceInstance.execute(1)).to.be.revertedWithCustomError(
        governanceInstance,
        "GovUpgradeSameAsCurrent",
      );
    });

    it("should revert if target not contract", async () => {
      const { governanceInstance, user2 } = await setupTests();
      const data = governanceInstance.interface.encodeFunctionData(
        "upgradeImplementation(address)",
        [user2.address],
      );
      const action = new ProposedAction(
        await governanceInstance.getAddress(),
        data,
        0n,
      );
      await governanceInstance.propose([action], description);
      expect(await governanceInstance.proposalCount()).to.be.eq(1n);
      await timeTravel({ days: 14, mine: true });
      await governanceInstance.castVote(1, 1);
      await timeTravel({ days: 7, mine: true });
      await expect(governanceInstance.execute(1)).to.be.revertedWithCustomError(
        governanceInstance,
        "GovUpgradeNotContract",
      );
    });

    it("should upgrade implementation", async () => {
      const { governanceInstance } = await setupTests();
      const { ethers } = await network.getOrCreate();
      // 2 is the Wormhole chain id of Ethereum, the governance hub
      const newImplementation = await ethers.deployContract(
        "RigoblockGovernance",
        [2],
      );
      const newImplementationAddress = await newImplementation.getAddress();
      const data = governanceInstance.interface.encodeFunctionData(
        "upgradeImplementation(address)",
        [newImplementationAddress],
      );
      const action = new ProposedAction(
        await governanceInstance.getAddress(),
        data,
        0n,
      );
      await governanceInstance.propose([action], description);
      expect(await governanceInstance.proposalCount()).to.be.eq(1n);
      await timeTravel({ days: 14, mine: true });
      await governanceInstance.castVote(1, 1);
      await timeTravel({ days: 7, mine: true });
      await expect(governanceInstance.execute(1))
        .to.emit(governanceInstance, "Upgraded")
        .withArgs(newImplementationAddress);
      // the proxy EIP-1967 implementation slot must now delegate to the new implementation
      const implementationSlot =
        "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
      const { provider } = await network.getOrCreate();
      const storedImplementation = (await provider.request({
        method: "eth_getStorageAt",
        params: [
          await governanceInstance.getAddress(),
          implementationSlot,
          "latest",
        ],
      })) as string;
      expect(storedImplementation).to.eq(
        zeroPadValue(newImplementationAddress, 32),
      );
      // a view call through the proxy still works with the new implementation
      expect(await governanceInstance.proposalCount()).to.be.eq(1n);
    });
  });

  describe("upgradeStrategy", async () => {
    it("should revert if not called by governance itself", async () => {
      const { governanceInstance, user2 } = await setupTests();
      await expect(
        governanceInstance.upgradeStrategy(user2.address),
      ).to.be.revertedWithCustomError(
        governanceInstance,
        "GovernorOnlyExecutor",
      );
    });

    it("should revert if new strategy same as current", async () => {
      const { governanceInstance } = await setupTests();
      const strategy = (await governanceInstance.governanceParameters()).params
        .strategy;
      const data = governanceInstance.interface.encodeFunctionData(
        "upgradeStrategy(address)",
        [strategy],
      );
      const action = new ProposedAction(
        await governanceInstance.getAddress(),
        data,
        0n,
      );
      await timeTravel({ days: 9, mine: true });
      await governanceInstance.propose([action], description);
      expect(await governanceInstance.proposalCount()).to.be.eq(1n);
      // voting opens after 5 days
      await timeTravel({ days: 5, mine: true });
      await governanceInstance.castVote(1, 1);
      // proposal becomes executable 7 days after becoming active
      await timeTravel({ days: 7, mine: true });
      await expect(governanceInstance.execute(1)).to.be.revertedWithCustomError(
        governanceInstance,
        "GovUpgradeSameAsCurrent",
      );
    });

    it("should revert if target not contract", async () => {
      const { governanceInstance, user2 } = await setupTests();
      const data = governanceInstance.interface.encodeFunctionData(
        "upgradeStrategy(address)",
        [user2.address],
      );
      const action = new ProposedAction(
        await governanceInstance.getAddress(),
        data,
        0n,
      );
      await governanceInstance.propose([action], description);
      await timeTravel({ days: 14, mine: true });
      expect(await governanceInstance.proposalCount()).to.be.eq(1n);
      await governanceInstance.castVote(1, 1);
      await timeTravel({ days: 7, mine: true });
      await expect(governanceInstance.execute(1)).to.be.revertedWithCustomError(
        governanceInstance,
        "GovUpgradeNotContract",
      );
    });

    it("should upgrade strategy", async () => {
      const { governanceInstance, staking } = await setupTests();
      const stakingAddress = await staking.getAddress();
      const data = governanceInstance.interface.encodeFunctionData(
        "upgradeStrategy(address)",
        [stakingAddress],
      );
      const action = new ProposedAction(
        await governanceInstance.getAddress(),
        data,
        0n,
      );
      await governanceInstance.propose([action], description);
      expect(await governanceInstance.proposalCount()).to.be.eq(1n);
      await timeTravel({ days: 14, mine: true });
      await governanceInstance.castVote(1, 1);
      await timeTravel({ days: 7, mine: true });
      await expect(governanceInstance.execute(1))
        .to.emit(governanceInstance, "StrategyUpgraded")
        .withArgs(stakingAddress);
      // the new strategy must be stored in the governance parameters read through the proxy
      const storedStrategy = (await governanceInstance.governanceParameters())
        .params.strategy;
      expect(storedStrategy).to.eq(stakingAddress);
    });
  });

  describe("updateThresholds", async () => {
    it("should revert if not called by governance itself", async () => {
      const { governanceInstance } = await setupTests();
      await expect(
        governanceInstance.updateThresholds(1, 1),
      ).to.be.revertedWithCustomError(
        governanceInstance,
        "GovernorOnlyExecutor",
      );
    });

    it("should revert only when both new thresholds equal current", async () => {
      const { governanceInstance } = await setupTests();
      // threshold updates are validated at execution time via the strategy's validateParams,
      // so the proposed values must be within the supply-based bounds when they execute;
      // inflation grows the supply during the fixture setup, pushing the stored 100k proposal
      // threshold below the 1% floor — use in-bounds values instead
      let data = governanceInstance.interface.encodeFunctionData(
        "updateThresholds(uint,uint)",
        [parseEther("150000"), parseEther("600000")],
      );
      let action = new ProposedAction(
        await governanceInstance.getAddress(),
        data,
        0n,
      );
      await governanceInstance.propose([action], description);
      expect(await governanceInstance.proposalCount()).to.be.eq(1n);
      // proposal 2 carries the same values: once proposal 1 executes, both equal current
      data = governanceInstance.interface.encodeFunctionData(
        "updateThresholds(uint,uint)",
        [parseEther("150000"), parseEther("600000")],
      );
      action = new ProposedAction(
        await governanceInstance.getAddress(),
        data,
        0n,
      );
      await governanceInstance.propose([action], description);
      expect(await governanceInstance.proposalCount()).to.be.eq(2n);
      // proposal 3 changes a single threshold
      data = governanceInstance.interface.encodeFunctionData(
        "updateThresholds(uint,uint)",
        [parseEther("150000"), parseEther("700000")],
      );
      action = new ProposedAction(
        await governanceInstance.getAddress(),
        data,
        0n,
      );
      await governanceInstance.propose([action], description);
      expect(await governanceInstance.proposalCount()).to.be.eq(3n);
      await timeTravel({ days: 14, mine: true });
      await governanceInstance.castVote(1, 1);
      await governanceInstance.castVote(2, 1);
      await governanceInstance.castVote(3, 1);
      await timeTravel({ days: 7, mine: true });
      // a proposal that changes both thresholds succeeds
      await expect(governanceInstance.execute(1))
        .to.emit(governanceInstance, "ProposalThresholdSet")
        .withArgs(parseEther("150000"));
      let storedParams = (await governanceInstance.governanceParameters())
        .params;
      expect(storedParams.quorumThreshold).to.be.eq(parseEther("600000"));
      expect(storedParams.proposalThreshold).to.be.eq(parseEther("150000"));
      // a proposal that changes no threshold reverts
      await expect(governanceInstance.execute(2)).to.be.revertedWithCustomError(
        governanceInstance,
        "GovUpgradeSameAsCurrent",
      );
      // a proposal that changes a single threshold succeeds
      await expect(governanceInstance.execute(3))
        .to.emit(governanceInstance, "ProposalThresholdSet")
        .withArgs(parseEther("150000"));
      storedParams = (await governanceInstance.governanceParameters()).params;
      expect(storedParams.proposalThreshold).to.be.eq(parseEther("150000"));
      expect(storedParams.quorumThreshold).to.be.eq(parseEther("700000"));
    });

    it("should revert if either is invalid paramter", async () => {
      const { ethers } = await network.getOrCreate();
      const { governanceInstance, strategy } = await setupTests();
      // the threshold assertion runs in the strategy, which defines the custom error;
      // validation happens at execution time, via validateParams on the post-update parameters
      const strategyInstance = await ethers.getContractAt(
        "RigoblockGovernanceStrategy",
        strategy,
      );
      const newProposalThreshold = 100n;
      const newQuorumThreshold = parseEther("500000");
      const data = governanceInstance.interface.encodeFunctionData(
        "updateThresholds(uint,uint)",
        [newProposalThreshold, newQuorumThreshold],
      );
      const action = new ProposedAction(
        await governanceInstance.getAddress(),
        data,
        0n,
      );
      // a rogue proposal passes propose and voting, and reverts at execution
      await governanceInstance.propose([action], description);
      await timeTravel({ days: 14, mine: true });
      await governanceInstance.castVote(1, 1);
      await timeTravel({ days: 7, mine: true });
      await expect(governanceInstance.execute(1)).to.be.revertedWithCustomError(
        strategyInstance,
        "GovStrategyInvalidProposalThreshold",
      );
      // an in-bounds proposal still passes and executes
      const validData = governanceInstance.interface.encodeFunctionData(
        "updateThresholds(uint,uint)",
        [parseEther("150000"), newQuorumThreshold],
      );
      const validAction = new ProposedAction(
        await governanceInstance.getAddress(),
        validData,
        0n,
      );
      await governanceInstance.propose([validAction], description);
      await timeTravel({ days: 14, mine: true });
      await governanceInstance.castVote(2, 1);
      await timeTravel({ days: 7, mine: true });
      await expect(governanceInstance.execute(2)).to.emit(
        governanceInstance,
        "ProposalThresholdSet",
      );
    });

    it("should update thresholds", async () => {
      const { governanceInstance } = await setupTests();
      const newProposalThreshold = parseEther("150000");
      const newQuorumThreshold = parseEther("500000");
      const data = governanceInstance.interface.encodeFunctionData(
        "updateThresholds(uint,uint)",
        [newProposalThreshold, newQuorumThreshold],
      );
      const action = new ProposedAction(
        await governanceInstance.getAddress(),
        data,
        0n,
      );
      await governanceInstance.propose([action], description);
      await timeTravel({ days: 14, mine: true });
      await governanceInstance.castVote(1, 1);
      await timeTravel({ days: 7, mine: true });
      await expect(governanceInstance.execute(1))
        .to.emit(governanceInstance, "ProposalThresholdSet")
        .withArgs(newProposalThreshold);
    });
  });
});
