import { expect } from "chai";
import { network } from "hardhat";
import { parseEther } from "ethers";
import { createFixture } from "../utils/fixtures";
import { TimeType } from "../utils/utils";

describe("Governance Factory", async () => {
  const setupTests = createFixture(["governance-tests"], async ({ get }) => {
    const { ethers } = await network.getOrCreate();
    const governanceFactory = await ethers.getContractAt(
      "RigoblockGovernanceFactory",
      (await get("RigoblockGovernanceFactory")).address,
    );
    const implementation = (await get("RigoblockGovernance")).address;
    const strategy = (await get("RigoblockGovernanceStrategy")).address;
    return {
      implementation,
      strategy,
      governanceFactory,
    };
  });

  describe("createGovernance", async () => {
    it("should not allow deploying governance if params verification fails", async () => {
      const { governanceFactory, implementation, strategy } =
        await setupTests();
      // will revert if strategy contract does not implement method assertValidInitParams
      await expect(
        governanceFactory.createGovernance(
          implementation,
          implementation,
          parseEther("100000"),
          parseEther("1000000"),
          TimeType.Timestamp,
          "Rigoblock Governance",
        ),
      ).to.be.revertedWithPanic(0x1);
      // will revert without reason if assertion in strategy contract fails
      await expect(
        governanceFactory.createGovernance(
          implementation,
          strategy,
          parseEther("10000000"),
          parseEther("1000000"),
          TimeType.Timestamp,
          "Rigoblock Governance",
        ),
      ).to.be.revertedWithPanic(0x1);
      await expect(
        governanceFactory.createGovernance(
          implementation,
          strategy,
          parseEther("100000"),
          parseEther("1000000"),
          TimeType.Timestamp,
          "Any Governance",
        ),
      ).to.be.revertedWithPanic(0x1);
    });

    it("should emit event when creating new governance", async () => {
      const { governanceFactory, implementation, strategy } =
        await setupTests();
      // inputs validation in rigoblock strategy reverts without error, but other strategies could revert with error
      const governance = await governanceFactory.createGovernance.staticCall(
        implementation,
        strategy,
        parseEther("100000"),
        parseEther("1000000"),
        TimeType.Timestamp,
        "Rigoblock Governance",
      );
      await expect(
        governanceFactory.createGovernance(
          implementation,
          strategy,
          parseEther("100000"),
          parseEther("1000000"),
          TimeType.Timestamp,
          "Rigoblock Governance",
        ),
      )
        .to.emit(governanceFactory, "GovernanceCreated")
        .withArgs(governance);
    });
  });
});
