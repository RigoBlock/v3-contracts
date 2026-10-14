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
      // the proxy constructor asserts empty initialization returndata, so every initialization
      // failure surfaces as panic 0x1 through createGovernance, masking the initializer's and
      // the strategy's custom errors (the initializer's own errors are covered by
      // Governance.Initializer.t.sol, which exercises initializeGovernance directly)
      // an EOA strategy fails the factory's own contract check (assert → panic)
      await expect(
        governanceFactory.createGovernance(
          implementation,
          "0x1111111111111111111111111111111111111111",
          parseEther("100000"),
          parseEther("1000000"),
          TimeType.Timestamp,
          "Rigoblock Governance",
        ),
      ).to.be.revertedWithPanic(0x1);
      // a contract without the strategy interface fails the initializer's conformance probe
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
      // out-of-bounds thresholds fail the strategy's validateParams
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
      // a wrong name fails the strategy's assertion
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
      // inputs validation in the rigoblock strategy surfaces the strategy's own errors
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
