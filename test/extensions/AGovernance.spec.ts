import { expect } from "chai";
import { network } from "hardhat";
import { ZeroAddress, parseEther } from "ethers";
import { timeTravel, ProposedAction, TimeType, VoteType } from "../utils/utils";
import { connect, getFixedGasSigners } from "../shared/helper";
import { createFixture } from "../utils/fixtures";

describe("AGovernance", async () => {
  const description = "gov proposal one";

  const setupTests = createFixture(["tests-setup"], async ({ get }) => {
    const [user1, user2] = await getFixedGasSigners();
    const { ethers } = await network.getOrCreate();
    const factory = await ethers.getContractAt(
      "RigoblockPoolProxyFactory",
      (await get("RigoblockPoolProxyFactory")).address,
    );
    const grgToken = await ethers.getContractAt(
      "RigoToken",
      (await get("RigoToken")).address,
    );
    const grgVault = await ethers.getContractAt(
      "GrgVault",
      (await get("GrgVault")).address,
    );
    const pop = await ethers.getContractAt(
      "ProofOfPerformance",
      (await get("ProofOfPerformance")).address,
    );
    const stakingProxy = await ethers.getContractAt(
      "Staking",
      (await get("StakingProxy")).address,
    );
    const authority = await ethers.getContractAt(
      "Authority",
      (await get("Authority")).address,
    );
    const aStakingAddress = (await get("AStaking")).address;
    // "a694fc3a": "stake(uint256)"
    // "4aace835": "undelegateStake(uint256)",
    // "2e17de78": "unstake(uint256)",
    // "b880660b": "withdrawDelegatorRewards()"
    await authority.addMethod("0xa694fc3a", aStakingAddress);
    await authority.addMethod("0x4aace835", aStakingAddress);
    await authority.addMethod("0x2e17de78", aStakingAddress);
    await authority.addMethod("0xb880660b", aStakingAddress);
    const { newPoolAddress, poolId } = await factory.createPool.staticCall(
      "testpool",
      "TEST",
      ZeroAddress,
    );
    await factory.createPool("testpool", "TEST", ZeroAddress);
    return {
      grgToken,
      grgVault,
      pop,
      stakingProxy,
      newPoolAddress,
      poolId,
      authority,
      user1,
      user2,
    };
  });

  describe("execute", async () => {
    it("should execute a proposal", async () => {
      const {
        stakingProxy,
        grgToken,
        newPoolAddress,
        authority,
        user1,
        user2,
      } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const pool = await ethers.getContractAt(
        "IRigoblockPoolExtended",
        newPoolAddress,
      );
      // used to match custom errors emitted by the implementation
      const poolImplementation = await ethers.getContractAt(
        "SmartPool",
        newPoolAddress,
      );
      const amount = parseEther("400000");
      await grgToken.transfer(newPoolAddress, amount);
      await pool.stake(amount);
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      const govFactory = await ethers.deployContract(
        "RigoblockGovernanceFactory",
      );
      const govImplementation = await ethers.deployContract(
        "RigoblockGovernance",
      );
      const govStrategy = await ethers.deployContract(
        "RigoblockGovernanceStrategy",
        [await stakingProxy.getAddress()],
      );
      // we deploy from user2 as otherwise governance already exists
      const governance = await connect(
        govFactory,
        user2,
      ).createGovernance.staticCall(
        await govImplementation.getAddress(),
        await govStrategy.getAddress(),
        parseEther("100000"), // 100k GRG
        parseEther("400000"), // 400K GRG
        TimeType.Timestamp,
        "Rigoblock Governance",
      );
      await connect(govFactory, user2).createGovernance(
        await govImplementation.getAddress(),
        await govStrategy.getAddress(),
        parseEther("100000"), // 100k GRG
        parseEther("400000"), // 400K GRG
        TimeType.Timestamp,
        "Rigoblock Governance",
      );
      const governanceInstance = await ethers.getContractAt(
        "RigoblockGovernance",
        governance,
      );
      const aGovernance = await ethers.deployContract("AGovernance", [
        governance,
      ]);
      const data = grgToken.interface.encodeFunctionData(
        "approve(address,uint256)",
        [user2.address, amount],
      );
      const action = new ProposedAction(await grgToken.getAddress(), data, 0n);
      await expect(
        pool.propose([action], description),
      ).to.be.revertedWithCustomError(
        poolImplementation,
        "PoolMethodNotAllowed",
      );
      // we add the adapter
      await authority.setAdapter(await aGovernance.getAddress(), true);
      await expect(
        pool.propose([action], description),
      ).to.be.revertedWithCustomError(
        poolImplementation,
        "PoolMethodNotAllowed",
      );
      // we whitelist the methods
      // "56781388": "castVote(uint256, VoteType)",
      // "fe0d94c1": "execute(uint256)",
      // "367015bb": "propose(Proposal, string)"
      await authority.addMethod("0x56781388", await aGovernance.getAddress());
      await authority.addMethod("0xfe0d94c1", await aGovernance.getAddress());
      await authority.addMethod("0x367015bb", await aGovernance.getAddress());
      // we make a proposal
      await expect(pool.propose([action], description)).to.emit(
        governanceInstance,
        "ProposalCreated",
      );
      await timeTravel({ days: 14, mine: true });
      await expect(pool.castVote(1, VoteType.For))
        .to.emit(governanceInstance, "VoteCast")
        .withArgs(await pool.getAddress(), 1, VoteType.For, amount);
      await timeTravel({ days: 7, mine: true });
      // must encode call, as execute method is also present in AUniswapRouter and hardhat will not be able to differentiate
      const encodedExecuteData = pool.interface.encodeFunctionData(
        "execute(uint256)",
        [1],
      );

      // txn will always revert in fallback
      await expect(
        user1.sendTransaction({
          to: await pool.getAddress(),
          value: 0,
          data: encodedExecuteData,
        }),
      )
        .to.emit(governanceInstance, "ProposalExecuted")
        .withArgs(1);
    });
  });
});
