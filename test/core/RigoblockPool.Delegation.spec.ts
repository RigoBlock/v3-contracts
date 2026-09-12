import { expect } from "chai";
import { network } from "hardhat";
import { id, ZeroAddress } from "ethers";
import { connect, getFixedGasSigners } from "../shared/helper";
import { createFixture } from "../utils/fixtures";

describe("Delegation", async () => {
  // selector for MockDelegationAdapter.delegationTestWrite()
  const WRITE_SELECTOR = id("delegationTestWrite()").slice(0, 10);

  const setupTests = createFixture(["tests-setup"], async ({ get }) => {
    const [user1, user2, user3] = await getFixedGasSigners();
    const { ethers } = await network.getOrCreate();
    const authority = await ethers.getContractAt(
      "Authority",
      (await get("Authority")).address,
    );
    const factory = await ethers.getContractAt(
      "RigoblockPoolProxyFactory",
      (await get("RigoblockPoolProxyFactory")).address,
    );
    const poolAddress = (
      await factory.createPool.staticCall("testpool", "TEST", ZeroAddress)
    ).newPoolAddress;
    await factory.createPool("testpool", "TEST", ZeroAddress);
    const pool = await ethers.getContractAt("SmartPool", poolAddress);

    // Deploy and register the mock adapter
    const mockAdapter = await ethers.deployContract("MockDelegationAdapter");
    await authority.setAdapter(await mockAdapter.getAddress(), true);
    await authority.addMethod(WRITE_SELECTOR, await mockAdapter.getAddress());

    // adapter interface bound to the pool proxy address, as tests call it via the pool
    const mockAdapterAtPool = await ethers.getContractAt(
      "MockDelegationAdapter",
      poolAddress,
    );

    return {
      authority,
      factory,
      pool,
      mockAdapter,
      mockAdapterAtPool,
      user1,
      user2,
      user3,
    };
  });

  describe("updateDelegation", async () => {
    it("should revert when caller is not the pool owner", async () => {
      const { pool, user2 } = await setupTests();
      await expect(
        connect(pool, user2).updateDelegation([
          {
            delegated: user2.address,
            selector: WRITE_SELECTOR,
            isDelegated: true,
          },
        ]),
      ).to.be.revertedWithCustomError(pool, "PoolCallerIsNotOwner");
    });

    it("should grant delegation for a single (selector, address) pair", async () => {
      const { pool, user2, mockAdapterAtPool } = await setupTests();
      const { ethers } = await network.getOrCreate();
      await pool.updateDelegation([
        {
          delegated: user2.address,
          selector: WRITE_SELECTOR,
          isDelegated: true,
        },
      ]);
      // Verify delegated address can call write method without revert
      await expect(
        connect(mockAdapterAtPool, user2).delegationTestWrite(),
      ).to.not.revert(ethers);
    });

    it("should emit DelegationUpdated when granting access", async () => {
      const { pool, user2 } = await setupTests();
      const poolAddress = await pool.getAddress();
      await expect(
        pool.updateDelegation([
          {
            delegated: user2.address,
            selector: WRITE_SELECTOR,
            isDelegated: true,
          },
        ]),
      )
        .to.emit(pool, "DelegationUpdated")
        .withArgs(poolAddress, user2.address, WRITE_SELECTOR, true);
    });

    it("should revoke delegation for a single (selector, address) pair", async () => {
      const { pool, user2, mockAdapterAtPool } = await setupTests();
      const { ethers } = await network.getOrCreate();
      // Grant first
      await pool.updateDelegation([
        {
          delegated: user2.address,
          selector: WRITE_SELECTOR,
          isDelegated: true,
        },
      ]);
      // Revoke
      await pool.updateDelegation([
        {
          delegated: user2.address,
          selector: WRITE_SELECTOR,
          isDelegated: false,
        },
      ]);
      // Confirm write is no longer possible (staticcall → revert)
      await expect(
        connect(mockAdapterAtPool, user2).delegationTestWrite(),
      ).to.revert(ethers);
    });

    it("should emit DelegationUpdated when revoking access", async () => {
      const { pool, user2 } = await setupTests();
      const poolAddress = await pool.getAddress();
      await pool.updateDelegation([
        {
          delegated: user2.address,
          selector: WRITE_SELECTOR,
          isDelegated: true,
        },
      ]);
      await expect(
        pool.updateDelegation([
          {
            delegated: user2.address,
            selector: WRITE_SELECTOR,
            isDelegated: false,
          },
        ]),
      )
        .to.emit(pool, "DelegationUpdated")
        .withArgs(poolAddress, user2.address, WRITE_SELECTOR, false);
    });

    it("should handle a batch of mixed add and remove operations", async () => {
      const { pool, user2, user3, mockAdapterAtPool } = await setupTests();
      const { ethers } = await network.getOrCreate();

      await pool.updateDelegation([
        {
          delegated: user2.address,
          selector: WRITE_SELECTOR,
          isDelegated: true,
        },
        {
          delegated: user3.address,
          selector: WRITE_SELECTOR,
          isDelegated: true,
        },
      ]);

      await expect(
        connect(mockAdapterAtPool, user2).delegationTestWrite(),
      ).to.not.revert(ethers);
      await expect(
        connect(mockAdapterAtPool, user3).delegationTestWrite(),
      ).to.not.revert(ethers);

      // Revoke user2 in the same batch as granting user3 (already granted, idempotent)
      await pool.updateDelegation([
        {
          delegated: user2.address,
          selector: WRITE_SELECTOR,
          isDelegated: false,
        },
      ]);
      await expect(
        connect(mockAdapterAtPool, user2).delegationTestWrite(),
      ).to.revert(ethers);
      await expect(
        connect(mockAdapterAtPool, user3).delegationTestWrite(),
      ).to.not.revert(ethers);
    });

    it("should be idempotent when adding an already-delegated pair", async () => {
      const { pool, user2 } = await setupTests();
      await pool.updateDelegation([
        {
          delegated: user2.address,
          selector: WRITE_SELECTOR,
          isDelegated: true,
        },
      ]);
      // Adding again: no storage change → no event
      await expect(
        pool.updateDelegation([
          {
            delegated: user2.address,
            selector: WRITE_SELECTOR,
            isDelegated: true,
          },
        ]),
      ).to.not.emit(pool, "DelegationUpdated");
    });

    it("should be idempotent when removing a non-existent pair", async () => {
      const { pool, user2 } = await setupTests();
      // Removing a pair that was never added: no storage change → no event, no revert
      await expect(
        pool.updateDelegation([
          {
            delegated: user2.address,
            selector: WRITE_SELECTOR,
            isDelegated: false,
          },
        ]),
      ).to.not.emit(pool, "DelegationUpdated");
    });

    it("should not grant owner-level write access to unrelated selectors", async () => {
      const { pool, user2, mockAdapterAtPool } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const OTHER_SELECTOR = id("otherMethod()").slice(0, 10);
      await pool.updateDelegation([
        {
          delegated: user2.address,
          selector: OTHER_SELECTOR,
          isDelegated: true,
        },
      ]);
      // user2 is delegated for OTHER_SELECTOR but NOT for WRITE_SELECTOR
      await expect(
        connect(mockAdapterAtPool, user2).delegationTestWrite(),
      ).to.revert(ethers);
    });
  });

  describe("revokeAllDelegations", async () => {
    it("should revert when caller is not the pool owner", async () => {
      const { pool, user2 } = await setupTests();
      await expect(
        connect(pool, user2).revokeAllDelegations(user2.address),
      ).to.be.revertedWithCustomError(pool, "PoolCallerIsNotOwner");
    });

    it("should revoke all selectors for a delegated address at once", async () => {
      const { pool, user2, mockAdapterAtPool } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const SEL2 = id("anotherMethod()").slice(0, 10);

      await pool.updateDelegation([
        {
          delegated: user2.address,
          selector: WRITE_SELECTOR,
          isDelegated: true,
        },
        { delegated: user2.address, selector: SEL2, isDelegated: true },
      ]);

      await pool.revokeAllDelegations(user2.address);

      // Both selectors should now be revoked
      await expect(
        connect(mockAdapterAtPool, user2).delegationTestWrite(),
      ).to.revert(ethers);
    });

    it("should emit DelegationUpdated for each revoked selector", async () => {
      const { pool, user2 } = await setupTests();
      const poolAddress = await pool.getAddress();
      await pool.updateDelegation([
        {
          delegated: user2.address,
          selector: WRITE_SELECTOR,
          isDelegated: true,
        },
      ]);
      const tx = await pool.revokeAllDelegations(user2.address);
      await expect(tx)
        .to.emit(pool, "DelegationUpdated")
        .withArgs(poolAddress, user2.address, WRITE_SELECTOR, false);
    });

    it("should succeed without emitting events when address has no delegations", async () => {
      const { pool, user2 } = await setupTests();
      const { ethers } = await network.getOrCreate();
      // No delegations set for user2
      await expect(pool.revokeAllDelegations(user2.address)).to.not.revert(
        ethers,
      );
    });

    it("should only affect the target address, leaving other delegations intact", async () => {
      const { pool, user2, user3, mockAdapterAtPool } = await setupTests();
      const { ethers } = await network.getOrCreate();
      await pool.updateDelegation([
        {
          delegated: user2.address,
          selector: WRITE_SELECTOR,
          isDelegated: true,
        },
        {
          delegated: user3.address,
          selector: WRITE_SELECTOR,
          isDelegated: true,
        },
      ]);

      await pool.revokeAllDelegations(user2.address);

      // user3 should still be delegated
      await expect(
        connect(mockAdapterAtPool, user3).delegationTestWrite(),
      ).to.not.revert(ethers);
    });
  });

  describe("revokeAllDelegationsForSelector", async () => {
    it("should revert when caller is not the pool owner", async () => {
      const { pool, user2 } = await setupTests();
      await expect(
        connect(pool, user2).revokeAllDelegationsForSelector(WRITE_SELECTOR),
      ).to.be.revertedWithCustomError(pool, "PoolCallerIsNotOwner");
    });

    it("should revoke all addresses delegated for a selector at once", async () => {
      const { pool, user2, user3, mockAdapterAtPool } = await setupTests();
      const { ethers } = await network.getOrCreate();
      await pool.updateDelegation([
        {
          delegated: user2.address,
          selector: WRITE_SELECTOR,
          isDelegated: true,
        },
        {
          delegated: user3.address,
          selector: WRITE_SELECTOR,
          isDelegated: true,
        },
      ]);

      await pool.revokeAllDelegationsForSelector(WRITE_SELECTOR);

      await expect(
        connect(mockAdapterAtPool, user2).delegationTestWrite(),
      ).to.revert(ethers);
      await expect(
        connect(mockAdapterAtPool, user3).delegationTestWrite(),
      ).to.revert(ethers);
    });

    it("should emit DelegationUpdated for each revoked address", async () => {
      const { pool, user2 } = await setupTests();
      const poolAddress = await pool.getAddress();
      await pool.updateDelegation([
        {
          delegated: user2.address,
          selector: WRITE_SELECTOR,
          isDelegated: true,
        },
      ]);
      const tx = await pool.revokeAllDelegationsForSelector(WRITE_SELECTOR);
      await expect(tx)
        .to.emit(pool, "DelegationUpdated")
        .withArgs(poolAddress, user2.address, WRITE_SELECTOR, false);
    });

    it("should succeed without emitting events when selector has no delegations", async () => {
      const { pool } = await setupTests();
      const { ethers } = await network.getOrCreate();
      await expect(
        pool.revokeAllDelegationsForSelector(WRITE_SELECTOR),
      ).to.not.revert(ethers);
    });

    it("should only affect the target selector, leaving other selector delegations intact", async () => {
      const { pool, user2, mockAdapterAtPool } = await setupTests();
      const { ethers } = await network.getOrCreate();
      const SEL2 = id("anotherMethod()").slice(0, 10);

      await pool.updateDelegation([
        {
          delegated: user2.address,
          selector: WRITE_SELECTOR,
          isDelegated: true,
        },
        { delegated: user2.address, selector: SEL2, isDelegated: true },
      ]);

      await pool.revokeAllDelegationsForSelector(WRITE_SELECTOR);

      // user2 still has delegation for SEL2 (even though it's not a real adapter method)
      // Verify WRITE_SELECTOR is revoked
      await expect(
        connect(mockAdapterAtPool, user2).delegationTestWrite(),
      ).to.revert(ethers);
    });
  });

  describe("fallback write-mode gating", async () => {
    it("should allow pool owner to call adapter in write mode without delegation", async () => {
      const { user1, mockAdapterAtPool } = await setupTests();
      const { ethers } = await network.getOrCreate();
      // user1 is the pool owner - should always be able to delegatecall
      await expect(
        connect(mockAdapterAtPool, user1).delegationTestWrite(),
      ).to.not.revert(ethers);
    });

    it("should NOT allow arbitrary address to call adapter in write mode", async () => {
      const { user2, mockAdapterAtPool } = await setupTests();
      const { ethers } = await network.getOrCreate();
      await expect(
        connect(mockAdapterAtPool, user2).delegationTestWrite(),
      ).to.revert(ethers);
    });

    it("should allow delegated address to call its specific adapter selector in write mode", async () => {
      const { pool, user2, mockAdapterAtPool } = await setupTests();
      const { ethers } = await network.getOrCreate();
      await pool.updateDelegation([
        {
          delegated: user2.address,
          selector: WRITE_SELECTOR,
          isDelegated: true,
        },
      ]);
      await expect(
        connect(mockAdapterAtPool, user2).delegationTestWrite(),
      ).to.not.revert(ethers);
    });

    it("should revert for delegated address after its delegation is revoked", async () => {
      const { pool, user2, mockAdapterAtPool } = await setupTests();
      const { ethers } = await network.getOrCreate();
      await pool.updateDelegation([
        {
          delegated: user2.address,
          selector: WRITE_SELECTOR,
          isDelegated: true,
        },
      ]);
      await pool.updateDelegation([
        {
          delegated: user2.address,
          selector: WRITE_SELECTOR,
          isDelegated: false,
        },
      ]);
      await expect(
        connect(mockAdapterAtPool, user2).delegationTestWrite(),
      ).to.revert(ethers);
    });

    it("new owner should not lose write access when former owner had delegated addresses", async () => {
      const { pool, user2, user3, mockAdapterAtPool } = await setupTests();
      const { ethers } = await network.getOrCreate();
      await pool.updateDelegation([
        {
          delegated: user2.address,
          selector: WRITE_SELECTOR,
          isDelegated: true,
        },
      ]);
      // Transfer ownership to user3
      await pool.setOwner(user3.address);

      // New owner still has write access
      await expect(
        connect(mockAdapterAtPool, user3).delegationTestWrite(),
      ).to.not.revert(ethers);
      // Previously delegated address still has its delegation (delegation follows storage, not owner)
      await expect(
        connect(mockAdapterAtPool, user2).delegationTestWrite(),
      ).to.not.revert(ethers);
    });
  });

  describe("getDelegatedAddresses / getDelegatedSelectors", async () => {
    it("should return empty arrays when no delegation exists", async () => {
      const { pool, user2 } = await setupTests();
      const addrs = Array.from(
        await pool.getDelegatedAddresses(WRITE_SELECTOR),
      );
      expect(addrs).to.deep.eq([]);
      const sels = Array.from(await pool.getDelegatedSelectors(user2.address));
      expect(sels).to.deep.eq([]);
    });

    it("should list a single delegated address for a selector", async () => {
      const { pool, user2 } = await setupTests();
      await pool.updateDelegation([
        {
          delegated: user2.address,
          selector: WRITE_SELECTOR,
          isDelegated: true,
        },
      ]);
      const addrs = Array.from(
        await pool.getDelegatedAddresses(WRITE_SELECTOR),
      );
      expect(addrs).to.deep.eq([user2.address]);
    });

    it("should list all delegated addresses for a selector", async () => {
      const { pool, user2, user3 } = await setupTests();
      await pool.updateDelegation([
        {
          delegated: user2.address,
          selector: WRITE_SELECTOR,
          isDelegated: true,
        },
        {
          delegated: user3.address,
          selector: WRITE_SELECTOR,
          isDelegated: true,
        },
      ]);
      const addrs = Array.from(
        await pool.getDelegatedAddresses(WRITE_SELECTOR),
      );
      expect(addrs).to.have.members([user2.address, user3.address]);
    });

    it("should list all selectors delegated to an address", async () => {
      const { pool, user2 } = await setupTests();
      const SEL2 = id("anotherMethod()").slice(0, 10);
      await pool.updateDelegation([
        {
          delegated: user2.address,
          selector: WRITE_SELECTOR,
          isDelegated: true,
        },
        { delegated: user2.address, selector: SEL2, isDelegated: true },
      ]);
      const sels = Array.from(await pool.getDelegatedSelectors(user2.address));
      expect(sels).to.have.members([WRITE_SELECTOR, SEL2]);
    });

    it("should remove an address from getDelegatedAddresses after revocation", async () => {
      const { pool, user2, user3 } = await setupTests();
      await pool.updateDelegation([
        {
          delegated: user2.address,
          selector: WRITE_SELECTOR,
          isDelegated: true,
        },
        {
          delegated: user3.address,
          selector: WRITE_SELECTOR,
          isDelegated: true,
        },
      ]);
      await pool.updateDelegation([
        {
          delegated: user2.address,
          selector: WRITE_SELECTOR,
          isDelegated: false,
        },
      ]);
      const addrs = Array.from(
        await pool.getDelegatedAddresses(WRITE_SELECTOR),
      );
      expect(addrs).to.deep.eq([user3.address]);
      expect(addrs).to.not.include(user2.address);
    });

    it("should remove a selector from getDelegatedSelectors after revocation", async () => {
      const { pool, user2 } = await setupTests();
      const SEL2 = id("anotherMethod()").slice(0, 10);
      await pool.updateDelegation([
        {
          delegated: user2.address,
          selector: WRITE_SELECTOR,
          isDelegated: true,
        },
        { delegated: user2.address, selector: SEL2, isDelegated: true },
      ]);
      await pool.updateDelegation([
        {
          delegated: user2.address,
          selector: WRITE_SELECTOR,
          isDelegated: false,
        },
      ]);
      const sels = Array.from(await pool.getDelegatedSelectors(user2.address));
      expect(sels).to.deep.eq([SEL2]);
      expect(sels).to.not.include(WRITE_SELECTOR);
    });

    it("should return empty arrays after revokeAllDelegations", async () => {
      const { pool, user2 } = await setupTests();
      const SEL2 = id("anotherMethod()").slice(0, 10);
      await pool.updateDelegation([
        {
          delegated: user2.address,
          selector: WRITE_SELECTOR,
          isDelegated: true,
        },
        { delegated: user2.address, selector: SEL2, isDelegated: true },
      ]);
      await pool.revokeAllDelegations(user2.address);
      expect(
        Array.from(await pool.getDelegatedSelectors(user2.address)),
      ).to.deep.eq([]);
      // selector-side entry cleaned up too
      expect(
        Array.from(await pool.getDelegatedAddresses(WRITE_SELECTOR)),
      ).to.deep.eq([]);
    });

    it("should return empty arrays after revokeAllDelegationsForSelector", async () => {
      const { pool, user2, user3 } = await setupTests();
      await pool.updateDelegation([
        {
          delegated: user2.address,
          selector: WRITE_SELECTOR,
          isDelegated: true,
        },
        {
          delegated: user3.address,
          selector: WRITE_SELECTOR,
          isDelegated: true,
        },
      ]);
      await pool.revokeAllDelegationsForSelector(WRITE_SELECTOR);
      expect(
        Array.from(await pool.getDelegatedAddresses(WRITE_SELECTOR)),
      ).to.deep.eq([]);
      // address-side entries cleaned up too
      expect(
        Array.from(await pool.getDelegatedSelectors(user2.address)),
      ).to.deep.eq([]);
      expect(
        Array.from(await pool.getDelegatedSelectors(user3.address)),
      ).to.deep.eq([]);
    });
  });
});
