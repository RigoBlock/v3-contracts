import { expect } from "chai";
import { network } from "hardhat";
import { encodeBytes32String, Signature } from "ethers";
import { connect, getFixedGasSigners } from "../shared/helper";
import { createFixture } from "../utils/fixtures";
import { signEip712Message } from "../utils/eip712sig";
import { ProposedAction, VoteType } from "../utils/utils";

describe("Governance Implementation", async () => {
  const setupTests = createFixture(["governance-tests"], async ({ get }) => {
    const { ethers } = await network.getOrCreate();
    const [user1, user2] = await getFixedGasSigners();
    const implementation = await ethers.getContractAt(
      "RigoblockGovernance",
      (await get("RigoblockGovernance")).address,
    );
    return {
      implementation,
      user1,
      user2,
    };
  });

  describe("propose", async () => {
    it("should revert with direct call", async () => {
      const { implementation, user2 } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const mockBytes = encodeBytes32String("mock");
      const action = new ProposedAction(user2.address, mockBytes, 0n);
      // will revert as strategy is set to address 0, therefore is not able to return voting power
      await expect(
        implementation.propose([action], "this proposal should always fail"),
      ).to.be.revertedWithoutReason(ethers);
    });
  });

  describe("castVote", async () => {
    it("should revert with direct call", async () => {
      const { implementation } = await setupTests();
      const proposalId = 1;
      const voteType = VoteType.Abstain;
      // we won't be able to vote as no proposal can exist on the implementation
      await expect(
        implementation.castVote(proposalId, voteType),
      ).to.be.revertedWith("VOTING_PROPOSAL_ID_ERROR");
    });
  });

  describe("castVoteBySignature", async () => {
    it("should revert with direct call", async () => {
      const { implementation, user2 } = await setupTests();
      const proposalId = 1;
      const voteType = VoteType.Abstain;
      const { signature } = await signEip712Message({
        governance: await implementation.getAddress(),
        proposalId: proposalId,
        voteType: voteType,
      });
      const { v, r, s } = Signature.from(signature);
      // we won't be able to vote as no proposal can exist on the implementation
      await expect(
        connect(implementation, user2).castVoteBySignature(
          proposalId,
          voteType,
          v,
          r,
          s,
        ),
      ).to.be.revertedWith("VOTING_PROPOSAL_ID_ERROR");
    });
  });

  describe("execute", async () => {
    it("should revert with direct call", async () => {
      const { implementation } = await setupTests();
      // we will never be able to execute a proposal that does not exist
      const proposalId = 1;
      await expect(implementation.execute(proposalId)).to.be.revertedWith(
        "VOTING_PROPOSAL_ID_ERROR",
      );
    });
  });

  describe("upgradeImplementation", async () => {
    it("should revert with direct call", async () => {
      const { implementation, user2 } = await setupTests();
      await expect(
        implementation.upgradeImplementation(user2.address),
      ).to.be.revertedWith("GOV_UPGRADE_APPROVAL_ERROR");
    });
  });

  describe("updateThresholds", async () => {
    it("should revert with direct call", async () => {
      const { implementation } = await setupTests();
      await expect(implementation.updateThresholds(1, 1)).to.be.revertedWith(
        "GOV_UPGRADE_APPROVAL_ERROR",
      );
    });
  });

  describe("initializeGovernance", async () => {
    it("should revert with direct call", async () => {
      const { implementation } = await setupTests();
      await expect(implementation.initializeGovernance()).to.be.revertedWith(
        "ALREADY_INITIALIZED_ERROR",
      );
    });
  });

  describe("upgradeStrategy", async () => {
    it("should revert with direct call", async () => {
      const { implementation, user2 } = await setupTests();
      await expect(
        implementation.upgradeStrategy(user2.address),
      ).to.be.revertedWith("GOV_UPGRADE_APPROVAL_ERROR");
    });
  });
});
