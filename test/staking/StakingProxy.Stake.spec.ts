import { expect } from "chai";
import { network } from "hardhat";
import { parseEther } from "ethers";
import { ZERO_ADDRESS as ZeroAddress } from "../shared/constants";
import { connect, getFixedGasSigners } from "../shared/helper";
import { createFixture } from "../utils/fixtures";
import { timeTravel } from "../utils/utils";

describe("StakingProxy-Stake", async () => {
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
    const stakingProxy = await ethers.getContractAt(
      "Staking",
      (await get("StakingProxy")).address,
    );
    const grgTransferProxyAddress = (await get("ERC20Proxy")).address;
    const { newPoolAddress, poolId } = await factory.createPool.staticCall(
      "testpool",
      "TEST",
      ZeroAddress,
    );
    await factory.createPool("testpool", "TEST", ZeroAddress);
    return {
      factory,
      grgToken,
      grgVault,
      stakingProxy,
      grgTransferProxyAddress,
      newPoolAddress,
      poolId,
      user1,
      user2,
    };
  });

  describe("stake", async () => {
    it("should stake 100 GRG", async () => {
      const {
        grgToken,
        stakingProxy,
        grgTransferProxyAddress,
        grgVault,
        user1,
      } = await setupTests();
      const amount = parseEther("100");
      await grgToken.approve(grgTransferProxyAddress, amount);
      await expect(stakingProxy.stake(amount))
        .to.emit(grgVault, "Deposit")
        .withArgs(user1.address, amount);
    });

    // pool initialization in epoch will fail if all pool delegated below minimum
    it("should allow staking below minimum", async () => {
      const { grgToken, stakingProxy, grgTransferProxyAddress, user1 } =
        await setupTests();
      const amount = parseEther("0.1");
      await grgToken.approve(grgTransferProxyAddress, amount);
      await expect(stakingProxy.stake(amount))
        .to.emit(stakingProxy, "Stake")
        .withArgs(user1.address, amount);
    });

    it("should revert if allowance not set to staking proxy", async () => {
      const { grgToken, stakingProxy, grgTransferProxyAddress, user1 } =
        await setupTests();
      const amount = parseEther("100");
      await expect(stakingProxy.stake(amount)).to.be.revertedWith(
        "TRANSFER_FAILED",
      );
      await grgToken.approve(grgTransferProxyAddress, amount);
      await expect(stakingProxy.stake(amount))
        .to.emit(stakingProxy, "Stake")
        .withArgs(user1.address, amount);
    });

    it("should revert if GRG balance not enough", async () => {
      const { grgToken, stakingProxy, grgTransferProxyAddress, user2 } =
        await setupTests();
      const amount = parseEther("100");
      await connect(grgToken, user2).approve(grgTransferProxyAddress, amount);
      await expect(stakingProxy.stake(amount)).to.be.revertedWith(
        "TRANSFER_FAILED",
      );
      await grgToken.transfer(user2.address, amount);
      await expect(connect(stakingProxy, user2).stake(amount))
        .to.emit(stakingProxy, "Stake")
        .withArgs(user2.address, amount);
    });
  });

  describe("unstake", async () => {
    it("should unstake staked undelegated balance", async () => {
      const {
        grgToken,
        stakingProxy,
        grgTransferProxyAddress,
        grgVault,
        user1,
      } = await setupTests();
      const amount = parseEther("100");
      await grgToken.approve(grgTransferProxyAddress, amount);
      await stakingProxy.stake(amount);
      const withdrawAmount = parseEther("50");
      await expect(stakingProxy.unstake(withdrawAmount))
        .to.emit(stakingProxy, "Unstake")
        .withArgs(user1.address, withdrawAmount);
      await expect(stakingProxy.unstake(withdrawAmount))
        .to.emit(grgToken, "Transfer")
        .withArgs(await grgVault.getAddress(), user1.address, withdrawAmount);
      await expect(stakingProxy.unstake(withdrawAmount)).to.be.revertedWith(
        "MOVE_STAKE_AMOUNT_HIGHER_THAN_WITHDRAWABLE_ERROR",
      );
    });
  });

  describe("moveStake", async () => {
    it("should revert if staking pool does not exist", async () => {
      const { stakingProxy, grgToken, grgTransferProxyAddress, poolId } =
        await setupTests();
      const amount = parseEther("100");
      await grgToken.approve(grgTransferProxyAddress, amount);
      await stakingProxy.stake(amount);
      const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      const toInfo = new StakeInfo(StakeStatus.Delegated, poolId);
      await expect(
        stakingProxy.moveStake(fromInfo, toInfo, amount),
      ).to.be.revertedWith("STAKING_POOL_DOES_NOT_EXIST_ERROR");
    });

    it("should revert if 0 amount delegated", async () => {
      const {
        grgToken,
        stakingProxy,
        grgTransferProxyAddress,
        newPoolAddress,
        poolId,
      } = await setupTests();
      const amount = parseEther("100");
      await grgToken.approve(grgTransferProxyAddress, amount);
      await stakingProxy.stake(amount);
      await stakingProxy.createStakingPool(newPoolAddress);
      const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      const toInfo = new StakeInfo(StakeStatus.Delegated, poolId);
      await expect(
        stakingProxy.moveStake(fromInfo, toInfo, 0),
      ).to.be.revertedWith("MOVE_STAKE_AMOUNT_NULL_ERROR");
    });

    it("should revert if stake status remains undelegated", async () => {
      const {
        grgToken,
        stakingProxy,
        grgTransferProxyAddress,
        newPoolAddress,
        poolId,
      } = await setupTests();
      const amount = parseEther("100");
      await grgToken.approve(grgTransferProxyAddress, amount);
      await stakingProxy.stake(amount);
      await stakingProxy.createStakingPool(newPoolAddress);
      const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      const toInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      await expect(
        stakingProxy.moveStake(fromInfo, toInfo, amount),
      ).to.be.revertedWith("MOVE_STAKE_UNDELEGATED_STATUS_UNCHANGED_ERROR");
    });

    it("should delegate staked amount", async () => {
      const {
        grgToken,
        stakingProxy,
        grgTransferProxyAddress,
        newPoolAddress,
        poolId,
        user1,
      } = await setupTests();
      const amount = parseEther("100");
      await grgToken.approve(grgTransferProxyAddress, amount);
      await stakingProxy.stake(amount);
      await stakingProxy.createStakingPool(newPoolAddress);
      const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      const toInfo = new StakeInfo(StakeStatus.Delegated, poolId);
      await expect(stakingProxy.moveStake(fromInfo, toInfo, amount))
        .to.emit(stakingProxy, "MoveStake")
        .withArgs(
          user1.address,
          amount,
          StakeStatus.Undelegated,
          poolId,
          StakeStatus.Delegated,
          poolId,
        );
      // RIGO-1 (known production behaviour): DELEGATED→DELEGATED with same pointer reverts.
      // Per-pool accounting is handled by _undelegateStake/_delegateStake upstream, but
      // _moveStake itself uses require(!_arePointersEqual) for the global status bucket.
      await expect(
        stakingProxy.moveStake(toInfo, toInfo, amount),
      ).to.be.revertedWith("STAKING_POINTERS_EQUAL_ERROR");
    });

    // RIGO-1: cross-pool DELEGATED→DELEGATED in a single moveStake call also reverts
    // because fromPtr and toPtr both resolve to _ownerStakeByStatus[DELEGATED][owner] —
    // the same storage slot regardless of pool.  The documented workaround is a two-step
    // multicall (DELEGATED→UNDELEGATED, then UNDELEGATED→DELEGATED).
    it("should revert when redelegating between pools in single moveStake call (RIGO-1 known limitation)", async () => {
      const {
        factory,
        grgToken,
        stakingProxy,
        grgTransferProxyAddress,
        newPoolAddress,
        poolId,
      } = await setupTests();
      const amount = parseEther("100");
      await grgToken.approve(grgTransferProxyAddress, amount);
      await stakingProxy.stake(amount);

      const { newPoolAddress: newPoolAddress2, poolId: poolId2 } =
        await factory.createPool.staticCall("testpool2", "TEST2", ZeroAddress);
      await factory.createPool("testpool2", "TEST2", ZeroAddress);

      await stakingProxy.createStakingPool(newPoolAddress);
      await stakingProxy.createStakingPool(newPoolAddress2);

      const undelegated = new StakeInfo(StakeStatus.Undelegated, poolId);
      const toPool1 = new StakeInfo(StakeStatus.Delegated, poolId);
      const toPool2 = new StakeInfo(StakeStatus.Delegated, poolId2);

      await stakingProxy.moveStake(undelegated, toPool1, amount);

      // Single-call cross-pool redelegate reverts (production behaviour)
      await expect(
        stakingProxy.moveStake(toPool1, toPool2, amount),
      ).to.be.revertedWith("STAKING_POINTERS_EQUAL_ERROR");
    });

    it("should not allow to unstake delegated stake", async () => {
      const {
        grgToken,
        stakingProxy,
        grgTransferProxyAddress,
        newPoolAddress,
        poolId,
      } = await setupTests();
      const amount = parseEther("100");
      await grgToken.approve(grgTransferProxyAddress, amount);
      await stakingProxy.stake(amount);
      await stakingProxy.createStakingPool(newPoolAddress);
      const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      const toInfo = new StakeInfo(StakeStatus.Delegated, poolId);
      await stakingProxy.moveStake(fromInfo, toInfo, amount);
      const undelegated = await stakingProxy.getGlobalStakeByStatus(
        StakeStatus.Undelegated,
      );
      const delegated = await stakingProxy.getGlobalStakeByStatus(
        StakeStatus.Delegated,
      );
      expect(undelegated.currentEpoch).to.be.eq(1n);
      expect(undelegated.currentEpochBalance).to.be.eq(amount);
      expect(undelegated.nextEpochBalance).to.be.eq(0n);
      expect(delegated.currentEpoch).to.be.eq(1n);
      expect(delegated.currentEpochBalance).to.be.eq(0n);
      expect(delegated.nextEpochBalance).to.be.eq(amount);
      await expect(stakingProxy.unstake(amount)).to.be.revertedWith(
        "MOVE_STAKE_AMOUNT_HIGHER_THAN_WITHDRAWABLE_ERROR",
      );
    });

    it("should not allow to unstake before epoch end", async () => {
      const {
        grgToken,
        stakingProxy,
        grgTransferProxyAddress,
        newPoolAddress,
        poolId,
      } = await setupTests();
      const amount = parseEther("100");
      await grgToken.approve(grgTransferProxyAddress, amount);
      await stakingProxy.stake(amount);
      await stakingProxy.createStakingPool(newPoolAddress);
      const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      const toInfo = new StakeInfo(StakeStatus.Delegated, poolId);
      await stakingProxy.moveStake(fromInfo, toInfo, amount);
      await expect(
        stakingProxy.moveStake(fromInfo, toInfo, amount),
      ).to.be.revertedWith("STAKING_INSUFFICIENT_BALANCE_ERROR");
      await timeTravel({ days: 14, mine: true });
      await stakingProxy.endEpoch();
      let undelegated;
      let delegated;
      undelegated = await stakingProxy.getGlobalStakeByStatus(
        StakeStatus.Undelegated,
      );
      delegated = await stakingProxy.getGlobalStakeByStatus(
        StakeStatus.Delegated,
      );
      expect(undelegated.currentEpoch).to.be.eq(2n);
      expect(undelegated.currentEpochBalance).to.be.eq(0n);
      expect(undelegated.nextEpochBalance).to.be.eq(0n);
      expect(delegated.currentEpoch).to.be.eq(2n);
      expect(delegated.currentEpochBalance).to.be.eq(amount);
      expect(delegated.nextEpochBalance).to.be.eq(amount);
      await stakingProxy.moveStake(toInfo, fromInfo, amount);
      undelegated = await stakingProxy.getGlobalStakeByStatus(
        StakeStatus.Undelegated,
      );
      delegated = await stakingProxy.getGlobalStakeByStatus(
        StakeStatus.Delegated,
      );
      expect(undelegated.currentEpoch).to.be.eq(2n);
      expect(undelegated.currentEpochBalance).to.be.eq(0n);
      expect(undelegated.nextEpochBalance).to.be.eq(amount);
      // following test will underflow math
      const { ethers } = await network.getOrCreate();
      await expect(stakingProxy.moveStake(toInfo, fromInfo, amount)).to.revert(
        ethers,
      );
      expect(delegated.currentEpoch).to.be.eq(2n);
      expect(delegated.currentEpochBalance).to.be.eq(amount);
      expect(delegated.nextEpochBalance).to.be.eq(0n);
      await expect(stakingProxy.unstake(amount)).to.be.revertedWith(
        "MOVE_STAKE_AMOUNT_HIGHER_THAN_WITHDRAWABLE_ERROR",
      );
    });

    it("should allow to unstake before next epoch start", async () => {
      const {
        grgToken,
        stakingProxy,
        grgTransferProxyAddress,
        newPoolAddress,
        poolId,
        user1,
      } = await setupTests();
      const amount = parseEther("100");
      await grgToken.approve(grgTransferProxyAddress, amount);
      expect(
        await stakingProxy.getTotalStake.staticCall(user1.address),
      ).to.be.eq(0n);
      await stakingProxy.stake(amount);
      expect(
        await stakingProxy.getTotalStake.staticCall(user1.address),
      ).to.be.eq(amount);
      await stakingProxy.createStakingPool(newPoolAddress);
      const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      const toInfo = new StakeInfo(StakeStatus.Delegated, poolId);
      await stakingProxy.moveStake(fromInfo, toInfo, amount);
      const tooBigAmount = parseEther("150");
      // following test underflows balance
      const { ethers } = await network.getOrCreate();
      await expect(
        stakingProxy.moveStake(toInfo, fromInfo, tooBigAmount),
      ).to.revert(ethers);
      await stakingProxy.moveStake(toInfo, fromInfo, amount);
      await expect(stakingProxy.unstake(amount))
        .to.emit(stakingProxy, "Unstake")
        .withArgs(user1.address, amount);
      const undelegated = await stakingProxy.getGlobalStakeByStatus(
        StakeStatus.Undelegated,
      );
      const delegated = await stakingProxy.getGlobalStakeByStatus(
        StakeStatus.Delegated,
      );
      expect(undelegated.currentEpoch).to.be.eq(1n);
      expect(undelegated.currentEpochBalance).to.be.eq(0n);
      expect(undelegated.nextEpochBalance).to.be.eq(0n);
      expect(delegated.currentEpoch).to.be.eq(1n);
      expect(delegated.currentEpochBalance).to.be.eq(0n);
      expect(delegated.nextEpochBalance).to.be.eq(0n);
    });
  });

  describe("getGlobalStakeByStatus", async () => {
    it("should return system stake by status", async () => {
      const { stakingProxy, grgToken, grgTransferProxyAddress, poolId } =
        await setupTests();
      const amount = parseEther("100");
      let undelegated;
      let delegated;
      undelegated = await stakingProxy.getGlobalStakeByStatus(
        StakeStatus.Undelegated,
      );
      delegated = await stakingProxy.getGlobalStakeByStatus(
        StakeStatus.Delegated,
      );
      expect(undelegated.currentEpoch).to.be.eq(1n);
      expect(undelegated.currentEpochBalance).to.be.eq(0n);
      expect(undelegated.nextEpochBalance).to.be.eq(0n);
      expect(delegated.currentEpoch).to.be.eq(1n);
      expect(delegated.currentEpochBalance).to.be.eq(0n);
      expect(delegated.nextEpochBalance).to.be.eq(0n);
      await grgToken.approve(grgTransferProxyAddress, amount);
      await stakingProxy.stake(amount);
      undelegated = await stakingProxy.getGlobalStakeByStatus(
        StakeStatus.Undelegated,
      );
      delegated = await stakingProxy.getGlobalStakeByStatus(
        StakeStatus.Delegated,
      );
      expect(undelegated.currentEpoch).to.be.eq(1n);
      expect(undelegated.currentEpochBalance).to.be.eq(amount);
      expect(undelegated.nextEpochBalance).to.be.eq(amount);
      expect(delegated.currentEpoch).to.be.eq(1n);
      expect(delegated.currentEpochBalance).to.be.eq(0n);
      expect(delegated.nextEpochBalance).to.be.eq(0n);
      const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      const toInfo = new StakeInfo(StakeStatus.Delegated, poolId);
      await expect(
        stakingProxy.moveStake(fromInfo, toInfo, amount),
      ).to.be.revertedWith("STAKING_POOL_DOES_NOT_EXIST_ERROR");
    });
  });

  describe("enterCatastrophicFailure", async () => {
    it("should enter emergency mode", async () => {
      const {
        grgToken,
        stakingProxy,
        grgTransferProxyAddress,
        grgVault,
        user1,
        user2,
      } = await setupTests();
      await expect(grgVault.enterCatastrophicFailure()).to.be.revertedWith(
        "AUTHORIZABLE_SENDER_NOT_AUTHORIZED_ERROR",
      );
      await grgVault.addAuthorizedAddress(user1.address);
      await expect(grgVault.enterCatastrophicFailure())
        .to.emit(grgVault, "InCatastrophicFailureMode")
        .withArgs(user1.address);
      await expect(grgVault.enterCatastrophicFailure()).to.be.revertedWith(
        "GRG_VAULT_IN_CATASTROPHIC_FAILURE_ERROR",
      );
    });
  });

  describe("setGrgProxy", async () => {
    it("should set GRG transfer proxy", async () => {
      const { grgVault, user1, user2 } = await setupTests();
      await expect(grgVault.depositFrom(user1.address, 100)).to.be.revertedWith(
        "GRG_VAULT_ONLY_CALLABLE_BY_STAKING_PROXY_ERROR",
      );
      await expect(grgVault.setGrgProxy(user2.address)).to.be.revertedWith(
        "AUTHORIZABLE_SENDER_NOT_AUTHORIZED_ERROR",
      );
      await grgVault.addAuthorizedAddress(user1.address);
      await expect(grgVault.setGrgProxy(user2.address))
        .to.emit(grgVault, "GrgProxySet")
        .withArgs(user2.address);
      await grgVault.enterCatastrophicFailure();
      await expect(grgVault.setGrgProxy(user2.address)).to.be.revertedWith(
        "GRG_VAULT_IN_CATASTROPHIC_FAILURE_ERROR",
      );
    });
  });

  describe("withdrawAllFrom", async () => {
    it("should revert with null staked amount", async () => {
      const {
        grgToken,
        stakingProxy,
        grgTransferProxyAddress,
        grgVault,
        user1,
        user2,
      } = await setupTests();
      const { ethers } = await network.getOrCreate();
      await expect(grgVault.withdrawAllFrom(user2.address)).to.be.revertedWith(
        "GRG_VAULT_NOT_IN_CATASTROPHIC_FAILURE_ERROR",
      );
      // we need user to be authorized to enter catastrophic failure more
      await grgVault.addAuthorizedAddress(user1.address);
      await grgVault.enterCatastrophicFailure();
      // GRG requires a positive transfer amount (reverts with empty reason)
      await expect(
        grgVault.withdrawAllFrom(user2.address),
      ).to.be.revertedWithoutReason(ethers);
      const amount = parseEther("100");
      await grgToken.approve(grgTransferProxyAddress, amount);
      await expect(stakingProxy.stake(amount)).to.be.revertedWith(
        "GRG_VAULT_IN_CATASTROPHIC_FAILURE_ERROR",
      );
    });

    it("should withdraw with positive stake", async () => {
      const {
        grgToken,
        stakingProxy,
        grgTransferProxyAddress,
        grgVault,
        user1,
        user2,
      } = await setupTests();
      const amount = parseEther("100");
      await grgToken.transfer(user2.address, amount);
      await connect(grgToken, user2).approve(grgTransferProxyAddress, amount);
      await connect(stakingProxy, user2).stake(amount);
      await grgVault.addAuthorizedAddress(user1.address);
      await grgVault.enterCatastrophicFailure();
      const stakedBalance = await grgVault.withdrawAllFrom.staticCall(
        user2.address,
      );
      expect(stakedBalance).to.be.deep.eq(amount);
      await expect(grgVault.withdrawAllFrom(user2.address))
        .to.emit(grgVault, "Withdraw")
        .withArgs(user2.address, stakedBalance);
    });
  });

  describe("batchExecute", async () => {
    it("should execute multiple transactions", async () => {
      const {
        stakingProxy,
        grgToken,
        grgTransferProxyAddress,
        newPoolAddress,
        poolId,
        user1,
      } = await setupTests();
      const amount = parseEther("100");
      await grgToken.approve(grgTransferProxyAddress, amount);
      const encodedStakeData = stakingProxy.interface.encodeFunctionData(
        "stake",
        [amount],
      );
      const encodedCreatePoolData = stakingProxy.interface.encodeFunctionData(
        "createStakingPool",
        [newPoolAddress],
      );
      const fromInfo = new StakeInfo(StakeStatus.Undelegated, poolId);
      const toInfo = new StakeInfo(StakeStatus.Delegated, poolId);
      const encodedMoveStakeData = stakingProxy.interface.encodeFunctionData(
        "moveStake",
        [fromInfo, toInfo, amount],
      );
      const { ethers } = await network.getOrCreate();
      const stakingContract = await ethers.getContractAt(
        "StakingProxy",
        await stakingProxy.getAddress(),
      );
      await expect(
        stakingContract.batchExecute([
          encodedStakeData,
          encodedCreatePoolData,
          encodedMoveStakeData,
        ]),
      )
        .to.emit(stakingProxy, "Stake")
        .withArgs(user1.address, amount)
        .to.emit(stakingProxy, "StakingPoolCreated")
        .withArgs(poolId, user1.address, 700000n)
        .to.emit(stakingProxy, "MoveStake")
        .withArgs(
          user1.address,
          amount,
          StakeStatus.Undelegated,
          poolId,
          StakeStatus.Delegated,
          poolId,
        );
    });

    it("should revert if implementation detached", async () => {
      const {
        stakingProxy,
        grgToken,
        grgTransferProxyAddress,
        newPoolAddress,
        user1,
      } = await setupTests();
      const amount = parseEther("100");
      await grgToken.approve(grgTransferProxyAddress, amount);
      const encodedStakeData = stakingProxy.interface.encodeFunctionData(
        "stake",
        [amount],
      );
      const encodedCreatePoolData = stakingProxy.interface.encodeFunctionData(
        "createStakingPool",
        [newPoolAddress],
      );
      const { ethers } = await network.getOrCreate();
      const stakingContract = await ethers.getContractAt(
        "StakingProxy",
        await stakingProxy.getAddress(),
      );
      await expect(
        stakingContract.batchExecute([
          encodedStakeData,
          encodedCreatePoolData,
          encodedCreatePoolData,
        ]),
      ).to.be.revertedWith("STAKING_POOL_ALREADY_EXISTS_ERROR");
      await stakingContract.addAuthorizedAddress(user1.address);
      await stakingContract.detachStakingContract();
      await expect(
        stakingContract.batchExecute([encodedStakeData, encodedCreatePoolData]),
      ).to.be.revertedWith("STAKING_ADDRESS_NULL_ERROR");
      // storage params are still valid with detached staking implementation, as read from proxy storage
      await stakingContract.assertValidStorageParams();
    });
  });
});

export enum StakeStatus {
  Undelegated,
  Delegated,
}

export class StakeInfo {
  constructor(
    public status: StakeStatus,
    public poolId: any,
  ) {}
}

export class StoredBalance {
  constructor(
    public currentEpoch: Number,
    public currentEpochBalance: Number,
    public nextEpochBalance: Number,
  ) {}
}
