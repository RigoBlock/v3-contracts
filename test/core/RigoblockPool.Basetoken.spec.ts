import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber, utils } from "ethers";
import { DEADLINE } from "../shared/constants";
import { CommandType, RoutePlanner } from '../shared/planner'
import { Actions, V4Planner } from '../shared/v4Planner'
import { deployContract, timeTravel } from "../utils/utils";

describe("BaseTokenProxy", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets()
    const MAX_TICK_SPACING = 32767
    const DEFAULT_PAIR = {
        poolKey: {
        currency0: AddressZero,
        currency1: AddressZero,
        fee: 0,
        tickSpacing: MAX_TICK_SPACING,
        hooks: AddressZero,
        },
        price: BigNumber.from('1282621508889261311518273674430423'),
        tickLower: 193800,
        tickUpper: 193900,
    }

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        const GrgTokenInstance = await deployments.get("RigoToken")
        const GrgToken = await hre.ethers.getContractFactory("RigoToken")
        const factory = Factory.attach(RigoblockPoolProxyFactory.address)
        const { newPoolAddress } = await factory.callStatic.createPool(
            'testpool',
            'TEST',
            GrgTokenInstance.address
        )
        await factory.createPool('testpool','TEST',GrgTokenInstance.address)
        const pool = await hre.ethers.getContractAt(
            "SmartPool",
            newPoolAddress
        )
        const UniRouter2Instance = await deployments.get("MockUniswapRouter")
        const uniswapRouter2 = await ethers.getContractAt("MockUniswapRouter", UniRouter2Instance.address) 
        const uniswapV3NpmAddress = await uniswapRouter2.positionManager()
        const UniswapV3Npm = await hre.ethers.getContractFactory("MockUniswapNpm")
        const uniswapV3Npm = UniswapV3Npm.attach(uniswapV3NpmAddress)
        const Univ4PosmInstance = await deployments.get("MockUniswapPosm")
        const Univ4Posm = await hre.ethers.getContractFactory("MockUniswapPosm")
        const AuthorityInstance = await deployments.get("Authority")
        const Authority = await hre.ethers.getContractFactory("Authority")
        const authority = Authority.attach(AuthorityInstance.address)
        const MockUniUniversalRouter = await ethers.getContractFactory("MockUniUniversalRouter")
        const uniRouter = await MockUniUniversalRouter.deploy(uniswapV3NpmAddress, Univ4PosmInstance.address)
        const wethAddress = await uniswapV3Npm.WETH9()
        const AUniswapRouter = await ethers.getContractFactory("AUniswapRouter")
        const aUniswapRouter = await AUniswapRouter.deploy(uniRouter.address, Univ4PosmInstance.address, wethAddress)
        await authority.setAdapter(aUniswapRouter.address, true)
        // "3593564c": "execute(bytes calldata, bytes[] calldata, uint256)"
        await authority.addMethod("0x3593564c", aUniswapRouter.address)
        const Weth = await hre.ethers.getContractFactory("WETH9")
        const HookInstance = await deployments.get("MockOracle")
        const Hook = await hre.ethers.getContractFactory("MockOracle")
        return {
            pool,
            factory,
            grgToken: GrgToken.attach(GrgTokenInstance.address),
            univ4Posm: Univ4Posm.attach(Univ4PosmInstance.address),
            weth: Weth.attach(wethAddress),
            oracle: Hook.attach(HookInstance.address),
        }
    })

    describe("poolStorage", async () => {
        it('should return pool implementation immutables', async () => {
            const { pool } = await setupTests()
            const authority = await deployments.get("Authority")
            expect(await pool.authority()).to.be.eq(authority.address)
            // TODO: we should have an assertion that the version is different if implementation has changed
            //   so we are prompted to change the version in the deployment constants.
            expect(await pool.VERSION()).to.be.eq('4.0.1')
        })
    })

    describe("getPool", async () => {
        it('should return pool immutable parameters', async () => {
            const { pool, grgToken } = await setupTests()
            const poolData = await pool.getPool()
            //expect(poolData.name).to.be.eq('testpool')
            expect(poolData.symbol).to.be.eq('TEST')
            expect(poolData.decimals).to.be.eq(await grgToken.decimals())
            expect(poolData.decimals).to.be.eq(18)
            expect(poolData.owner).to.be.eq(user1.address)
            expect(poolData.baseToken).to.be.eq(grgToken.address)
            expect(await pool.name()).to.be.eq(poolData.name)
            expect(await pool.symbol()).to.be.eq(poolData.symbol)
            expect(await pool.decimals()).to.be.eq(poolData.decimals)
            expect(await pool.owner()).to.be.eq(poolData.owner)
        })
    })

    describe("getPoolParams", async () => {
        it('should return pool parameters', async () => {
            const { pool } = await setupTests()
            const poolData = await pool.getPoolParams()
            // 30 days default minimum period
            expect(poolData.minPeriod).to.be.eq(2592000)
            // 5% default spread
            expect(poolData.spread).to.be.eq(500)
            expect(poolData.transactionFee).to.be.eq(0)
            // pool operator default fee collector
            expect(poolData.feeCollector).to.be.eq(user1.address)
            expect(poolData.kycProvider).to.be.eq(AddressZero)
        })
    })

    describe("getPoolTokens", async () => {
        it('should return pool tokens struct', async () => {
            const { pool, grgToken, oracle } = await setupTests()
            let poolData = await pool.getPoolTokens()
            const decimals = await pool.decimals()
            const initialUnitaryValue = 1 * 10**decimals
            expect(poolData.unitaryValue).to.be.eq(initialUnitaryValue.toString())
            expect(poolData.totalSupply).to.be.eq(0)
            await grgToken.approve(pool.address, parseEther("20"))
            await pool.mint(user1.address, parseEther("10"), 0)
            poolData = await pool.getPoolTokens()
            expect(poolData.totalSupply).to.be.eq(parseEther("10"))
            // on second mint (or any op that requires nav calculation), the base token price feed existance is asserted
            await expect(
                pool.mint(user1.address, parseEther("10"), 0)
            ).to.be.revertedWith('BaseTokenPriceFeedError()')
            const poolKey = { currency0: AddressZero, currency1: grgToken.address, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
            await oracle.initializeObservations(poolKey)
            await pool.mint(user2.address, parseEther("10"), 0)
            poolData = await pool.getPoolTokens()
            // 5% default spread is not applied on mint
            expect(poolData.totalSupply).to.be.eq(parseEther("20"))
            await pool.updateUnitaryValue()
            poolData = await pool.getPoolTokens()
            expect(poolData.unitaryValue).to.be.eq(parseEther("1"))
        })
    })

    describe("getPoolStorage", async () => {
        it('should return pool init params', async () => {
            const { pool, grgToken } = await setupTests()
            const poolData = await pool.getPoolStorage()
            expect(poolData.poolInitParams.name).to.be.eq('testpool')
            expect(poolData.poolInitParams.symbol).to.be.eq('TEST')
            expect(poolData.poolInitParams.decimals).to.be.eq(18)
            expect(poolData.poolInitParams.owner).to.be.eq(user1.address)
            expect(poolData.poolInitParams.baseToken).to.be.eq(grgToken.address)
        })

        it('should return pool params', async () => {
            const { pool, grgToken } = await setupTests()
            const poolData = await pool.getPoolStorage()
            // 30 days default minimum period
            expect(poolData.poolVariables.minPeriod).to.be.eq(2592000)
            expect(poolData.poolVariables.spread).to.be.eq(500)
            expect(poolData.poolVariables.transactionFee).to.be.eq(0)
            expect(poolData.poolVariables.feeCollector).to.be.eq(user1.address)
            expect(poolData.poolVariables.kycProvider).to.be.eq(AddressZero)
        })

        it('should return pool tokens struct', async () => {
            // this test should always return 18 with any token but special tokens (i.e. 6 decimals tokens)
            const { pool, grgToken, oracle } = await setupTests()
            let poolData = await pool.getPoolStorage()
            expect(poolData.poolTokensInfo.unitaryValue).to.be.eq(parseEther("1"))
            expect(poolData.poolTokensInfo.totalSupply).to.be.eq(0)
            await grgToken.approve(pool.address, parseEther("10"))
            await pool.mint(user1.address, parseEther("10"), 0)
            // TODO: storage should be updated after mint, this is probably not necessary. However, this one
            // goes through nav calculations, while first mint simply stores initial value
            const poolKey = { currency0: AddressZero, currency1: grgToken.address, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
            await oracle.initializeObservations(poolKey)
            await pool.updateUnitaryValue()
            poolData = await pool.getPoolStorage()
            expect(poolData.poolTokensInfo.unitaryValue).to.be.eq(parseEther("1"))
            expect(poolData.poolTokensInfo.totalSupply).to.be.eq(parseEther("10"))

        })
    })

    describe("getUserAccount", async () => {
        it('should return UserAccount struct', async () => {
            const { pool, grgToken } = await setupTests()
            let poolData = await pool.getUserAccount(user1.address)
            expect(poolData.userBalance).to.be.eq(0)
            expect(poolData.activation).to.be.eq(0)
            await grgToken.approve(pool.address, parseEther("10"))
            const tx = await pool.mint(user1.address, parseEther("10"), 0)
            const receipt = await tx.wait()
            const block = await receipt.events[0].getBlock()
            poolData = await pool.getUserAccount(user1.address)
            expect(poolData.activation).to.be.eq(block.timestamp + 30 * 24 * 60 * 60)
            // when user is only holder, spread is not applied
            expect(poolData.userBalance).to.be.eq(parseEther("10"))
        })
    })

    describe("mint", async () => {
        it('should create new tokens with input tokens', async () => {
            const { pool, grgToken } = await setupTests()
            expect(await pool.totalSupply()).to.be.eq(0)
            expect(await grgToken.balanceOf(pool.address)).to.be.eq(0)
            const dustAmount = parseEther("0.000999")
            expect(await pool.decimals()).to.be.eq(18)
            await expect(
                pool.mint(user1.address, dustAmount, 0)
            ).to.be.revertedWith('PoolAmountSmallerThanMinumum(1000)')
            const tokenAmountIn = parseEther("1")
            await expect(
                pool.mint(user1.address, tokenAmountIn, 0)
            ).to.be.revertedWith('TokenTransferFromFailed()')
            await grgToken.approve(pool.address, tokenAmountIn)
            expect(
                await grgToken.allowance(user1.address, pool.address)
            ).to.be.eq(tokenAmountIn)
            await expect(
                pool.mint(user1.address, tokenAmountIn, tokenAmountIn)
            ).to.be.revertedWith('PoolMintOutputAmount()')
            const userTokens = await pool.callStatic.mint(user1.address, tokenAmountIn, 0)
            await expect(
                pool.mint(user1.address, tokenAmountIn, 0)
            ).to.emit(pool, "Transfer").withArgs(
                AddressZero,
                user1.address,
                userTokens
            )
            expect(await pool.totalSupply()).to.be.not.eq(0)
            let poolGrgBalance
            poolGrgBalance = await grgToken.balanceOf(pool.address)
            expect(poolGrgBalance).to.be.eq(tokenAmountIn)
            expect(await pool.balanceOf(user1.address)).to.be.eq(userTokens)
            // with 0 fees and without changing price, total supply will be equal to userbalance
            expect(userTokens).to.be.eq(await pool.totalSupply())
            // with initial price 1, user tokens are equal to grg transferred to pool
            expect(userTokens.toString()).to.be.eq(poolGrgBalance.toString())
        })
    })

    describe("burn", async () => {
        it('should burn tokens with input tokens', async () => {
            const { pool, grgToken, oracle } = await setupTests()
            const tokenAmountIn = parseEther("1")
            await grgToken.approve(pool.address, tokenAmountIn)
            const userTokens = await pool.callStatic.mint(user1.address, tokenAmountIn, 0)
            expect((await pool.getPoolParams()).minPeriod).to.be.eq(2592000)
            await pool.mint(user1.address, tokenAmountIn, 0)
            expect(await pool.totalSupply()).to.be.not.eq(0)
            expect(await pool.balanceOf(user1.address)).to.be.eq(userTokens)
            await expect(
                pool.burn(0, 0)
            ).to.be.revertedWith('PoolBurnNullAmount()')
            let userPoolBalance = await pool.balanceOf(user1.address)
            // initial price is 1, so user balance is same as tokenAmountIn as long as no spread is applied
            expect(userPoolBalance).to.be.eq(tokenAmountIn)
            await expect(
                pool.burn(BigNumber.from(tokenAmountIn).add(1), 0)
            ).to.be.revertedWith('PoolBurnNotEnough()')
            await expect(
                pool.burn(userPoolBalance, 0)
            ).to.be.revertedWith('PoolMinimumPeriodNotEnough()')
            // previous assertions result in 1 second time travel per assertion
            await timeTravel({ seconds: 2592000 - 4, mine: false })
            await expect(
                pool.burn(tokenAmountIn, BigNumber.from(tokenAmountIn).add(1))
            ).to.be.revertedWith('PoolMinimumPeriodNotEnough()')
            await timeTravel({ seconds: 1, mine: false })
            const poolKey = { currency0: AddressZero, currency1: grgToken.address, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
            await oracle.initializeObservations(poolKey)
            await expect(
                pool.burn(tokenAmountIn, BigNumber.from(tokenAmountIn).add(1))
            ).to.be.revertedWith('PoolBurnOutputAmount()')

            // when spread is applied, also requesting tokenAmountIn as minimum will revert
            await expect(
                pool.burn(tokenAmountIn, BigNumber.from(tokenAmountIn).add(1))
            ).to.be.revertedWith('PoolBurnOutputAmount()')
            const netRevenue = await pool.callStatic.burn(userPoolBalance, 0)
            // the following is true with fee set as 0
            await expect(
                pool.burn(userPoolBalance, 1)
            ).to.emit(grgToken, "Transfer").withArgs(
                pool.address,
                user1.address,
                netRevenue
            )
            const poolTotalSupply = await pool.totalSupply()
            expect(poolTotalSupply).to.be.eq(0)
            expect(await pool.balanceOf(user1.address)).to.be.eq(0)
            // as long as price is 1, tokenAmountIn should be equal to netRevenue
            expect(Number(tokenAmountIn)).to.be.eq(Number(netRevenue))
            const tokenDelta = Number(tokenAmountIn) - netRevenue
            const poolGrgBalance = await grgToken.balanceOf(pool.address)
            expect(poolGrgBalance).to.be.eq(tokenDelta.toString())
            // if fee != 0 and caller not fee recipient, supply will not be 0
            let poolData = await pool.getPoolParams()
            const spread = poolData.spread
            const markup = userPoolBalance === poolTotalSupply ? userPoolBalance.mul(spread).div(10000) : 0
            userPoolBalance -= markup
            poolData = await pool.getPoolTokens()
            const unitaryValue = poolData.unitaryValue
            const decimals = await pool.decimals()
            // we need to multiply by fraction as ts overflows otherwise
            const revenue = unitaryValue / (10**decimals) * userPoolBalance
            expect(userPoolBalance - revenue).to.be.eq(0)
            expect(Number(netRevenue)).to.be.deep.eq(revenue)
        })

        it('should apply spread if user not only holder', async () => {
            const { pool, grgToken, oracle } = await setupTests()
            await grgToken.approve(pool.address, parseEther("20"))
            await pool.mint(user1.address, parseEther("10"), 0)
            const poolKey = { currency0: AddressZero, currency1: grgToken.address, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
            await oracle.initializeObservations(poolKey)
            await pool.mint(user2.address, parseEther("5"), 0)
            // unitary value does not include spread to pool
            expect((await pool.getPoolTokens()).unitaryValue).to.be.eq(parseEther("1"))
            await timeTravel({ seconds: 2592000, mine: true })
            // spread is now included in calculations
            await expect(
                pool.burn(parseEther("1"), 0)
            )
                .to.emit(pool, "Transfer").withArgs(user1.address, AddressZero, parseEther("1"))
                // 5% spread is applied on burn
                .and.to.emit(grgToken, "Transfer").withArgs(pool.address, user1.address, parseEther("0.95"))
                // spread will only result in unitary value increase after burn
                .and.to.not.emit(pool, "NewNav")
        })
    })

    describe("burn 6-decimals pool", async () => {
        it('should burn tokens with 6-decimal base token', async () => {
            const { pool, factory, oracle } = await setupTests()
            const source = `
            contract USDC {
                uint256 public totalSupply = 1e16;
                uint8 public decimals = 6;
                mapping(address => uint256) balances;
                function init() public { balances[msg.sender] = totalSupply; }
                function transfer(address to,uint amount) public { transferFrom(msg.sender,to,amount); }
                function transferFrom(address from,address to,uint256 amount) public {
                    balances[to] += amount; balances[from] -= amount;
                }
                function balanceOf(address _who) external view returns (uint256) {
                    return balances[_who];
                }
            }`
            const usdc = await deployContract(user1, source)
            await usdc.init()
            const newPool = await factory.callStatic.createPool('USDC pool','USDP',usdc.address)
            await factory.createPool('USDC pool','USDP',usdc.address)
            const poolUsdc = pool.attach(newPool.newPoolAddress)
            expect(await poolUsdc.decimals()).to.be.eq(6)
            await usdc.transfer(user2.address, 2000000)
            // first mint will store initial value in storage
            await expect(
                poolUsdc.connect(user2).mint(user2.address, 100000, 1)
            )
                .to.emit(poolUsdc, "Transfer")
                .and.to.emit(poolUsdc, "NewNav").withArgs(
                    user2.address,
                    poolUsdc.address, 
                    10**6 // this is true as long as pool as initial price 1
                )
            // second mint will calculate new value and store it in storage only if different
            const poolKey = { currency0: AddressZero, currency1: usdc.address, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
            await oracle.initializeObservations(poolKey)
            await expect(
                poolUsdc.connect(user2).mint(user2.address, 100000, 0)
            )
                .to.emit(poolUsdc, "Transfer")
                    .withArgs(
                        AddressZero,
                        user2.address,
                        100000
                    )
                .and.to.not.emit(poolUsdc, "NewNav")
            await expect(
                poolUsdc.connect(user2).mint(user2.address, 999, 0)
            ).to.be.revertedWith('PoolAmountSmallerThanMinumum(1000)')
            // TODO: verify setting minimum period to 2 will set to 10?
            await timeTravel({ seconds: 2592000, mine: true })
            const burnAmount = 6000
            await expect(
                poolUsdc.connect(user2).burn(burnAmount, 1)
            )
                .to.emit(poolUsdc, "Transfer")
                    .withArgs(user2.address, AddressZero, burnAmount)
                .and.to.not.emit(poolUsdc, "NewNav")
        })
    })

    describe("initializePool", async () => {
        it('should revert when already initialized', async () => {
            const { pool } = await setupTests()
            let symbol = utils.formatBytes32String("TEST")
            symbol = utils.hexDataSlice(symbol, 0, 8)
            await expect(pool.initializePool())
                .to.be.revertedWith('PoolAlreadyInitialized()')
        })
    })

    describe("burnForToken", async () => {
        it('should revert when token is not active', async () => {
            const { pool, grgToken } = await setupTests()
            await grgToken.approve(pool.address, parseEther("10"))
            await pool.mint(user1.address, parseEther("10"), 0)
            await expect(
                pool.burnForToken(parseEther("10"), 0, AddressZero)
            ).to.be.revertedWith('PoolTokenNotActive()')
        })

        it('should burn if token is active and base token balance small enough', async () => {
            const { pool, grgToken, oracle } = await setupTests()
            await grgToken.approve(pool.address, parseEther("20"))
            await pool.mint(user1.address, parseEther("10"), 0)
            // re-deploy weth, as otherwise transaction won't revert (weth is converted 1-1 to ETH)
            const Weth = await hre.ethers.getContractFactory("WETH9")
            const weth = await Weth.deploy()

            // nav calculations will sync uni v4 positions, but require if a token does not have a price feed, the liquidity amount will be 0
            await expect(
                pool.mint(user1.address, parseEther("10"), 0)
            ).to.be.revertedWith(`BaseTokenPriceFeedError()`)
            let poolKey = { currency0: AddressZero, currency1: grgToken.address, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
            await oracle.initializeObservations(poolKey)
            // as the new token does not have a price feed, the token is not activated by minting
            await pool.mint(user1.address, parseEther("10"), 0)
            await expect(pool.burnForToken(0, 0, weth.address)).to.be.revertedWith('PoolTokenNotActive()')

            // using a supported app is the only way to activate a token
            const PAIR = DEFAULT_PAIR
            PAIR.poolKey = { currency0: AddressZero, currency1: weth.address, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
            const v4Planner: V4Planner = new V4Planner()
            v4Planner.addAction(Actions.TAKE, [PAIR.poolKey.currency1, pool.address, parseEther("12")])
            const planner: RoutePlanner = new RoutePlanner()
            planner.addCommand(CommandType.V4_SWAP, [v4Planner.actions, v4Planner.params])
            const { commands, inputs } = planner
            const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
            const extPool = ExtPool.attach(pool.address)
            const encodedSwapData = extPool.interface.encodeFunctionData(
                'execute(bytes,bytes[],uint256)',
                [commands, inputs, DEADLINE]
            )
            await expect(
                user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
            ).to.be.revertedWith('TokenPriceFeedDoesNotExist')
            poolKey = { currency0: AddressZero, currency1: weth.address, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
            await oracle.initializeObservations(poolKey)
            // this call will activate the token
            await user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
            await expect(pool.burnForToken(0, 0, weth.address)).to.be.revertedWith('PoolBurnNullAmount()')
            await expect(pool.burnForToken(parseEther("1"), 0, weth.address)).to.be.revertedWith('PoolMinimumPeriodNotEnough()')
            await timeTravel({ seconds: 2592000, mine: true })
            await expect(pool.burnForToken(parseEther("1"), 0, weth.address)).to.be.revertedWith('BaseTokenBalance()')
            // need to deposit a bigger amount, as otherwise won't be able to reproduce case where target token is transferred
            await weth.deposit({ value: parseEther("100") })
            await weth.transfer(pool.address, parseEther("100"))
            // Notice: if weth amount is smaller, the amounts will need to be adjusted
            // pool has enough tokens to pay with base token
            // update and verify the pool unitary value before the burn
            await pool.updateUnitaryValue()
            const { unitaryValue } = await pool.getPoolTokens()
            expect(unitaryValue).to.be.eq(parseEther("6"))
            // as nav is higher (transferred 100 weth), the pool will not have enough base token to pay
            await expect(pool.burnForToken(parseEther("16.7"), 0, weth.address)).to.be.revertedWith('TokenTransferFailed()')
            await expect(
                pool.burnForToken(parseEther("16.5"), 0, weth.address)
            )
                .to.emit(pool, "Transfer").withArgs(
                    user1.address,
                    AddressZero,
                    parseEther("16.5")
                )
                .and.to.emit(weth, "Transfer").withArgs(
                    pool.address,
                    user1.address,
                    parseEther("99")
                )
                .and.to.not.emit(grgToken, "Transfer")
        })

        it('should burn if ETH is input token', async () => {
            const { pool, grgToken, weth, oracle } = await setupTests()
            await grgToken.approve(pool.address, parseEther("20"))
            await pool.mint(user1.address, parseEther("10"), 0)
            await expect(pool.burnForToken(0, 0, AddressZero)).to.be.revertedWith('PoolTokenNotActive()')
            const v4Planner: V4Planner = new V4Planner()
            v4Planner.addAction(Actions.TAKE, [AddressZero, pool.address, parseEther("12")])
            const planner: RoutePlanner = new RoutePlanner()
            planner.addCommand(CommandType.V4_SWAP, [v4Planner.actions, v4Planner.params])
            const { commands, inputs } = planner
            const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
            const extPool = ExtPool.attach(pool.address)
            const encodedSwapData = extPool.interface.encodeFunctionData(
                'execute(bytes,bytes[],uint256)',
                [commands, inputs, DEADLINE]
            )

            // this call will activate the token
            await user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
            // verify native token has been activated
            const activeTokens = (await pool.getActiveTokens()).activeTokens
            expect(activeTokens[0]).to.be.eq(AddressZero)
            expect(activeTokens.length).to.be.eq(1)
            await expect(pool.burnForToken(0, 0, AddressZero)).to.be.revertedWith('PoolBurnNullAmount()')
            await expect(pool.burnForToken(parseEther("1"), 0, AddressZero)).to.be.revertedWith('PoolMinimumPeriodNotEnough()')
            await timeTravel({ seconds: 2592000, mine: true })
            await expect(pool.burnForToken(parseEther("1"), 0, AddressZero)).to.be.revertedWith('BaseTokenPriceFeedError()')
            const poolKey = { currency0: AddressZero, currency1: grgToken.address, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
            await oracle.initializeObservations(poolKey)
            await expect(pool.burnForToken(parseEther("1"), 0, AddressZero)).to.be.revertedWith('BaseTokenBalance()')
            await user1.sendTransaction({ to: pool.address, value: parseEther("98")})
            await pool.updateUnitaryValue()
            const { unitaryValue } = await pool.getPoolTokens()
            expect(unitaryValue).to.be.eq(parseEther("10.997963134960554552"))
            await expect(pool.burnForToken(parseEther("0.08"), 0, AddressZero)).to.be.revertedWith('BaseTokenBalance()')
            await expect(pool.burnForToken(parseEther("9.1"), 0, AddressZero)).to.be.revertedWith('NativeTransferFailed()')
            await expect(
                pool.burnForToken(parseEther("9"), 0, AddressZero)
            )
                .to.emit(pool, "Transfer").withArgs(
                    user1.address,
                    AddressZero,
                    parseEther("9")
                )
                .and.to.not.emit(grgToken, "Transfer")
        })

        it('should apply spread if user not only holder', async () => {
            const { pool, grgToken, weth, oracle } = await setupTests()
            // need to deposit a bigger amount, as otherwise won't be able to reproduce case where target token is transferred
            await weth.deposit({ value: parseEther("100") })
            await weth.transfer(pool.address, parseEther("100"))
            await grgToken.approve(pool.address, parseEther("20"))
            await pool.mint(user1.address, parseEther("10"), 0)
            // we only need to create price feed for grg, as weth is converted 1-1 to eth
            const poolKey = { currency0: AddressZero, currency1: grgToken.address, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
            await oracle.initializeObservations(poolKey)
            // activate token via app
            const v4Planner: V4Planner = new V4Planner()
            v4Planner.addAction(Actions.TAKE, [weth.address, pool.address, parseEther("12")])
            const planner: RoutePlanner = new RoutePlanner()
            planner.addCommand(CommandType.V4_SWAP, [v4Planner.actions, v4Planner.params])
            const { commands, inputs } = planner
            const ExtPool = await hre.ethers.getContractFactory("AUniswapRouter")
            const extPool = ExtPool.attach(pool.address)
            const encodedSwapData = extPool.interface.encodeFunctionData(
                'execute(bytes,bytes[],uint256)',
                [commands, inputs, DEADLINE]
            )

            // this call will activate the token
            await user1.sendTransaction({ to: extPool.address, value: 0, data: encodedSwapData})
            // minting again to activate token via nav calculations
            await pool.mint(user2.address, parseEther("5"), 0)
            // unitary value does not include spread to pool, but includes weth balance
            const { unitaryValue } = await pool.getPoolTokens()
            expect(unitaryValue).to.be.eq(parseEther("11.151123033319578267"))
            await timeTravel({ seconds: 2592000, mine: true })
            await expect(
                pool.burnForToken(parseEther("9"), 0, weth.address)
            )
                .to.emit(pool, "Transfer").withArgs(user1.address, AddressZero, parseEther("9"))
                // TODO: verify why we have a difference in nav (possibly due to rounding, or twap adjusting by block)
                .and.to.emit(pool, "NewNav").withArgs(user1.address, pool.address, parseEther("11.199819711327277833"))
                .and.to.emit(weth, "Transfer").withArgs(pool.address, user1.address, parseEther("93.862407866921491138"))
                .and.to.not.emit(grgToken, "Transfer")
        })
    })
})
