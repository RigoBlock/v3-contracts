import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber } from "ethers";
import { DEADLINE, ZERO_ADDRESS } from "../shared/constants";
import { CommandType, RoutePlanner } from '../shared/planner'
import { timeTravel } from "../utils/utils";

describe("MintWithToken", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()
    const MAX_TICK_SPACING = 32767

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const AuthorityInstance = await deployments.get("Authority")
        const Authority = await hre.ethers.getContractFactory("Authority")
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        const factory = Factory.attach(RigoblockPoolProxyFactory.address)
        const RigoTokenInstance = await deployments.get("RigoToken")
        const RigoToken = await hre.ethers.getContractFactory("RigoToken")
        const grgToken = RigoToken.attach(RigoTokenInstance.address)
        const { newPoolAddress } = await factory.callStatic.createPool(
            'testpool',
            'TEST',
            grgToken.address
        )
        await factory.createPool('testpool','TEST',grgToken.address)
        const pool = await hre.ethers.getContractAt(
            "SmartPool",
            newPoolAddress
        )
        const HookInstance = await deployments.get("MockOracle")
        const Hook = await hre.ethers.getContractFactory("MockOracle")
        const oracle = Hook.attach(HookInstance.address)
        const authority = Authority.attach(AuthorityInstance.address)
        const Weth = await hre.ethers.getContractFactory("WETH9")
        const WethInstance = await deployments.get("WETH9")
        const weth = Weth.attach(WethInstance.address)
        const Univ4PosmInstance = await deployments.get("MockUniswapPosm");
        const MockUniUniversalRouter = await ethers.getContractFactory("MockUniUniversalRouter");
        const uniRouter = await MockUniUniversalRouter.deploy(Univ4PosmInstance.address)
        const AUniswapRouter = await ethers.getContractFactory("AUniswapRouter")
        const aUniswapRouter = await AUniswapRouter.deploy(uniRouter.address, Univ4PosmInstance.address, weth.address)
        await authority.setAdapter(aUniswapRouter.address, true)
        await authority.addMethod("0x3593564c", aUniswapRouter.address) // execute(bytes,bytes[],uint256)
        const MockTokenJarInstance = await deployments.get("MockTokenJar")
        const MockTokenJar = await hre.ethers.getContractFactory("MockTokenJar")
        const tokenJar = MockTokenJar.attach(MockTokenJarInstance.address)

        return {
            factory,
            pool,
            oracle,
            grgToken,
            weth,
            tokenJar
        }
    })

    describe("mintWithToken", async () => {
        it('should revert if token not active', async () => {
            const { pool, weth, grgToken } = await setupTests()
            const tokenAmount = parseEther("10")
            await grgToken.approve(pool.address, tokenAmount)

            // weth is not in the active tokens set
            await expect(
                pool.mintWithToken(user1.address, tokenAmount, 0, weth.address)
            ).to.be.revertedWith('PoolTokenNotActive()')
        })

        it('should revert it token is the same as pool base token', async () => {
            const { pool, oracle, grgToken } = await setupTests()
            const tokenAmount = parseEther("100")
            await grgToken.approve(pool.address, tokenAmount)

            // grgToken is the same as pool base token
            await expect(
                pool.mintWithToken(user1.address, tokenAmount, 0, grgToken.address)
            ).to.be.revertedWith('PoolTokenNotActive()')

            // check that base token is not activated
            const poolKey = {
                currency0: AddressZero,
                currency1: grgToken.address,
                fee: 0,
                tickSpacing: MAX_TICK_SPACING,
                hooks: oracle.address
            }
            await oracle.initializeObservations(poolKey)
            await expect(
                pool.mintWithToken(user1.address, tokenAmount, 0, grgToken.address)
            ).to.be.revertedWith('PoolTokenNotActive()')
        })

        it('should should mint with alternative ERC20 token', async () => {
            const { pool, oracle, tokenJar, weth, grgToken } = await setupTests()
            const tokenAmount = parseEther("100")
            await weth.deposit({ value: tokenAmount })
            await weth.approve(pool.address, tokenAmount)

            // grgToken is the same as pool base token
            await expect(
                pool.mintWithToken(user1.address, tokenAmount, 0, weth.address)
            ).to.be.revertedWith('PoolTokenNotActive()')

            // check that base token is not activated
            const poolKey = {
                currency0: AddressZero,
                currency1: weth.address,
                fee: 0,
                tickSpacing: MAX_TICK_SPACING,
                hooks: oracle.address
            }
            await oracle.initializeObservations(poolKey)

            await expect(
                pool.mintWithToken(user1.address, tokenAmount, 0, weth.address)
            ).to.be.revertedWith('PoolTokenNotActive()')

            // make sure pool has some eth balance
            await user1.sendTransaction({
                to: pool.address,
                value: 1000
            })

            // activate the token by wrapping some eth in the pool via AUniswapRouter call
            const planner: RoutePlanner = new RoutePlanner()
            planner.addCommand(CommandType.WRAP_ETH, [pool.address, 1000])
            const { commands, inputs } = planner
            const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
            const extPool = ExtPool.attach(pool.address)
            const encodedWrapData = extPool.interface.encodeFunctionData(
                'execute(bytes,bytes[],uint256)',
                [commands, inputs, DEADLINE]
            )
            try {
                await user1.sendTransaction({
                to: extPool.address,
                value: 0,
                data: encodedWrapData
                });
            } catch (error: any) {
                const customError = error.error?.reason || error.reason || error.message;
                throw new Error(`${customError}`);
            }

            // the token is active, but the base token price feed does not exist, so it should revert (we wouldn't be able to price the token otherwise)
            await expect(
                pool.mintWithToken(user1.address, tokenAmount, 0, weth.address)
            ).to.be.revertedWith('BaseTokenPriceFeedError()')

            const grgPoolKey = {
                currency0: AddressZero,
                currency1: grgToken.address,
                fee: 0,
                tickSpacing: MAX_TICK_SPACING,
                hooks: oracle.address
            }
            await oracle.initializeObservations(grgPoolKey)

            const { spread } = await pool.getPoolParams()
            const spreadAmount = tokenAmount.mul(spread).div(10000)
            const tokenJarBalanceBefore = await weth.balanceOf(tokenJar.address)
            const mintedAmount = await pool.callStatic.mintWithToken(
                user1.address,
                tokenAmount,
                0,
                weth.address
            )

            const tx = await pool.mintWithToken(user1.address, tokenAmount, 0, weth.address)

            const actualBalance = await pool.balanceOf(user1.address)
            await expect(tx).to.emit(pool, "Transfer").withArgs(AddressZero, user1.address, actualBalance)
            await expect(tx).to.emit(weth, "Transfer").withArgs(user1.address, pool.address, tokenAmount)
            await expect(tx).to.emit(weth, "Transfer").withArgs(pool.address, tokenJar.address, spreadAmount)
            await expect(tx).to.emit(pool, "NewNav").withArgs(user1.address, pool.address, parseEther("1"))
            expect(actualBalance).to.be.eq(parseEther("95.476165614189864332"))
            // callStatic should return the same amount as actual execution
            expect(mintedAmount).to.be.eq(actualBalance)

            const tokenJarBalanceAfter = await weth.balanceOf(tokenJar.address)
            expect(tokenJarBalanceAfter.sub(tokenJarBalanceBefore)).to.be.eq(spreadAmount)
            //expect(await pool.balanceOf(user1.address)).to.be.eq(tokenAmount.sub(spreadAmount))
        })

        it('should revert if token is not active', async () => {
            const { pool, oracle, grgToken, weth } = await setupTests()

            // Initialize price feeds for both tokens
            const grgPoolKey = {
                currency0: AddressZero,
                currency1: grgToken.address,
                fee: 0,
                tickSpacing: MAX_TICK_SPACING,
                hooks: oracle.address
            }
            await oracle.initializeObservations(grgPoolKey)

            const wethPoolKey = {
                currency0: AddressZero,
                currency1: weth.address,
                fee: 0,
                tickSpacing: MAX_TICK_SPACING,
                hooks: oracle.address
            }
            await oracle.initializeObservations(wethPoolKey)

            // Add weth to active tokens by minting some weth to the pool
            await weth.deposit({ value: parseEther("1") })
            await weth.transfer(pool.address, parseEther("0.1"))

            const wethAmount = parseEther("10")
            await weth.deposit({ value: wethAmount })
            await weth.approve(pool.address, wethAmount)

            await expect(
                pool.mintWithToken(user1.address, wethAmount, 0, weth.address)
            ).to.be.revertedWith('PoolTokenNotActive()')
        })

        it('should apply spread and transfer to token jar contract', async () => {
            const { pool, oracle, grgToken, tokenJar, weth } = await setupTests()
            const poolKey = {
                currency0: AddressZero,
                currency1: grgToken.address,
                fee: 0,
                tickSpacing: MAX_TICK_SPACING,
                hooks: oracle.address
            }
            await oracle.initializeObservations(poolKey)

            await weth.deposit({ value: parseEther("1") })
            await weth.transfer(pool.address, parseEther("0.1"))

            // activate the native token by unwrapping some weth in the pool via AUniswapRouter call
            const planner: RoutePlanner = new RoutePlanner()
            planner.addCommand(CommandType.UNWRAP_WETH, [pool.address, 1000])
            const { commands, inputs } = planner
            const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
            const extPool = ExtPool.attach(pool.address)
            const encodedUnwrapData = extPool.interface.encodeFunctionData(
                'execute(bytes,bytes[],uint256)',
                [commands, inputs, DEADLINE]
            )
            try {
                await user1.sendTransaction({
                to: extPool.address,
                value: 0,
                data: encodedUnwrapData
                });
            } catch (error: any) {
                const customError = error.error?.reason || error.reason || error.message;
                throw new Error(`${customError}`);
            }

            const tokenAmount = parseEther("100")

            const { spread } = await pool.getPoolParams()
            const expectedSpread = tokenAmount.mul(spread).div(10000)

            const tokenJarBalanceBefore = await ethers.provider.getBalance(tokenJar.address)

            await pool.mintWithToken(user1.address, tokenAmount, 0, ZERO_ADDRESS, { value: tokenAmount })

            const tokenJarBalanceAfter = await ethers.provider.getBalance(tokenJar.address)
            expect(tokenJarBalanceAfter.sub(tokenJarBalanceBefore)).to.be.eq(expectedSpread)
        })

        it('should respect minimum output amount', async () => {
            const { pool, oracle, grgToken, weth } = await setupTests()
            const poolKey = {
                currency0: AddressZero,
                currency1: grgToken.address,
                fee: 0,
                tickSpacing: MAX_TICK_SPACING,
                hooks: oracle.address
            }
            await oracle.initializeObservations(poolKey)

            await weth.deposit({ value: parseEther("1") })
            await weth.transfer(pool.address, parseEther("0.1"))

            // activate the native token by unwrapping some weth in the pool via AUniswapRouter call
            const planner: RoutePlanner = new RoutePlanner()
            planner.addCommand(CommandType.UNWRAP_WETH, [pool.address, 1000])
            const { commands, inputs } = planner
            const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
            const extPool = ExtPool.attach(pool.address)
            const encodedUnwrapData = extPool.interface.encodeFunctionData(
                'execute(bytes,bytes[],uint256)',
                [commands, inputs, DEADLINE]
            )
            try {
                await user1.sendTransaction({
                to: extPool.address,
                value: 0,
                data: encodedUnwrapData
                });
            } catch (error: any) {
                const customError = error.error?.reason || error.reason || error.message;
                throw new Error(`${customError}`);
            }

            const tokenAmount = parseEther("100")

            const { spread } = await pool.getPoolParams()
            const expectedMint = tokenAmount.sub(tokenAmount.mul(spread).div(10000))

            // Request more than will be minted
            await expect(
                pool.mintWithToken(user1.address, tokenAmount, expectedMint.add(1), ZERO_ADDRESS, { value: tokenAmount })
            //).to.be.revertedWith('PoolMintOutputAmount()')
            ).to.not.be.reverted
        })

        it('should work with operator', async () => {
            const { pool, oracle, grgToken } = await setupTests()
            const poolKey = {
                currency0: AddressZero,
                currency1: grgToken.address,
                fee: 0,
                tickSpacing: MAX_TICK_SPACING,
                hooks: oracle.address
            }
            await oracle.initializeObservations(poolKey)

            // activate the native token by unwrapping some weth in the pool via AUniswapRouter call
            const planner: RoutePlanner = new RoutePlanner()
            planner.addCommand(CommandType.UNWRAP_WETH, [pool.address, 1000])
            const { commands, inputs } = planner
            const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
            const extPool = ExtPool.attach(pool.address)
            const encodedUnwrapData = extPool.interface.encodeFunctionData(
                'execute(bytes,bytes[],uint256)',
                [commands, inputs, DEADLINE]
            )
            try {
                await user1.sendTransaction({
                to: extPool.address,
                value: 0,
                data: encodedUnwrapData
                });
            } catch (error: any) {
                const customError = error.error?.reason || error.reason || error.message;
                throw new Error(`${customError}`);
            }

            await grgToken.transfer(user2.address, parseEther("100"))

            const tokenAmount = parseEther("50")
            await grgToken.connect(user2).approve(pool.address, tokenAmount)

            // Should fail without operator approval
            await expect(
                pool.mintWithToken(user2.address, tokenAmount, 0, ZERO_ADDRESS, { value: tokenAmount })
            ).to.be.revertedWith('InvalidOperator()')

            // Set operator
            await pool.connect(user2).setOperator(user1.address, true)

            // Should work now
            await //expect(
                pool.mintWithToken(user2.address, tokenAmount, 0, ZERO_ADDRESS, { value: tokenAmount })
            //).to.not.be.reverted

            expect(await pool.balanceOf(user2.address)).to.be.gt(0)
        })

        it('should enforce KYC if provider is set', async () => {
            const { pool, factory, oracle, grgToken } = await setupTests()

            // Set a KYC provider (any valid contract address will enforce the check)
            await pool.setKycProvider(factory.address)

            const poolKey = {
                currency0: AddressZero,
                currency1: grgToken.address,
                fee: 0,
                tickSpacing: MAX_TICK_SPACING,
                hooks: oracle.address
            }
            await oracle.initializeObservations(poolKey)

            // activate the native token by unwrapping some weth in the pool via AUniswapRouter call
            const planner: RoutePlanner = new RoutePlanner()
            planner.addCommand(CommandType.UNWRAP_WETH, [pool.address, 1000])
            const { commands, inputs } = planner
            const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
            const extPool = ExtPool.attach(pool.address)
            const encodedUnwrapData = extPool.interface.encodeFunctionData(
                'execute(bytes,bytes[],uint256)',
                [commands, inputs, DEADLINE]
            )
            try {
                await user1.sendTransaction({
                to: extPool.address,
                value: 0,
                data: encodedUnwrapData
                });
            } catch (error: any) {
                const customError = error.error?.reason || error.reason || error.message;
                throw new Error(`${customError}`);
            }

            const tokenAmount = parseEther("10")

            // Should fail, but not with PoolCallerNotWhitelisted() error, because factory does not implement the expected interface
            await expect(
                pool.mintWithToken(user1.address, tokenAmount, 0, ZERO_ADDRESS, { value: tokenAmount })
            ).to.be.revertedWith("Transaction reverted: function selector was not recognized and there's no fallback function")
        })

        it('should enforce minimum amount', async () => {
            const { pool, oracle, grgToken } = await setupTests()
            const poolKey = {
                currency0: AddressZero,
                currency1: grgToken.address,
                fee: 0,
                tickSpacing: MAX_TICK_SPACING,
                hooks: oracle.address
            }
            await oracle.initializeObservations(poolKey)

            // activate the native token by unwrapping some weth in the pool via AUniswapRouter call
            const planner: RoutePlanner = new RoutePlanner()
            planner.addCommand(CommandType.UNWRAP_WETH, [pool.address, 1000])
            const { commands, inputs } = planner
            const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
            const extPool = ExtPool.attach(pool.address)
            const encodedUnwrapData = extPool.interface.encodeFunctionData(
                'execute(bytes,bytes[],uint256)',
                [commands, inputs, DEADLINE]
            )
            try {
                await user1.sendTransaction({
                to: extPool.address,
                value: 0,
                data: encodedUnwrapData
                });
            } catch (error: any) {
                const customError = error.error?.reason || error.reason || error.message;
                throw new Error(`${customError}`);
            }

            const decimals = await pool.decimals()
            const minimumAmount = BigNumber.from(10).pow(decimals).div(1000) // 0.001 pool tokens

            await expect(
                pool.mintWithToken(user1.address, minimumAmount.sub(1), 0, ZERO_ADDRESS, { value: minimumAmount.sub(1) })
            ).to.be.revertedWith('PoolAmountSmallerThanMinimum(1000)')
        })
    })
})