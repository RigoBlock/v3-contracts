import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { timeTravel } from "../utils/utils";

describe("AStaking", async () => {
    const [ user1 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        const GrgTokenInstance = await deployments.get("RigoToken")
        const GrgToken = await hre.ethers.getContractFactory("RigoToken")
        const GrgVaultInstance = await deployments.get("GrgVault")
        const GrgVault = await hre.ethers.getContractFactory("GrgVault")
        const PopInstance = await deployments.get("ProofOfPerformance")
        const Pop = await hre.ethers.getContractFactory("ProofOfPerformance")
        const StakingProxyInstance = await deployments.get("StakingProxy")
        const Staking = await hre.ethers.getContractFactory("Staking")
        const GrgTransferProxyInstance = await deployments.get("ERC20Proxy")
        const grgTransferProxyAddress = GrgTransferProxyInstance.address
        const AuthorityInstance = await deployments.get("Authority")
        const Authority = await hre.ethers.getContractFactory("Authority")
        const AStakingInstance = await deployments.get("AStaking")
        const authority = Authority.attach(AuthorityInstance.address)
        // "a694fc3a": "stake(uint256)"
        // "4aace835": "undelegateStake(uint256)",
        // "2e17de78": "unstake(uint256)",
        // "b880660b": "withdrawDelegatorRewards()"
        await authority.addMethod("0xa694fc3a", AStakingInstance.address)
        await authority.addMethod("0x4aace835", AStakingInstance.address)
        await authority.addMethod("0x2e17de78", AStakingInstance.address)
        await authority.addMethod("0xb880660b", AStakingInstance.address)
        const factory = Factory.attach(RigoblockPoolProxyFactory.address)
        const { newPoolAddress, poolId } = await factory.callStatic.createPool(
            'testpool',
            'TEST',
            AddressZero
        )
        await factory.createPool('testpool','TEST',AddressZero)
        const stakingProxy = Staking.attach(StakingProxyInstance.address)
        const EOracle = await hre.ethers.getContractFactory("EOracle")
        const HookInstance = await deployments.get("MockOracle")
        const Hook = await hre.ethers.getContractFactory("MockOracle")
        const hook = Hook.attach(HookInstance.address)
        // GRG being ownable is a pre-condition, otherwise won't be able to use staking proxy
        const grgToken = GrgToken.attach(GrgTokenInstance.address)
        const MAX_TICK_SPACING = 32767
        const poolKey = { currency0: AddressZero, currency1: grgToken.address, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: hook.address }
        await hook.initializeObservations(poolKey)
        return {
            grgToken,
            grgVault: GrgVault.attach(GrgVaultInstance.address),
            pop: Pop.attach(PopInstance.address),
            stakingProxy,
            grgTransferProxyAddress,
            newPoolAddress,
            poolId,
            oraclePool: EOracle.attach(newPoolAddress)
        }
    });

    describe("unstake", async () => {
        it('should revert if null stake', async () => {
            const { stakingProxy, pop, grgToken, newPoolAddress } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AStaking")
            const pool = Pool.attach(newPoolAddress)
            const amount = 100
            await expect(pool.unstake(amount)).to.be.revertedWith("MOVE_STAKE_AMOUNT_HIGHER_THAN_WITHDRAWABLE_ERROR")
        })

        it('should revert if null withdrawable stake', async () => {
            const { stakingProxy, pop, grgToken, newPoolAddress } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AStaking")
            const pool = Pool.attach(newPoolAddress)
            const amount = parseEther("100")
            await grgToken.transfer(newPoolAddress, amount)
            await pool.stake(amount)
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            await expect(pool.unstake(amount)).to.be.revertedWith("MOVE_STAKE_AMOUNT_HIGHER_THAN_WITHDRAWABLE_ERROR")
        })

        it('should unstake withdrawable amount', async () => {
            const { stakingProxy, pop, grgToken, newPoolAddress } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AStaking")
            const pool = Pool.attach(newPoolAddress)
            const amount = parseEther("100")
            await grgToken.transfer(newPoolAddress, amount)
            await pool.stake(amount)
            await pool.undelegateStake(amount)
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            await expect(pool.unstake(amount.mul(2))).to.be.revertedWith("MOVE_STAKE_AMOUNT_HIGHER_THAN_WITHDRAWABLE_ERROR")
            await expect(pool.unstake(amount)).to.emit(stakingProxy, "Unstake").withArgs(newPoolAddress, amount)
        })
    })

    describe("withdraw rewards", async () => {
        it('withdraw delegator rewards', async () => {
            const { stakingProxy, pop, grgToken, newPoolAddress } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AStaking")
            const pool = Pool.attach(newPoolAddress)
            // transaction will success if null rewards
            await pool.withdrawDelegatorRewards()
            const amount = parseEther("100")
            await grgToken.transfer(newPoolAddress, amount)
            const grgPoolBalanceBeforeReward = await grgToken.balanceOf(newPoolAddress)
            await pool.stake(amount)
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            await expect(pop.creditPopRewardToStakingProxy(newPoolAddress))
                .to.be.revertedWith("STAKING_ONLY_CALLABLE_BY_POP_ERROR")
            await stakingProxy.addAuthorizedAddress(user1.address)
            await stakingProxy.addPopAddress(pop.address)
            await pop.creditPopRewardToStakingProxy(newPoolAddress)
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            const poolId = await stakingProxy.poolIdByRbPoolAccount(newPoolAddress)
            const reward = await stakingProxy.computeRewardBalanceOfDelegator(poolId, newPoolAddress)
            expect(reward).to.be.not.eq(0)
            await expect(pool.withdrawDelegatorRewards()).to.emit(grgToken, "Transfer")
                .withArgs(stakingProxy.address, newPoolAddress, reward)
            const grgPoolBalanceAfterReward = await grgToken.balanceOf(newPoolAddress)
            expect(grgPoolBalanceBeforeReward).to.be.lt(grgPoolBalanceAfterReward)
        })
    })

    describe("stake-unstake and sync tokens", async () => {
        it('should add grg to active tokens when positive stake', async () => {
            const { stakingProxy, grgToken, newPoolAddress } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AStaking")
            const pool = Pool.attach(newPoolAddress)
            const FullPool = await hre.ethers.getContractFactory("SmartPool")
            const fullPool = FullPool.attach(newPoolAddress)
            const amount = parseEther("100")
            await grgToken.transfer(newPoolAddress, amount)
            // returned active tokens are active tokens array and the base token
            expect((await fullPool.getActiveTokens()).activeTokens.length).to.be.eq(0)
            await pool.stake(amount)
            expect((await fullPool.getActiveTokens()).activeTokens.length).to.be.eq(0)
            // TODO: we can also assert that token is active before the end of the epoch
            await timeTravel({ days: 14, mine:true })
            await stakingProxy.endEpoch()
            expect((await fullPool.getActiveTokens()).activeTokens.length).to.be.eq(0)
            await fullPool.mint(user1.address, amount, 0, { value: amount })
            // first mint only initialized value in storage, need to mint again to update active tokens
            expect((await fullPool.getActiveTokens()).activeTokens.length).to.be.eq(0)
            await fullPool.mint(user1.address, amount, 0, { value: amount })
            const activeTokens = (await fullPool.getActiveTokens()).activeTokens
            expect(activeTokens.length).to.be.eq(1)
            expect(activeTokens[0]).to.be.eq(grgToken.address)
        })

        it('should not remove grg from active tokens when null stake', async () => {
            const { grgToken, newPoolAddress } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AStaking")
            const pool = Pool.attach(newPoolAddress)
            const FullPool = await hre.ethers.getContractFactory("SmartPool")
            const fullPool = FullPool.attach(newPoolAddress)
            const amount = parseEther("100")
            await grgToken.transfer(newPoolAddress, amount)
            await pool.stake(amount)
            await fullPool.mint(user1.address, amount, 0, { value: amount })
            await fullPool.mint(user1.address, amount, 0, { value: amount })
            expect((await fullPool.getActiveTokens()).activeTokens.length).to.be.eq(1)
            await pool.undelegateStake(amount)
            expect((await fullPool.getActiveTokens()).activeTokens.length).to.be.eq(1)
            await pool.unstake(amount)
            expect((await fullPool.getActiveTokens()).activeTokens.length).to.be.eq(1)
            await fullPool.updateUnitaryValue()
            expect((await fullPool.getActiveTokens()).activeTokens.length).to.be.eq(1)
            await fullPool.mint(user1.address, amount, 0, { value: amount })
            expect((await fullPool.getActiveTokens()).activeTokens.length).to.be.eq(1)
            // token is removed only with owner action, for gas optimization
            await fullPool.purgeInactiveTokensAndApps()
            // token is not removed because the token pool's balance is not null.
            expect((await fullPool.getActiveTokens()).activeTokens.length).to.be.eq(1)
            await timeTravel({ days: 30, mine:true })
            // remove base token balance, so below grg value in base token, so we can burn for token. Nav is approx 1.98019965344058
            // log ether balance to check if it is 0
            expect(await hre.ethers.provider.getBalance(fullPool.address)).to.be.eq(parseEther("300"))
            await fullPool.burn(parseEther("150"), 1)
            expect((await fullPool.getPoolTokens()).unitaryValue).to.be.eq(parseEther("1.980199653440576965"))
            await fullPool.burnForToken(parseEther("49.500041661833943559"), 1, grgToken.address)
            expect(await grgToken.balanceOf(pool.address)).to.be.eq(1)
            await fullPool.purgeInactiveTokensAndApps()
            // this time, token is removed because the token pool's balance is null or 1.
            expect((await fullPool.getActiveTokens()).activeTokens.length).to.be.eq(0)
        })

        it('should clear balances with total burn', async () => {
            const { grgToken, newPoolAddress, oraclePool } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AStaking")
            const pool = Pool.attach(newPoolAddress)
            const FullPool = await hre.ethers.getContractFactory("SmartPool")
            const fullPool = FullPool.attach(newPoolAddress)
            const amount = parseEther("100")
            await grgToken.transfer(newPoolAddress, amount)
            await pool.stake(amount)
            await fullPool.mint(user1.address, amount, 0, { value: amount })
            await fullPool.mint(user1.address, amount, 0, { value: amount })
            await pool.undelegateStake(amount)
            await pool.unstake(amount)
            await fullPool.mint(user1.address, amount, 0, { value: amount })
            // our mock oracle returns 200, so we expect the nav to be 1.980034655942303453
            expect(await oraclePool.getTwap(grgToken.address)).to.be.eq(200)
            await fullPool.updateUnitaryValue()
            expect((await fullPool.getPoolTokens()).unitaryValue).to.be.eq(parseEther("1.980199653440576965"))
            await timeTravel({ days: 30, mine:true })
            // remove base token balance, so below grg value in base token, so we can burn for token. Nav is approx 1.98019965344058
            // TODO: the following call is reflexive, i.e. not burning the full amount will result in a different nav, and the number of pool tokens
            // to clear grg token balance will be different. We will then find ourselves with a null total supply, but a positive balance in the pool.
            expect(await hre.ethers.provider.getBalance(fullPool.address)).to.be.eq(parseEther("300"))
            await fullPool.burn(parseEther("151.499875014498169326"), 1)
            expect(await hre.ethers.provider.getBalance(fullPool.address)).to.be.eq(0)
            await fullPool.burnForToken(parseEther("49.500041661833943556"), 1, grgToken.address)
            // TODO: there is a small residual amount in the pool, probably due to rounding errors
            expect(await grgToken.balanceOf(pool.address)).to.be.eq(7)
            const totalSupply = await fullPool.totalSupply()
            expect((await fullPool.getPoolTokens()).unitaryValue).to.be.eq(parseEther("1.980199653440576966"))
            expect(await fullPool.totalSupply()).to.be.eq(0)
            await expect(fullPool.burn(totalSupply, 1)).to.be.revertedWith('PoolBurnNullAmount()')
            expect(await hre.ethers.provider.getBalance(fullPool.address)).to.be.eq(0)
            // assert pool value does not change (need to mint as supply is null)
            await fullPool.mint(user1.address, amount, 0, { value: amount })
            expect((await fullPool.getPoolTokens()).unitaryValue).to.be.eq(parseEther("1.980199653440576966"))
        })
    })
})
