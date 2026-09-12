import { expect } from "chai";
import { network } from "hardhat";
import { encodeBytes32String, parseEther } from "ethers";
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
      user2,
    };
  });

  describe("upgradeImplementation", async () => {
    it("should revert if not called by governance itself", async () => {
      const { governanceInstance, user2 } = await setupTests();
      await expect(
        governanceInstance.upgradeImplementation(user2.address),
      ).to.be.revertedWith("GOV_UPGRADE_APPROVAL_ERROR");
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
      await governanceInstance.castVote(1, VoteType.For);
      await timeTravel({ days: 7, mine: true });
      await expect(governanceInstance.execute(1)).to.be.revertedWith(
        "UPGRADE_SAME_AS_CURRENT_ERROR",
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
      await governanceInstance.castVote(1, VoteType.For);
      await timeTravel({ days: 7, mine: true });
      await expect(governanceInstance.execute(1)).to.be.revertedWith(
        "UPGRADE_NOT_CONTRACT_ERROR",
      );
    });

    it("should upgrade implementation", async () => {
      const { governanceInstance, staking } = await setupTests();
      const data = governanceInstance.interface.encodeFunctionData(
        "upgradeImplementation(address)",
        [await staking.getAddress()],
      );
      const action = new ProposedAction(
        await governanceInstance.getAddress(),
        data,
        0n,
      );
      await governanceInstance.propose([action], description);
      expect(await governanceInstance.proposalCount()).to.be.eq(1n);
      await timeTravel({ days: 14, mine: true });
      await governanceInstance.castVote(1, VoteType.For);
      await timeTravel({ days: 7, mine: true });
      await expect(governanceInstance.execute(1))
        .to.emit(governanceInstance, "Upgraded")
        .withArgs(await staking.getAddress());
    });
  });

  describe("upgradeStrategy", async () => {
    it("should revert if not called by governance itself", async () => {
      const { governanceInstance, user2 } = await setupTests();
      await expect(
        governanceInstance.upgradeStrategy(user2.address),
      ).to.be.revertedWith("GOV_UPGRADE_APPROVAL_ERROR");
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
      await governanceInstance.castVote(1, VoteType.For);
      // proposal becomes executable 7 days after becoming active
      await timeTravel({ days: 7, mine: true });
      await expect(governanceInstance.execute(1)).to.be.revertedWith(
        "UPGRADE_SAME_AS_CURRENT_ERROR",
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
      await governanceInstance.castVote(1, VoteType.For);
      await timeTravel({ days: 7, mine: true });
      await expect(governanceInstance.execute(1)).to.be.revertedWith(
        "UPGRADE_NOT_CONTRACT_ERROR",
      );
    });

    it("should upgrade strategy", async () => {
      const { governanceInstance, staking } = await setupTests();
      const data = governanceInstance.interface.encodeFunctionData(
        "upgradeStrategy(address)",
        [await staking.getAddress()],
      );
      const action = new ProposedAction(
        await governanceInstance.getAddress(),
        data,
        0n,
      );
      await governanceInstance.propose([action], description);
      expect(await governanceInstance.proposalCount()).to.be.eq(1n);
      await timeTravel({ days: 14, mine: true });
      await governanceInstance.castVote(1, VoteType.For);
      await timeTravel({ days: 7, mine: true });
      await expect(governanceInstance.execute(1))
        .to.emit(governanceInstance, "StrategyUpgraded")
        .withArgs(await staking.getAddress());
    });
  });

  describe("updateThresholds", async () => {
    it("should revert if not called by governance itself", async () => {
      const { governanceInstance } = await setupTests();
      await expect(
        governanceInstance.updateThresholds(1, 1),
      ).to.be.revertedWith("GOV_UPGRADE_APPROVAL_ERROR");
    });

    it("should revert if either of new thresholds same as current", async () => {
      const { governanceInstance } = await setupTests();
      const { proposalThreshold, quorumThreshold } = (
        await governanceInstance.governanceParameters()
      ).params;
      let data = governanceInstance.interface.encodeFunctionData(
        "updateThresholds(uint,uint)",
        [proposalThreshold, quorumThreshold],
      );
      let action = new ProposedAction(
        await governanceInstance.getAddress(),
        data,
        0n,
      );
      await governanceInstance.propose([action], description);
      expect(await governanceInstance.proposalCount()).to.be.eq(1n);
      const newQuorumThreshold = parseEther("600000");
      expect(newQuorumThreshold).to.be.not.eq(quorumThreshold);
      data = governanceInstance.interface.encodeFunctionData(
        "updateThresholds(uint,uint)",
        [proposalThreshold, newQuorumThreshold],
      );
      action = new ProposedAction(
        await governanceInstance.getAddress(),
        data,
        0n,
      );
      await governanceInstance.propose([action], description);
      expect(await governanceInstance.proposalCount()).to.be.eq(2n);
      const newProposalThreshold = parseEther("150000");
      expect(newProposalThreshold).to.be.not.eq(proposalThreshold);
      data = governanceInstance.interface.encodeFunctionData(
        "updateThresholds(uint,uint)",
        [newProposalThreshold, newQuorumThreshold],
      );
      action = new ProposedAction(
        await governanceInstance.getAddress(),
        data,
        0n,
      );
      await governanceInstance.propose([action], description);
      expect(await governanceInstance.proposalCount()).to.be.eq(3n);
      await timeTravel({ days: 14, mine: true });
      await governanceInstance.castVote(1, VoteType.For);
      await governanceInstance.castVote(2, VoteType.For);
      await governanceInstance.castVote(3, VoteType.For);
      await timeTravel({ days: 7, mine: true });
      await expect(governanceInstance.execute(1)).to.be.revertedWith(
        "UPGRADE_SAME_AS_CURRENT_ERROR",
      );
      await expect(governanceInstance.execute(2)).to.be.revertedWith(
        "UPGRADE_SAME_AS_CURRENT_ERROR",
      );
      await expect(governanceInstance.execute(3)).to.emit(
        governanceInstance,
        "ThresholdsUpdated",
      );
    });

    it("should revert if either is invalid paramter", async () => {
      const { governanceInstance } = await setupTests();
      let newProposalThreshold = 100n;
      const newQuorumThreshold = parseEther("500000");
      let data = governanceInstance.interface.encodeFunctionData(
        "updateThresholds(uint,uint)",
        [newProposalThreshold, newQuorumThreshold],
      );
      let action = new ProposedAction(
        await governanceInstance.getAddress(),
        data,
        0n,
      );
      await governanceInstance.propose([action], description);
      expect(await governanceInstance.proposalCount()).to.be.eq(1n);
      newProposalThreshold = parseEther("150000");
      data = governanceInstance.interface.encodeFunctionData(
        "updateThresholds(uint,uint)",
        [newProposalThreshold, newQuorumThreshold],
      );
      action = new ProposedAction(
        await governanceInstance.getAddress(),
        data,
        0n,
      );
      await governanceInstance.propose([action], description);
      await timeTravel({ days: 14, mine: true });
      await governanceInstance.castVote(1, VoteType.For);
      await governanceInstance.castVote(2, VoteType.For);
      await timeTravel({ days: 7, mine: true });
      // governance strategy reverts without error in case of rogue params as proposer should be aware of params
      await expect(governanceInstance.execute(1)).to.be.revertedWithPanic(0x1);
      await expect(governanceInstance.execute(2)).to.emit(
        governanceInstance,
        "ThresholdsUpdated",
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
      await governanceInstance.castVote(1, VoteType.For);
      await timeTravel({ days: 7, mine: true });
      await expect(governanceInstance.execute(1))
        .to.emit(governanceInstance, "ThresholdsUpdated")
        .withArgs(newProposalThreshold, newQuorumThreshold);
    });
  });
});
