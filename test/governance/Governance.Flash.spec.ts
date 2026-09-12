import { expect } from "chai";
import { network } from "hardhat";
import { encodeBytes32String, parseEther } from "ethers";
import { connect, getFixedGasSigners } from "../shared/helper";
import { createFixture } from "../utils/fixtures";
import {
  ProposedAction,
  StakeInfo,
  StakeStatus,
  TimeType,
  VoteType,
  stakeProposalThreshold,
  timeTravel,
} from "../utils/utils";

describe("Governance Flash Attack", async () => {
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
      parseEther("400000"), // 400K GRG
      TimeType.Timestamp,
      "Rigoblock Governance",
    );
    await governanceFactory.createGovernance(
      implementation,
      strategy,
      parseEther("100000"), // 100k GRG
      parseEther("400000"), // 400K GRG
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

  // a flash attack would still require staking proposal GRG (100k) but would allow upgrading i.e. staking implementation
  //  in order to unstake before staking epoch ends.
  describe("simulate flash attack", async () => {
    it("should not be able to execute during voting period", async () => {
      const {
        governanceInstance,
        grgToken,
        grgTransferProxyAddress,
        poolAddress,
        poolId,
        staking,
        user2,
      } = await setupTests();
      // we stake the minimum amount to make a proposal
      let amount = parseEther("100000");
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
      // at the beginning of the new epoch, we make a proposal which can be voted on in 14 days
      // after the end of the new epoch, we make a proposal which can be voted from current block + 1
      await timeTravel({ days: 14, mine: true });
      await governanceInstance.propose([action], description);
      // we move forward 2 seconds to make sure proposal can be voted on
      await timeTravel({ seconds: 2, mine: true });
      // after the end of the epoch, we  flash borrow and stake GRG in order to gain quorum and > 2/3 of all stake
      amount = parseEther("400000");
      await grgToken.transfer(user2.address, amount);
      await connect(grgToken, user2).approve(grgTransferProxyAddress, amount);
      await connect(staking, user2).stake(amount);
      const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      const toInfo = new StakeInfo(StakeStatus.Delegated, poolId);
      await connect(staking, user2).moveStake(fromInfo, toInfo, amount);
      await staking.endEpoch();
      // voting is active since it has just started
      await connect(governanceInstance, user2).castVote(1, VoteType.For);
      // voting is closed as we have reached qualified consensus (proposal cannot fail under any circumstance)
      await expect(
        connect(governanceInstance, user2).castVote(1, VoteType.For),
      ).to.be.revertedWith("VOTING_CLOSED_ERROR");
      // transaction will be executed as it is in a new block. We keep this test as we want to catch an error should
      //  future upgrades modify this logic. Relevant as moving the voting end 1 block forward instead of same block
      //  as qualifying vote would create an attack vector with limited impact where voters keep postponing voting end.
      await expect(connect(governanceInstance, user2).execute(1)).to.emit(
        grgToken,
        "Approval",
      );
    });
  });

  describe("flash attack", async () => {
    it("should not be able to execute during voting period", async () => {
      const {
        governanceInstance,
        grgToken,
        grgTransferProxyAddress,
        poolAddress,
        poolId,
        staking,
        user2,
      } = await setupTests();
      const { ethers } = await network.getOrCreate();
      // we stake the minimum amount to make a proposal
      let amount = parseEther("100000");
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
      // at the beginning of the new epoch, we make a proposal which can be voted on in 14 days
      // after the end of the new epoch, we make a proposal which can be voted from current block + 1
      await timeTravel({ days: 14, mine: true });
      await governanceInstance.propose([action], description);
      // we move forward 2 seconds to make sure proposal can be voted on
      await timeTravel({ seconds: 2, mine: true });
      // after the end of the epoch, we  flash borrow and stake GRG in order to gain quorum and > 2/3 of all stake
      amount = parseEther("400000");
      const flashGovernance = await ethers.deployContract("FlashGovernance", [
        await staking.getAddress(),
        await governanceInstance.getAddress(),
        grgTransferProxyAddress,
      ]);
      // we allow the flash governance to move GRG
      await grgToken.approve(await flashGovernance.getAddress(), amount);
      await expect(flashGovernance.flashAttack(poolId, amount))
        .to.emit(governanceInstance, "VoteCast")
        .withArgs(await flashGovernance.getAddress(), 1, VoteType.For, amount)
        .to.emit(flashGovernance, "CatchStringEvent")
        .withArgs("VOTING_CLOSED_ERROR")
        .to.emit(flashGovernance, "CatchStringEvent")
        .withArgs("VOTING_EXECUTION_STATE_ERROR")
        .to.emit(flashGovernance, "CatchStringEvent")
        .withArgs("MOVE_STAKE_AMOUNT_HIGHER_THAN_WITHDRAWABLE_ERROR")
        // will revert without reason in old ERC20
        .to.emit(flashGovernance, "ReturnDataEvent")
        .withArgs("0x");
      // during the next block, transaction will be executed
      await expect(connect(governanceInstance, user2).execute(1)).to.emit(
        grgToken,
        "Approval",
      );
    });
  });
});
