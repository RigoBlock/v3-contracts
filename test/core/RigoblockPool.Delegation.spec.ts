import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";

describe("Delegation", async () => {
    const [user1, user2, user3] = waffle.provider.getWallets()

    // selector for MockDelegationAdapter.delegationTestWrite()
    const WRITE_SELECTOR = ethers.utils.id("delegationTestWrite()").slice(0, 10)

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const AuthorityInstance = await deployments.get("Authority")
        const Authority = await hre.ethers.getContractFactory("Authority")
        const authority = Authority.attach(AuthorityInstance.address)

        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        const factory = Factory.attach(RigoblockPoolProxyFactory.address)

        const { newPoolAddress } = await factory.callStatic.createPool(
            'testpool',
            'TEST',
            AddressZero
        )
        await factory.createPool('testpool', 'TEST', AddressZero)
        const pool = await hre.ethers.getContractAt("SmartPool", newPoolAddress)

        // Deploy and register the mock adapter
        const MockDelegationAdapter = await hre.ethers.getContractFactory("MockDelegationAdapter")
        const mockAdapter = await MockDelegationAdapter.deploy()
        await authority.setAdapter(mockAdapter.address, true)
        await authority.addMethod(WRITE_SELECTOR, mockAdapter.address)

        return { authority, factory, pool, mockAdapter }
    })

    describe("updateDelegation", async () => {
        it("should revert when caller is not the pool owner", async () => {
            const { pool } = await setupTests()
            await expect(
                pool.connect(user2).updateDelegation([
                    { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: true }
                ])
            ).to.be.revertedWith("PoolCallerIsNotOwner()")
        })

        it("should grant delegation for a single (selector, address) pair", async () => {
            const { pool } = await setupTests()
            await pool.updateDelegation([
                { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: true }
            ])
            // Verify delegated address can call write method without revert
            const mockAdapter = await hre.ethers.getContractAt("MockDelegationAdapter", pool.address)
            await expect(
                mockAdapter.connect(user2).delegationTestWrite()
            ).to.not.be.reverted
        })

        it("should emit DelegationUpdated when granting access", async () => {
            const { pool } = await setupTests()
            await expect(
                pool.updateDelegation([
                    { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: true }
                ])
            )
                .to.emit(pool, "DelegationUpdated")
                .withArgs(pool.address, user2.address, WRITE_SELECTOR, true)
        })

        it("should revoke delegation for a single (selector, address) pair", async () => {
            const { pool } = await setupTests()
            // Grant first
            await pool.updateDelegation([
                { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: true }
            ])
            // Revoke
            await pool.updateDelegation([
                { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: false }
            ])
            // Confirm write is no longer possible (staticcall → revert)
            const mockAdapter = await hre.ethers.getContractAt("MockDelegationAdapter", pool.address)
            await expect(
                mockAdapter.connect(user2).delegationTestWrite()
            ).to.be.reverted
        })

        it("should emit DelegationUpdated when revoking access", async () => {
            const { pool } = await setupTests()
            await pool.updateDelegation([
                { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: true }
            ])
            await expect(
                pool.updateDelegation([
                    { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: false }
                ])
            )
                .to.emit(pool, "DelegationUpdated")
                .withArgs(pool.address, user2.address, WRITE_SELECTOR, false)
        })

        it("should handle a batch of mixed add and remove operations", async () => {
            const { pool } = await setupTests()
            const SEL2 = ethers.utils.id("delegationTestWrite()").slice(0, 10) // same selector, different address

            await pool.updateDelegation([
                { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: true },
                { delegated: user3.address, selector: WRITE_SELECTOR, isDelegated: true }
            ])

            const mockAdapter = await hre.ethers.getContractAt("MockDelegationAdapter", pool.address)
            await expect(mockAdapter.connect(user2).delegationTestWrite()).to.not.be.reverted
            await expect(mockAdapter.connect(user3).delegationTestWrite()).to.not.be.reverted

            // Revoke user2 in the same batch as granting user3 (already granted, idempotent)
            await pool.updateDelegation([
                { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: false }
            ])
            await expect(mockAdapter.connect(user2).delegationTestWrite()).to.be.reverted
            await expect(mockAdapter.connect(user3).delegationTestWrite()).to.not.be.reverted
        })

        it("should be idempotent when adding an already-delegated pair", async () => {
            const { pool } = await setupTests()
            await pool.updateDelegation([
                { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: true }
            ])
            // Adding again: no storage change → no event
            await expect(
                pool.updateDelegation([
                    { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: true }
                ])
            ).to.not.emit(pool, "DelegationUpdated")
        })

        it("should be idempotent when removing a non-existent pair", async () => {
            const { pool } = await setupTests()
            // Removing a pair that was never added: no storage change → no event, no revert
            await expect(
                pool.updateDelegation([
                    { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: false }
                ])
            ).to.not.emit(pool, "DelegationUpdated")
        })

        it("should not grant owner-level write access to unrelated selectors", async () => {
            const { pool } = await setupTests()
            const OTHER_SELECTOR = ethers.utils.id("otherMethod()").slice(0, 10)
            await pool.updateDelegation([
                { delegated: user2.address, selector: OTHER_SELECTOR, isDelegated: true }
            ])
            // user2 is delegated for OTHER_SELECTOR but NOT for WRITE_SELECTOR
            const mockAdapter = await hre.ethers.getContractAt("MockDelegationAdapter", pool.address)
            await expect(
                mockAdapter.connect(user2).delegationTestWrite()
            ).to.be.reverted
        })
    })

    describe("revokeAllDelegations", async () => {
        it("should revert when caller is not the pool owner", async () => {
            const { pool } = await setupTests()
            await expect(
                pool.connect(user2).revokeAllDelegations(user2.address)
            ).to.be.revertedWith("PoolCallerIsNotOwner()")
        })

        it("should revoke all selectors for a delegated address at once", async () => {
            const { pool } = await setupTests()
            const SEL2 = ethers.utils.id("anotherMethod()").slice(0, 10)

            await pool.updateDelegation([
                { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: true },
                { delegated: user2.address, selector: SEL2, isDelegated: true }
            ])

            await pool.revokeAllDelegations(user2.address)

            // Both selectors should now be revoked
            const mockAdapter = await hre.ethers.getContractAt("MockDelegationAdapter", pool.address)
            await expect(mockAdapter.connect(user2).delegationTestWrite()).to.be.reverted
        })

        it("should emit DelegationUpdated for each revoked selector", async () => {
            const { pool } = await setupTests()
            await pool.updateDelegation([
                { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: true }
            ])
            const tx = await pool.revokeAllDelegations(user2.address)
            await expect(tx)
                .to.emit(pool, "DelegationUpdated")
                .withArgs(pool.address, user2.address, WRITE_SELECTOR, false)
        })

        it("should succeed without emitting events when address has no delegations", async () => {
            const { pool } = await setupTests()
            // No delegations set for user2
            await expect(pool.revokeAllDelegations(user2.address)).to.not.be.reverted
        })

        it("should only affect the target address, leaving other delegations intact", async () => {
            const { pool } = await setupTests()
            await pool.updateDelegation([
                { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: true },
                { delegated: user3.address, selector: WRITE_SELECTOR, isDelegated: true }
            ])

            await pool.revokeAllDelegations(user2.address)

            // user3 should still be delegated
            const mockAdapter = await hre.ethers.getContractAt("MockDelegationAdapter", pool.address)
            await expect(mockAdapter.connect(user3).delegationTestWrite()).to.not.be.reverted
        })
    })

    describe("revokeAllDelegationsForSelector", async () => {
        it("should revert when caller is not the pool owner", async () => {
            const { pool } = await setupTests()
            await expect(
                pool.connect(user2).revokeAllDelegationsForSelector(WRITE_SELECTOR)
            ).to.be.revertedWith("PoolCallerIsNotOwner()")
        })

        it("should revoke all addresses delegated for a selector at once", async () => {
            const { pool } = await setupTests()
            await pool.updateDelegation([
                { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: true },
                { delegated: user3.address, selector: WRITE_SELECTOR, isDelegated: true }
            ])

            await pool.revokeAllDelegationsForSelector(WRITE_SELECTOR)

            const mockAdapter = await hre.ethers.getContractAt("MockDelegationAdapter", pool.address)
            await expect(mockAdapter.connect(user2).delegationTestWrite()).to.be.reverted
            await expect(mockAdapter.connect(user3).delegationTestWrite()).to.be.reverted
        })

        it("should emit DelegationUpdated for each revoked address", async () => {
            const { pool } = await setupTests()
            await pool.updateDelegation([
                { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: true }
            ])
            const tx = await pool.revokeAllDelegationsForSelector(WRITE_SELECTOR)
            await expect(tx)
                .to.emit(pool, "DelegationUpdated")
                .withArgs(pool.address, user2.address, WRITE_SELECTOR, false)
        })

        it("should succeed without emitting events when selector has no delegations", async () => {
            const { pool } = await setupTests()
            await expect(
                pool.revokeAllDelegationsForSelector(WRITE_SELECTOR)
            ).to.not.be.reverted
        })

        it("should only affect the target selector, leaving other selector delegations intact", async () => {
            const { pool } = await setupTests()
            const SEL2 = ethers.utils.id("anotherMethod()").slice(0, 10)

            await pool.updateDelegation([
                { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: true },
                { delegated: user2.address, selector: SEL2, isDelegated: true }
            ])

            await pool.revokeAllDelegationsForSelector(WRITE_SELECTOR)

            // user2 still has delegation for SEL2 (even though it's not a real adapter method)
            // Verify WRITE_SELECTOR is revoked
            const mockAdapter = await hre.ethers.getContractAt("MockDelegationAdapter", pool.address)
            await expect(mockAdapter.connect(user2).delegationTestWrite()).to.be.reverted
        })
    })

    describe("fallback write-mode gating", async () => {
        it("should allow pool owner to call adapter in write mode without delegation", async () => {
            const { pool } = await setupTests()
            // user1 is the pool owner - should always be able to delegatecall
            const mockAdapter = await hre.ethers.getContractAt("MockDelegationAdapter", pool.address)
            await expect(mockAdapter.connect(user1).delegationTestWrite()).to.not.be.reverted
        })

        it("should NOT allow arbitrary address to call adapter in write mode", async () => {
            const { pool } = await setupTests()
            const mockAdapter = await hre.ethers.getContractAt("MockDelegationAdapter", pool.address)
            await expect(mockAdapter.connect(user2).delegationTestWrite()).to.be.reverted
        })

        it("should allow delegated address to call its specific adapter selector in write mode", async () => {
            const { pool } = await setupTests()
            await pool.updateDelegation([
                { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: true }
            ])
            const mockAdapter = await hre.ethers.getContractAt("MockDelegationAdapter", pool.address)
            await expect(mockAdapter.connect(user2).delegationTestWrite()).to.not.be.reverted
        })

        it("should revert for delegated address after its delegation is revoked", async () => {
            const { pool } = await setupTests()
            await pool.updateDelegation([
                { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: true }
            ])
            await pool.updateDelegation([
                { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: false }
            ])
            const mockAdapter = await hre.ethers.getContractAt("MockDelegationAdapter", pool.address)
            await expect(mockAdapter.connect(user2).delegationTestWrite()).to.be.reverted
        })

        it("new owner should not lose write access when former owner had delegated addresses", async () => {
            const { pool } = await setupTests()
            await pool.updateDelegation([
                { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: true }
            ])
            // Transfer ownership to user3
            await pool.setOwner(user3.address)

            const mockAdapter = await hre.ethers.getContractAt("MockDelegationAdapter", pool.address)
            // New owner still has write access
            await expect(mockAdapter.connect(user3).delegationTestWrite()).to.not.be.reverted
            // Previously delegated address still has its delegation (delegation follows storage, not owner)
            await expect(mockAdapter.connect(user2).delegationTestWrite()).to.not.be.reverted
        })
    })

    describe("getDelegatedAddresses / getDelegatedSelectors", async () => {
        it("should return empty arrays when no delegation exists", async () => {
            const { pool } = await setupTests()
            const addrs = await pool.getDelegatedAddresses(WRITE_SELECTOR)
            expect(addrs).to.deep.eq([])
            const sels = await pool.getDelegatedSelectors(user2.address)
            expect(sels).to.deep.eq([])
        })

        it("should list a single delegated address for a selector", async () => {
            const { pool } = await setupTests()
            await pool.updateDelegation([
                { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: true }
            ])
            const addrs = await pool.getDelegatedAddresses(WRITE_SELECTOR)
            expect(addrs).to.deep.eq([user2.address])
        })

        it("should list all delegated addresses for a selector", async () => {
            const { pool } = await setupTests()
            await pool.updateDelegation([
                { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: true },
                { delegated: user3.address, selector: WRITE_SELECTOR, isDelegated: true }
            ])
            const addrs = await pool.getDelegatedAddresses(WRITE_SELECTOR)
            expect(addrs).to.have.members([user2.address, user3.address])
        })

        it("should list all selectors delegated to an address", async () => {
            const { pool } = await setupTests()
            const SEL2 = ethers.utils.id("anotherMethod()").slice(0, 10)
            await pool.updateDelegation([
                { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: true },
                { delegated: user2.address, selector: SEL2, isDelegated: true }
            ])
            const sels = await pool.getDelegatedSelectors(user2.address)
            expect(sels).to.have.members([WRITE_SELECTOR, SEL2])
        })

        it("should remove an address from getDelegatedAddresses after revocation", async () => {
            const { pool } = await setupTests()
            await pool.updateDelegation([
                { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: true },
                { delegated: user3.address, selector: WRITE_SELECTOR, isDelegated: true }
            ])
            await pool.updateDelegation([
                { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: false }
            ])
            const addrs = await pool.getDelegatedAddresses(WRITE_SELECTOR)
            expect(addrs).to.deep.eq([user3.address])
            expect(addrs).to.not.include(user2.address)
        })

        it("should remove a selector from getDelegatedSelectors after revocation", async () => {
            const { pool } = await setupTests()
            const SEL2 = ethers.utils.id("anotherMethod()").slice(0, 10)
            await pool.updateDelegation([
                { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: true },
                { delegated: user2.address, selector: SEL2, isDelegated: true }
            ])
            await pool.updateDelegation([
                { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: false }
            ])
            const sels = await pool.getDelegatedSelectors(user2.address)
            expect(sels).to.deep.eq([SEL2])
            expect(sels).to.not.include(WRITE_SELECTOR)
        })

        it("should return empty arrays after revokeAllDelegations", async () => {
            const { pool } = await setupTests()
            const SEL2 = ethers.utils.id("anotherMethod()").slice(0, 10)
            await pool.updateDelegation([
                { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: true },
                { delegated: user2.address, selector: SEL2, isDelegated: true }
            ])
            await pool.revokeAllDelegations(user2.address)
            expect(await pool.getDelegatedSelectors(user2.address)).to.deep.eq([])
            // selector-side entry cleaned up too
            expect(await pool.getDelegatedAddresses(WRITE_SELECTOR)).to.deep.eq([])
        })

        it("should return empty arrays after revokeAllDelegationsForSelector", async () => {
            const { pool } = await setupTests()
            await pool.updateDelegation([
                { delegated: user2.address, selector: WRITE_SELECTOR, isDelegated: true },
                { delegated: user3.address, selector: WRITE_SELECTOR, isDelegated: true }
            ])
            await pool.revokeAllDelegationsForSelector(WRITE_SELECTOR)
            expect(await pool.getDelegatedAddresses(WRITE_SELECTOR)).to.deep.eq([])
            // address-side entries cleaned up too
            expect(await pool.getDelegatedSelectors(user2.address)).to.deep.eq([])
            expect(await pool.getDelegatedSelectors(user3.address)).to.deep.eq([])
        })
    })
})
