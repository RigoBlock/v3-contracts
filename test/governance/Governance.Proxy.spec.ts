import { expect } from "chai";
import { network } from "hardhat";
import {
  EventLog,
  Log,
  Signature,
  TypedDataEncoder,
  ZeroAddress,
  encodeBytes32String,
  parseEther,
  recoverAddress,
} from "ethers";
import { connect, getFixedGasSigners } from "../shared/helper";
import { createFixture } from "../utils/fixtures";
import { signEip712Message } from "../utils/eip712sig";
import {
  ProposalState,
  ProposedAction,
  StakeInfo,
  StakeStatus,
  TimeType,
  VoteType,
  stakeProposalThreshold,
  timeTravel,
} from "../utils/utils";

describe("Governance Proxy", async () => {
  const description = "gov proposal one";

  const setupTests = createFixture(["governance-tests"], async ({ get }) => {
    const { ethers } = await network.getOrCreate();
    const [user1, user2, user3] = await getFixedGasSigners();
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
    return {
      staking,
      governanceInstance,
      grgToken,
      grgTransferProxyAddress: (await get("ERC20Proxy")).address,
      poolId,
      poolAddress,
      strategy,
      user1,
      user2,
      user3,
    };
  });

  describe("initializeGovernance", async () => {
    it("should always revert", async () => {
      const { governanceInstance } = await setupTests();
      expect(await governanceInstance.name()).to.be.eq("Rigoblock Governance");
      await expect(
        governanceInstance.initializeGovernance(),
      ).to.be.revertedWith("ALREADY_INITIALIZED_ERROR");
    });
  });

  describe("propose", async () => {
    it("should revert with null stake", async () => {
      const { governanceInstance, user2 } = await setupTests();
      const mockBytes = encodeBytes32String("mock");
      const action = new ProposedAction(user2.address, mockBytes, 0n);
      await expect(
        governanceInstance.propose([action], "gov proposal one"),
      ).to.be.revertedWith("GOV_LOW_VOTING_POWER");
    });

    it("should revert with empty actions", async () => {
      const {
        governanceInstance,
        grgToken,
        grgTransferProxyAddress,
        poolAddress,
        poolId,
        staking,
      } = await setupTests();
      const amount = parseEther("100000");
      await grgToken.approve(grgTransferProxyAddress, amount);
      await staking.stake(amount);
      await staking.createStakingPool(poolAddress);
      const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      const toInfo = new StakeInfo(StakeStatus.Delegated, poolId);
      await staking.moveStake(fromInfo, toInfo, amount);
      await timeTravel({ days: 14, mine: true });
      await staking.endEpoch();
      await expect(
        governanceInstance.propose([], "gov proposal one"),
      ).to.be.revertedWith("GOV_NO_ACTIONS_ERROR");
    });

    it("can create invalid proposal", async () => {
      const {
        governanceInstance,
        grgToken,
        grgTransferProxyAddress,
        poolAddress,
        poolId,
        staking,
        user1,
      } = await setupTests();
      const amount = parseEther("100000");
      await grgToken.approve(grgTransferProxyAddress, amount);
      await staking.stake(amount);
      await staking.createStakingPool(poolAddress);
      const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      const toInfo = new StakeInfo(StakeStatus.Delegated, poolId);
      await staking.moveStake(fromInfo, toInfo, amount);
      await timeTravel({ days: 14, mine: true });
      await staking.endEpoch();
      const zeroBytes = encodeBytes32String("");
      const action = new ProposedAction(ZeroAddress, zeroBytes, 0n);
      let actions = [
        action,
        action,
        action,
        action,
        action,
        action,
        action,
        action,
        action,
        action,
        action,
      ];
      await expect(
        governanceInstance.propose(actions, description),
      ).to.be.revertedWith("GOV_TOO_MANY_ACTIONS_ERROR");
      const proposalId = await governanceInstance.propose.staticCall(
        [action],
        description,
      );
      expect(proposalId).to.be.eq(1n);
      const startTime =
        await staking.getCurrentEpochEarliestEndTimeInSeconds.staticCall();
      const votingPeriod = await governanceInstance.votingPeriod.staticCall();
      // 7 days
      expect(votingPeriod).to.be.eq(604800n);
      const endTime = startTime + votingPeriod;
      actions = [action, action];
      // Before proposing, no actions are stored for this proposal id
      let outputActions = await governanceInstance.getActions(1);
      expect(outputActions.length).to.be.eq(0);
      // Struct arrays are emitted as ethers Result objects, which cannot be
      // matched against plain tuples/objects via .withArgs(). We verify the
      // event emission and check args via receipt instead.
      const tx = await governanceInstance.propose(actions, description);
      await expect(tx).to.emit(governanceInstance, "ProposalCreated");
      const receipt = await tx.wait();
      const event = receipt!.logs.find(
        (log: Log): log is EventLog =>
          log instanceof EventLog && log.fragment.name === "ProposalCreated",
      )!;
      expect(event.args.proposer).to.eq(user1.address);
      expect(event.args.proposalId).to.eq(proposalId);
      expect(event.args.actions.length).to.eq(actions.length);
      // Explicitly assert each emitted action matches the expected action
      for (let i = 0; i < actions.length; i++) {
        expect(event.args.actions[i].target).to.eq(action.target);
        expect(event.args.actions[i].data).to.eq(action.data);
        expect(event.args.actions[i].value).to.eq(action.value);
      }
      expect(event.args.startBlockOrTime).to.eq(startTime);
      expect(event.args.endBlockOrTime).to.eq(endTime);
      expect(event.args.description).to.eq(description);
      expect(await governanceInstance.proposalCount()).to.be.eq(1n);
      // Verify on-chain storage matches the input actions exactly
      outputActions = await governanceInstance.getActions(1);
      const actionsTuple = [
        new ProposedAction(
          outputActions[0].target,
          outputActions[0].data,
          outputActions[0].value,
        ),
        new ProposedAction(
          outputActions[1].target,
          outputActions[1].data,
          outputActions[1].value,
        ),
      ];
      expect(String(actionsTuple)).to.be.eq(String(actions));
    });

    it("can create valid proposal", async () => {
      const {
        governanceInstance,
        grgToken,
        grgTransferProxyAddress,
        poolAddress,
        poolId,
        staking,
        user1,
      } = await setupTests();
      const amount = parseEther("100000");
      await grgToken.approve(grgTransferProxyAddress, amount);
      await staking.stake(amount);
      await staking.createStakingPool(poolAddress);
      const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      const toInfo = new StakeInfo(StakeStatus.Delegated, poolId);
      await staking.moveStake(fromInfo, toInfo, amount);
      await timeTravel({ days: 14, mine: true });
      await staking.endEpoch();
      const data = grgToken.interface.encodeFunctionData(
        "approve(address,uint256)",
        [user1.address, amount],
      );
      const action = new ProposedAction(await grgToken.getAddress(), data, 0n);
      const proposalId = await governanceInstance.propose.staticCall(
        [action],
        description,
      );
      expect(proposalId).to.be.eq(1n);
      const startTime =
        await staking.getCurrentEpochEarliestEndTimeInSeconds.staticCall();
      const votingPeriod = await governanceInstance.votingPeriod.staticCall();
      const endTime = startTime + votingPeriod;
      const actions = [action, action];
      // Before proposing, no actions are stored for this proposal id
      let outputActions = await governanceInstance.getActions(proposalId);
      expect(outputActions.length).to.be.eq(0);
      // Struct arrays are emitted as ethers Result objects, which cannot be
      // matched against plain tuples/objects via .withArgs(). We verify the
      // event emission and check args via receipt instead.
      const tx = await governanceInstance.propose(actions, description);
      await expect(tx).to.emit(governanceInstance, "ProposalCreated");
      const receipt = await tx.wait();
      const event = receipt!.logs.find(
        (log: Log): log is EventLog =>
          log instanceof EventLog && log.fragment.name === "ProposalCreated",
      )!;
      expect(event.args.proposer).to.eq(user1.address);
      expect(event.args.proposalId).to.eq(proposalId);
      expect(event.args.actions.length).to.eq(actions.length);
      // Explicitly assert each emitted action matches the expected action
      for (let i = 0; i < actions.length; i++) {
        expect(event.args.actions[i].target).to.eq(action.target);
        expect(event.args.actions[i].data).to.eq(action.data);
        expect(event.args.actions[i].value).to.eq(action.value);
      }
      expect(event.args.startBlockOrTime).to.eq(startTime);
      expect(event.args.endBlockOrTime).to.eq(endTime);
      expect(event.args.description).to.eq(description);
      // Verify on-chain storage matches the input actions exactly
      outputActions = await governanceInstance.getActions(proposalId);
      const storedActionsTuple = [
        new ProposedAction(
          outputActions[0].target,
          outputActions[0].data,
          outputActions[0].value,
        ),
        new ProposedAction(
          outputActions[1].target,
          outputActions[1].data,
          outputActions[1].value,
        ),
      ];
      expect(String(storedActionsTuple)).to.be.eq(String(actions));
      // after that, we further investigate by creating a new identical proposal
      const txReceipt = await governanceInstance.propose(actions, description);
      const result = await txReceipt.wait();
      const secondEvent = result!.logs.find(
        (log: Log): log is EventLog =>
          log instanceof EventLog && log.fragment.name === "ProposalCreated",
      )!;
      outputActions = secondEvent.args.actions;
      // we define a new variable
      const actionsTuple = [
        new ProposedAction(
          outputActions[0].target,
          outputActions[0].data,
          outputActions[0].value,
        ),
        new ProposedAction(
          outputActions[1].target,
          outputActions[1].data,
          outputActions[1].value,
        ),
      ];
      expect(String(actionsTuple)).to.be.eq(String(actions));
    });
  });

  describe("castVote", async () => {
    it("should revert with non active proposal", async () => {
      const {
        governanceInstance,
        grgToken,
        grgTransferProxyAddress,
        poolAddress,
        poolId,
        staking,
      } = await setupTests();
      // proposal does not exist
      await expect(
        governanceInstance.castVote(1, VoteType.For),
      ).to.be.revertedWith("VOTING_PROPOSAL_ID_ERROR");
      const amount = parseEther("100000");
      await grgToken.approve(grgTransferProxyAddress, amount);
      await staking.stake(amount);
      await staking.createStakingPool(poolAddress);
      const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      const toInfo = new StakeInfo(StakeStatus.Delegated, poolId);
      await staking.moveStake(fromInfo, toInfo, amount);
      await timeTravel({ days: 14, mine: true });
      await staking.endEpoch();
      const zeroBytes = encodeBytes32String("");
      const action = new ProposedAction(ZeroAddress, zeroBytes, 0n);
      await governanceInstance.propose([action], description);
      await expect(
        governanceInstance.castVote(1, VoteType.For),
      ).to.be.revertedWith("VOTING_CLOSED_ERROR");
    });

    it("should revert without voting power", async () => {
      const {
        governanceInstance,
        grgToken,
        grgTransferProxyAddress,
        poolAddress,
        poolId,
        staking,
        user1,
        user2,
      } = await setupTests();
      const amount = parseEther("100000");
      await grgToken.approve(grgTransferProxyAddress, amount);
      await staking.stake(amount);
      await staking.createStakingPool(poolAddress);
      const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      const toInfo = new StakeInfo(StakeStatus.Delegated, poolId);
      await staking.moveStake(fromInfo, toInfo, amount);
      await timeTravel({ days: 14, mine: true });
      await staking.endEpoch();
      const zeroBytes = encodeBytes32String("");
      const action = new ProposedAction(ZeroAddress, zeroBytes, 0n);
      await governanceInstance.propose([action], description);
      await expect(
        connect(governanceInstance, user2).castVote(1, VoteType.For),
      ).to.be.revertedWith("VOTING_CLOSED_ERROR");
      await timeTravel({ days: 14, mine: true });
      await staking.endEpoch();
      await expect(
        connect(governanceInstance, user2).castVote(1, VoteType.For),
      ).to.be.revertedWith("VOTING_NO_VOTES_ERROR");
      await expect(governanceInstance.castVote(1, VoteType.For))
        .to.emit(governanceInstance, "VoteCast")
        .withArgs(user1.address, 1, VoteType.For, amount);
      await expect(
        governanceInstance.castVote(1, VoteType.For),
      ).to.be.revertedWith("VOTING_ALREADY_VOTED_ERROR");
    });

    it("should revert after voting period ended", async () => {
      const {
        governanceInstance,
        grgToken,
        grgTransferProxyAddress,
        poolAddress,
        poolId,
        staking,
        user2,
      } = await setupTests();
      const amount = parseEther("100000");
      await stakeProposalThreshold({
        amount,
        grgToken,
        grgTransferProxyAddress,
        staking,
        poolAddress,
        poolId,
      });
      const zeroBytes = encodeBytes32String("");
      const action = new ProposedAction(ZeroAddress, zeroBytes, 0n);
      await timeTravel({ days: 8, mine: true });
      await governanceInstance.propose([action], description);
      // voting starts after 6 days
      await timeTravel({ days: 6, mine: true });
      // voting ends after 7 days from voting start
      await timeTravel({ days: 7, mine: true });
      await expect(
        connect(governanceInstance, user2).castVote(1, VoteType.For),
      ).to.be.revertedWith("VOTING_CLOSED_ERROR");
    });
  });

  describe("castVoteBySignature", async () => {
    it("should revert without proposal", async () => {
      const { governanceInstance, user2 } = await setupTests();
      const proposalId = 1;
      const voteType = VoteType.Abstain;
      const { signature } = await signEip712Message({
        governance: await governanceInstance.getAddress(),
        proposalId: proposalId,
        voteType: voteType,
      });
      const { v, r, s } = Signature.from(signature);
      // we use user2 as signed message should be relayable by anyone
      await expect(
        connect(governanceInstance, user2).castVoteBySignature(
          proposalId,
          voteType,
          v,
          r,
          s,
        ),
      ).to.be.revertedWith("VOTING_PROPOSAL_ID_ERROR");
    });

    it("should vote on an existing proposal", async () => {
      const {
        governanceInstance,
        grgToken,
        grgTransferProxyAddress,
        poolAddress,
        poolId,
        staking,
        user1,
        user2,
      } = await setupTests();
      const amount = parseEther("100000");
      await stakeProposalThreshold({
        amount: amount,
        grgToken: grgToken,
        grgTransferProxyAddress: grgTransferProxyAddress,
        staking: staking,
        poolAddress: poolAddress,
        poolId: poolId,
      });
      const data = grgToken.interface.encodeFunctionData(
        "approve(address,uint256)",
        [user2.address, amount],
      );
      const action = new ProposedAction(await grgToken.getAddress(), data, 0n);
      const proposalId = await governanceInstance.propose.staticCall(
        [action],
        description,
      );
      await governanceInstance.propose([action], description);
      await timeTravel({ days: 14, mine: true });
      const voteType = VoteType.For;
      const { signature, domain, types, value } = await signEip712Message({
        governance: await governanceInstance.getAddress(),
        proposalId: Number(proposalId),
        voteType: voteType,
      });
      const { v, r, s } = Signature.from(signature);
      const structDataHash = TypedDataEncoder.hash(domain, types, value);
      const signerAddress = recoverAddress(structDataHash, signature);
      expect(signerAddress).to.be.eq(user1.address);
      const { currentEpochBalance } = await staking.getOwnerStakeByStatus(
        signerAddress,
        StakeStatus.Delegated,
      );
      const votingPower =
        await governanceInstance.getVotingPower(signerAddress);
      expect(currentEpochBalance).to.be.eq(votingPower);
      expect(votingPower).to.be.eq(amount);
      // notice: contract only asserts signatory != address(0) as eip712 signatures on diff. domains always bypass the assertion
      await expect(
        connect(governanceInstance, user2).castVoteBySignature(
          proposalId,
          voteType,
          v,
          r,
          s,
        ),
      )
        .to.emit(governanceInstance, "VoteCast")
        .withArgs(user1.address, proposalId, voteType, votingPower);
    });

    it("should revert on wrong proposal id or vote", async () => {
      const {
        governanceInstance,
        grgToken,
        grgTransferProxyAddress,
        staking,
        poolAddress,
        poolId,
        user1,
        user2,
      } = await setupTests();
      const amount = parseEther("100000");
      await stakeProposalThreshold({
        amount,
        grgToken,
        grgTransferProxyAddress,
        staking,
        poolAddress,
        poolId,
      });
      const data = grgToken.interface.encodeFunctionData(
        "approve(address,uint256)",
        [user2.address, amount],
      );
      const action = new ProposedAction(await grgToken.getAddress(), data, 0n);
      await governanceInstance.propose([action], description);
      const proposalId = 1;
      const voteType = VoteType.Abstain;
      const { signature } = await signEip712Message({
        governance: await governanceInstance.getAddress(),
        proposalId: proposalId,
        voteType: voteType,
      });
      const { v, r, s } = Signature.from(signature);
      await governanceInstance.propose([action], description);
      await timeTravel({ days: 14, mine: true });
      // an invalid signature (we send signature for proposal 1, bypasses signature assertion)
      await expect(
        connect(governanceInstance, user2).castVoteBySignature(
          proposalId + 1,
          voteType,
          v,
          r,
          s,
        ),
      ).to.be.revertedWith("VOTING_NO_VOTES_ERROR");
      await expect(
        connect(governanceInstance, user2).castVoteBySignature(
          proposalId,
          VoteType.For,
          v,
          r,
          s,
        ),
      ).to.be.revertedWith("VOTING_NO_VOTES_ERROR");
      await expect(
        connect(governanceInstance, user2).castVoteBySignature(
          proposalId,
          voteType,
          v,
          r,
          s,
        ),
      )
        .to.emit(governanceInstance, "VoteCast")
        .withArgs(user1.address, proposalId, voteType, amount);
    });

    it("should not be replayed", async () => {
      const {
        governanceInstance,
        grgToken,
        grgTransferProxyAddress,
        staking,
        poolAddress,
        poolId,
        user1,
        user2,
        user3,
      } = await setupTests();
      const amount = parseEther("100000");
      await stakeProposalThreshold({
        amount,
        grgToken,
        grgTransferProxyAddress,
        staking,
        poolAddress,
        poolId,
      });
      const data = grgToken.interface.encodeFunctionData(
        "approve(address,uint256)",
        [user2.address, amount],
      );
      const action = new ProposedAction(await grgToken.getAddress(), data, 0n);
      await governanceInstance.propose([action], description);
      const proposalId = 1;
      const voteType = VoteType.Abstain;
      const { signature } = await signEip712Message({
        governance: await governanceInstance.getAddress(),
        proposalId: proposalId,
        voteType: voteType,
      });
      const { v, r, s } = Signature.from(signature);
      await governanceInstance.propose([action], description);
      await timeTravel({ days: 14, mine: true });
      await expect(
        connect(governanceInstance, user2).castVoteBySignature(
          proposalId,
          voteType,
          v,
          r,
          s,
        ),
      )
        .to.emit(governanceInstance, "VoteCast")
        .withArgs(user1.address, proposalId, voteType, amount);
      // submitting a different vote type will return a different signer that probabilistically won't have votes.
      await expect(
        connect(governanceInstance, user3).castVoteBySignature(
          proposalId,
          VoteType.For,
          v,
          r,
          s,
        ),
      ).to.be.revertedWith("VOTING_NO_VOTES_ERROR");
      await expect(
        connect(governanceInstance, user3).castVoteBySignature(
          proposalId,
          voteType,
          v,
          r,
          s,
        ),
      ).to.be.revertedWith("VOTING_ALREADY_VOTED_ERROR");
    });

    it("should be able to vote if has unstaked", async () => {
      const {
        governanceInstance,
        grgToken,
        grgTransferProxyAddress,
        staking,
        poolAddress,
        poolId,
        user1,
        user2,
      } = await setupTests();
      const amount = parseEther("100000");
      await stakeProposalThreshold({
        amount,
        grgToken,
        grgTransferProxyAddress,
        staking,
        poolAddress,
        poolId,
      });
      const data = grgToken.interface.encodeFunctionData(
        "approve(address,uint256)",
        [user2.address, amount],
      );
      const action = new ProposedAction(await grgToken.getAddress(), data, 0n);
      await governanceInstance.propose([action], description);
      const proposalId = 1;
      const voteType = VoteType.Abstain;
      const { signature } = await signEip712Message({
        governance: await governanceInstance.getAddress(),
        proposalId: proposalId,
        voteType: voteType,
      });
      const { v, r, s } = Signature.from(signature);
      await timeTravel({ days: 14, mine: true });
      await staking.endEpoch();
      const fromInfo = new StakeInfo(StakeStatus.Delegated, poolId);
      const toInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      await staking.moveStake(fromInfo, toInfo, amount);
      await expect(staking.unstake(amount)).to.be.revertedWith(
        "MOVE_STAKE_AMOUNT_HIGHER_THAN_WITHDRAWABLE_ERROR",
      );
      await expect(
        connect(governanceInstance, user2).castVoteBySignature(
          proposalId,
          voteType,
          v,
          r,
          s,
        ),
      )
        .to.emit(governanceInstance, "VoteCast")
        .withArgs(user1.address, proposalId, voteType, amount);
      // we create a new proposal
      await governanceInstance.propose([action], description);
      await timeTravel({ days: 14, mine: true });
      await staking.endEpoch();
      await staking.unstake(amount);
      // an invalid signature (we send signature for proposal 1, bypasses signature assertion)
      await expect(
        connect(governanceInstance, user2).castVoteBySignature(
          proposalId + 1,
          voteType,
          v,
          r,
          s,
        ),
      ).to.be.revertedWith("VOTING_NO_VOTES_ERROR");
    });
  });

  describe("execute", async () => {
    it("should revert with invalid state", async () => {
      const {
        governanceInstance,
        grgToken,
        grgTransferProxyAddress,
        poolAddress,
        poolId,
        staking,
      } = await setupTests();
      await expect(governanceInstance.execute(1)).to.be.revertedWith(
        "VOTING_PROPOSAL_ID_ERROR",
      );
      const amount = parseEther("1000000");
      await grgToken.approve(grgTransferProxyAddress, amount);
      await staking.stake(amount);
      await staking.createStakingPool(poolAddress);
      const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      const toInfo = new StakeInfo(StakeStatus.Delegated, poolId);
      await staking.moveStake(fromInfo, toInfo, amount);
      await timeTravel({ days: 14, mine: true });
      await staking.endEpoch();
      const zeroBytes = encodeBytes32String("");
      const action = new ProposedAction(ZeroAddress, zeroBytes, 0n);
      await governanceInstance.propose([action], description);
      await expect(governanceInstance.execute(1)).to.be.revertedWith(
        "VOTING_EXECUTION_STATE_ERROR",
      );
      // voting becomes active after 14 days if proposal made at beginning of epoch
      await timeTravel({ days: 14, mine: true });
      await expect(governanceInstance.execute(1)).to.be.revertedWith(
        "VOTING_EXECUTION_STATE_ERROR",
      );
      await governanceInstance.castVote(1, VoteType.For);
      // proposal becomes executable after voting period ends
      await timeTravel({ days: 7, mine: true });
      // empty action does not fail
      await expect(governanceInstance.execute(1))
        .to.emit(governanceInstance, "ProposalExecuted")
        .withArgs(1);
    });

    it("should revert during voting period when below quorum", async () => {
      const {
        governanceInstance,
        grgToken,
        grgTransferProxyAddress,
        poolAddress,
        poolId,
        staking,
        user1,
        user2,
      } = await setupTests();
      expect(await governanceInstance.proposalCount()).to.be.eq(0n);
      expect(await governanceInstance.getVotingPower(user1.address)).to.be.eq(
        0n,
      );
      const amount = parseEther("1000000");
      await grgToken.approve(grgTransferProxyAddress, amount);
      await staking.stake(amount);
      await staking.createStakingPool(poolAddress);
      const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      const toInfo = new StakeInfo(StakeStatus.Delegated, poolId);
      await staking.moveStake(fromInfo, toInfo, (amount / 10n) * 7n);
      await timeTravel({ days: 14, mine: true });
      await staking.endEpoch();
      expect(await governanceInstance.getVotingPower(user1.address)).to.be.eq(
        (amount / 10n) * 7n,
      );
      const data = grgToken.interface.encodeFunctionData(
        "approve(address,uint256)",
        [user2.address, amount],
      );
      const action = new ProposedAction(await grgToken.getAddress(), data, 0n);
      await governanceInstance.propose([action], description);
      expect(await governanceInstance.proposalCount()).to.be.eq(1n);
      await timeTravel({ days: 14, mine: true });
      await governanceInstance.castVote(1, VoteType.For);
      await expect(governanceInstance.execute(1)).to.be.revertedWith(
        "VOTING_EXECUTION_STATE_ERROR",
      );
      await governanceInstance.propose([action], description);
      expect(await governanceInstance.proposalCount()).to.be.eq(2n);
      await grgToken.transfer(user2.address, amount);
      await connect(grgToken, user2).approve(grgTransferProxyAddress, amount);
      await connect(staking, user2).stake(amount);
      await connect(staking, user2).moveStake(
        fromInfo,
        toInfo,
        (amount / 10n) * 3n,
      );
      await staking.endEpoch();
      await governanceInstance.castVote(2, VoteType.For);
      await connect(governanceInstance, user2).castVote(2, VoteType.Abstain);
      await expect(
        connect(governanceInstance, user2).castVote(2, VoteType.Abstain),
      ).to.be.revertedWith("VOTING_ALREADY_VOTED_ERROR");
      // execution reverts as votes for below quorum
      await expect(governanceInstance.execute(2)).to.be.revertedWith(
        "VOTING_EXECUTION_STATE_ERROR",
      );
      const proposals = await governanceInstance.proposals();
      expect(proposals[0].proposal.actionsLength).to.be.eq(1);
      expect(proposals[0].proposal.votesFor).to.be.eq((amount / 10n) * 7n);
      expect(proposals[1].proposal.votesAbstain).to.be.eq((amount / 10n) * 3n);
    });

    it("should revert if quorum not reached)", async () => {
      const {
        governanceInstance,
        grgToken,
        grgTransferProxyAddress,
        poolAddress,
        poolId,
        staking,
        user1,
        user2,
        user3,
      } = await setupTests();
      expect(await governanceInstance.proposalCount()).to.be.eq(0n);
      expect(await governanceInstance.getVotingPower(user1.address)).to.be.eq(
        0n,
      );
      const amount = parseEther("100000");
      // stake 100k GRG from user1
      await stakeProposalThreshold({
        amount,
        grgToken,
        grgTransferProxyAddress,
        staking,
        poolAddress,
        poolId,
      });
      const data = grgToken.interface.encodeFunctionData(
        "approve(address,uint256)",
        [user2.address, amount],
      );
      const action = new ProposedAction(await grgToken.getAddress(), data, 0n);
      await governanceInstance.propose([action], description);
      // stake 100k GRG from user2
      const transferAmount = amount;
      await grgToken.transfer(user2.address, transferAmount);
      await connect(grgToken, user2).approve(
        grgTransferProxyAddress,
        transferAmount,
      );
      await connect(staking, user2).stake(transferAmount);
      const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      const toInfo = new StakeInfo(StakeStatus.Delegated, poolId);
      await connect(staking, user2).moveStake(fromInfo, toInfo, transferAmount);
      // stake 200k + 1 GRG from user3
      const transferAmount2 = amount * 2n + 1n;
      await grgToken.transfer(user3.address, transferAmount2);
      await connect(grgToken, user3).approve(
        grgTransferProxyAddress,
        transferAmount2,
      );
      await connect(staking, user3).stake(transferAmount2);
      await connect(staking, user3).moveStake(
        fromInfo,
        toInfo,
        transferAmount2,
      );
      await governanceInstance.propose([action], description);
      await timeTravel({ days: 14, mine: true });
      await staking.endEpoch();
      await governanceInstance.castVote(1, VoteType.Abstain);
      await connect(governanceInstance, user2).castVote(1, VoteType.Against);
      await connect(governanceInstance, user3).castVote(2, VoteType.For);
      await expect(governanceInstance.execute(1)).to.be.revertedWith(
        "VOTING_EXECUTION_STATE_ERROR",
      );
      await timeTravel({ days: 14, mine: true });
      await staking.endEpoch();
      await expect(governanceInstance.execute(1)).to.be.revertedWith(
        "VOTING_EXECUTION_STATE_ERROR",
      );
    });

    it("should revert if quorum reached but not enough support", async () => {
      const {
        governanceInstance,
        grgToken,
        grgTransferProxyAddress,
        poolAddress,
        poolId,
        staking,
        user1,
        user2,
        user3,
      } = await setupTests();
      expect(await governanceInstance.proposalCount()).to.be.eq(0n);
      expect(await governanceInstance.getVotingPower(user1.address)).to.be.eq(
        0n,
      );
      const amount = parseEther("1000000");
      // stake 1MM GRG from user1
      await stakeProposalThreshold({
        amount,
        grgToken,
        grgTransferProxyAddress,
        staking,
        poolAddress,
        poolId,
      });
      const data = grgToken.interface.encodeFunctionData(
        "approve(address,uint256)",
        [user2.address, amount],
      );
      const action = new ProposedAction(await grgToken.getAddress(), data, 0n);
      await governanceInstance.propose([action], description);
      // stake 100k GRG from user2
      const transferAmount = amount / 10n;
      await grgToken.transfer(user2.address, transferAmount);
      await connect(grgToken, user2).approve(
        grgTransferProxyAddress,
        transferAmount,
      );
      await connect(staking, user2).stake(transferAmount);
      const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      const toInfo = new StakeInfo(StakeStatus.Delegated, poolId);
      await connect(staking, user2).moveStake(fromInfo, toInfo, transferAmount);
      await timeTravel({ days: 14, mine: true });
      await staking.endEpoch();
      await governanceInstance.castVote(1, VoteType.Abstain);
      await connect(governanceInstance, user2).castVote(1, VoteType.Against);
      await timeTravel({ days: 14, mine: true });
      await staking.endEpoch();
      await expect(governanceInstance.execute(1)).to.be.revertedWith(
        "VOTING_EXECUTION_STATE_ERROR",
      );
      // add another voter
      await grgToken.transfer(user3.address, transferAmount + 1n);
      await connect(grgToken, user3).approve(
        grgTransferProxyAddress,
        transferAmount + 1n,
      );
      await connect(staking, user3).stake(transferAmount + 1n);
      await connect(staking, user3).moveStake(
        fromInfo,
        toInfo,
        transferAmount + 1n,
      );
      await governanceInstance.propose([action], description);
      await timeTravel({ days: 14, mine: true });
      await staking.endEpoch();
      await governanceInstance.castVote(2, VoteType.Abstain);
      await connect(governanceInstance, user2).castVote(2, VoteType.Against);
      await connect(governanceInstance, user3).castVote(2, VoteType.For);
      const receipt = await governanceInstance.getReceipt(2, user3.address);
      expect(receipt.hasVoted).to.be.eq(true);
      expect(receipt.votes).to.be.eq(transferAmount + 1n);
      expect(Number(receipt.voteType)).to.be.eq(0);
      await expect(
        connect(governanceInstance, user3).castVote(2, VoteType.Abstain),
      ).to.be.revertedWith("VOTING_ALREADY_VOTED_ERROR");
      await timeTravel({ days: 14, mine: true });
      await expect(governanceInstance.execute(2)).to.be.revertedWith(
        "VOTING_EXECUTION_STATE_ERROR",
      );
    });

    it("should revert during voting period (unless qualified > of all delegated stake)", async () => {
      const {
        governanceInstance,
        grgToken,
        grgTransferProxyAddress,
        poolAddress,
        poolId,
        staking,
        user1,
        user2,
        user3,
      } = await setupTests();
      expect(await governanceInstance.proposalCount()).to.be.eq(0n);
      expect(await governanceInstance.getVotingPower(user1.address)).to.be.eq(
        0n,
      );
      const amount = parseEther("1000000");
      // stake 1MM GRG from user1
      await stakeProposalThreshold({
        amount,
        grgToken,
        grgTransferProxyAddress,
        staking,
        poolAddress,
        poolId,
      });
      const data = grgToken.interface.encodeFunctionData(
        "approve(address,uint256)",
        [user2.address, amount],
      );
      const action = new ProposedAction(await grgToken.getAddress(), data, 0n);
      await governanceInstance.propose([action], description);
      // stake 100k GRG from user2
      const transferAmount = amount / 10n;
      await grgToken.transfer(user2.address, transferAmount);
      await connect(grgToken, user2).approve(
        grgTransferProxyAddress,
        transferAmount,
      );
      await connect(staking, user2).stake(transferAmount);
      const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      const toInfo = new StakeInfo(StakeStatus.Delegated, poolId);
      await connect(staking, user2).moveStake(fromInfo, toInfo, transferAmount);
      // stake 200k + 1 GRG from user3
      const transferAmount2 = transferAmount * 2n + 1n;
      await grgToken.transfer(user3.address, transferAmount2);
      await connect(grgToken, user3).approve(
        grgTransferProxyAddress,
        transferAmount2,
      );
      await connect(staking, user3).stake(transferAmount2);
      await connect(staking, user3).moveStake(
        fromInfo,
        toInfo,
        transferAmount2,
      );
      await timeTravel({ days: 14, mine: true });
      await staking.endEpoch();
      await governanceInstance.castVote(1, VoteType.Abstain);
      await connect(governanceInstance, user2).castVote(1, VoteType.Against);
      await connect(governanceInstance, user3).castVote(1, VoteType.For);
      await expect(governanceInstance.execute(1)).to.be.revertedWith(
        "VOTING_EXECUTION_STATE_ERROR",
      );
      await timeTravel({ days: 14, mine: true });
      // reverts as qualified majority but quorum not reached
      await expect(governanceInstance.execute(1)).to.be.revertedWith(
        "VOTING_EXECUTION_STATE_ERROR",
      );
    });

    it("should correctly execute an external contract call", async () => {
      const {
        governanceInstance,
        grgToken,
        grgTransferProxyAddress,
        poolAddress,
        poolId,
        staking,
        user2,
      } = await setupTests();
      const amount = parseEther("1000000");
      await grgToken.approve(grgTransferProxyAddress, amount);
      await staking.stake(amount);
      await staking.createStakingPool(poolAddress);
      const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      const toInfo = new StakeInfo(StakeStatus.Delegated, poolId);
      await staking.moveStake(fromInfo, toInfo, amount);
      await timeTravel({ days: 14, mine: true });
      await staking.endEpoch();
      const data = grgToken.interface.encodeFunctionData(
        "approve(address,uint256)",
        [user2.address, amount],
      );
      const action = new ProposedAction(await grgToken.getAddress(), data, 0n);
      // finalizePool can be called at any time and will have no impact on state but will emit log
      const data2 = staking.interface.encodeFunctionData(
        "finalizePool(bytes32)",
        [poolId],
      );
      const action2 = new ProposedAction(await staking.getAddress(), data2, 0n);
      await governanceInstance.propose([action, action2], description);
      await timeTravel({ days: 14, mine: true });
      // only 3 types of votes are supported, the 4th will revert
      const { ethers } = await network.getOrCreate();
      await expect(governanceInstance.castVote(1, 3)).to.revert(ethers);
      await governanceInstance.castVote(1, VoteType.For);
      await timeTravel({ days: 14, mine: true });
      const firstAction = (await governanceInstance.getActions(1))[0];
      expect(firstAction.target).to.be.eq(await grgToken.getAddress());
      expect(firstAction.value).to.be.eq(0n);
      expect(firstAction.data).to.be.eq(data);
      await expect(governanceInstance.execute(1))
        .to.emit(grgToken, "Approval")
        .withArgs(await governanceInstance.getAddress(), user2.address, amount);
    });

    it("reverts if error in execution", async () => {
      const {
        governanceInstance,
        grgToken,
        grgTransferProxyAddress,
        poolAddress,
        poolId,
        staking,
      } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const amount = parseEther("1000000");
      await grgToken.approve(grgTransferProxyAddress, amount);
      await staking.stake(amount);
      await staking.createStakingPool(poolAddress);
      const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      const toInfo = new StakeInfo(StakeStatus.Delegated, poolId);
      await staking.moveStake(fromInfo, toInfo, amount);
      await timeTravel({ days: 14, mine: true });
      await staking.endEpoch();
      const zeroBytes = encodeBytes32String("");
      const action = new ProposedAction(
        await grgToken.getAddress(),
        zeroBytes,
        0n,
      );
      await governanceInstance.propose([action], description);
      await timeTravel({ days: 14, mine: true });
      await governanceInstance.castVote(1, VoteType.For);
      await timeTravel({ days: 14, mine: true });
      await expect(governanceInstance.execute(1)).to.be.revertedWithoutReason(
        ethers,
      );
    });

    // executable immediately after support > 2/3 all staked delegated GRG
    it("should be able to execute during voting period when qualified majority", async () => {
      const {
        governanceInstance,
        grgToken,
        grgTransferProxyAddress,
        poolAddress,
        poolId,
        staking,
        user2,
      } = await setupTests();
      const amount = parseEther("1000000");
      await grgToken.approve(grgTransferProxyAddress, amount);
      await staking.stake(amount);
      await staking.createStakingPool(poolAddress);
      const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      const toInfo = new StakeInfo(StakeStatus.Delegated, poolId);
      await staking.moveStake(fromInfo, toInfo, amount);
      await timeTravel({ days: 14, mine: true });
      await staking.endEpoch();
      const data = grgToken.interface.encodeFunctionData(
        "approve(address,uint256)",
        [user2.address, amount],
      );
      const action = new ProposedAction(await grgToken.getAddress(), data, 0n);
      await governanceInstance.propose([action], description);
      expect(await governanceInstance.getProposalState(1)).to.be.eq(
        ProposalState.Pending,
      );
      await timeTravel({ days: 14, mine: true });
      expect(await governanceInstance.getProposalState(1)).to.be.eq(
        ProposalState.Active,
      );
      await governanceInstance.castVote(1, VoteType.For);
      // qualified majority will change state to qualified, which can be executed at next block
      expect(await governanceInstance.getProposalState(1)).to.be.eq(
        ProposalState.Qualified,
      );
      // we do not need to time travel as a new transaction is included in a new block
      await expect(governanceInstance.execute(1))
        .to.emit(grgToken, "Approval")
        .withArgs(await governanceInstance.getAddress(), user2.address, amount);
      // after execution state will find its final state
      expect(await governanceInstance.getProposalState(1)).to.be.eq(
        ProposalState.Executed,
      );
    });
  });
});
