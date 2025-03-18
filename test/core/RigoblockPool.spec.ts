import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber, Contract, utils } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { deployContract, timeTravel } from "../utils/utils";
import { getAddress } from "ethers/lib/utils";
import { time } from "console";

describe("Proxy", async () => {
    const [ user1, user2, user3 ] = waffle.provider.getWallets()
    const MAX_TICK_SPACING = 32767

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const AuthorityInstance = await deployments.get("Authority")
        const Authority = await hre.ethers.getContractFactory("Authority")
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        const factory = Factory.attach(RigoblockPoolProxyFactory.address)
        const UniRouter2Instance = await deployments.get("MockUniswapRouter");
        const uniswapRouter2 = await ethers.getContractAt("MockUniswapRouter", UniRouter2Instance.address) 
        const uniswapV3NpmAddress = await uniswapRouter2.positionManager()
        const UniswapV3Npm = await hre.ethers.getContractFactory("MockUniswapNpm")
        const UniswapV4PosmInstance = await deployments.get("MockUniswapPosm")
        const UniswapV4Posm = await hre.ethers.getContractFactory("MockUniswapPosm")
        const { newPoolAddress } = await factory.callStatic.createPool(
            'testpool',
            'TEST',
            AddressZero
        )
        await factory.createPool('testpool','TEST',AddressZero)
        const pool = await hre.ethers.getContractAt(
            "SmartPool",
            newPoolAddress
        )
        const HookInstance = await deployments.get("MockOracle")
        const Hook = await hre.ethers.getContractFactory("MockOracle")
        return {
            authority: Authority.attach(AuthorityInstance.address),
            factory,
            pool,
            uniswapV3Npm: UniswapV3Npm.attach(uniswapV3NpmAddress),
            uniswapV4Posm: UniswapV4Posm.attach(UniswapV4PosmInstance.address),
            oracle: Hook.attach(HookInstance.address),
        }
    });

    describe("receive", async () => {
        it('should revert if direct call to implementation', async () => {
            const { factory } = await setupTests()
            const etherAmount = parseEther("5")
            const implementation = await factory.implementation()
            await expect(
                user1.sendTransaction({ to: implementation, value: etherAmount})
            ).to.be.revertedWith('PoolImplementationDirectCallNotAllowed()')
        })

        it('should receive ether', async () => {
            const { pool } = await setupTests()
            const etherAmount = parseEther("5")
            await user1.sendTransaction({ to: pool.address, value: etherAmount})
            expect(await hre.ethers.provider.getBalance(pool.address)).to.be.deep.eq(etherAmount)
        })
    })

    describe("poolStorage", async () => {
        it('should return pool name from new pool', async () => {
            const { pool } = await setupTests()
            const poolData = await pool.getPool()
            expect(poolData.name).to.be.eq('testpool')
        })

        it('should return pool owner', async () => {
            const { pool } = await setupTests()
            expect(await pool.owner()).to.be.eq(user1.address)
        })
    })

    describe("setTransactionFee", async () => {
        it('should set the transaction fee', async () => {
            const { pool } = await setupTests()
            await pool.setTransactionFee(2)
            const poolData = await pool.getPoolParams()
            expect(poolData.transactionFee).to.be.eq(2)
        })

        it('should not set fee if caller not owner', async () => {
            const { pool } = await setupTests()
            await pool.setOwner(user2.address)
            await expect(pool.setTransactionFee(2)
          ).to.be.revertedWith('PoolCallerIsNotOwner()')
        })

        it('should not set fee higher than 1 percent', async () => {
            const { pool } = await setupTests()
            await expect(
              pool.setTransactionFee(101) // 100 / 10000 = 1%
            ).to.be.revertedWith('PoolFeeBiggerThanMax(100)')
        })
    })

    describe("setOwner", async () => {
        it('should revert if caller not owner', async () => {
            const { pool } = await setupTests()
            await expect(pool.connect(user2).setOwner(user2.address))
                .to.be.revertedWith('PoolCallerIsNotOwner()')
        })

        it('should revert if new owner null address', async () => {
            const { pool } = await setupTests()
            await expect(pool.setOwner(AddressZero))
                .to.be.revertedWith('PoolNullOwnerInput()')
        })

        it('should set owner', async () => {
            const { pool } = await setupTests()
            const owner = await pool.owner()
            expect(owner).to.be.eq(user1.address)
            const newOwner = user2.address
            await expect(pool.setOwner(newOwner))
                .to.emit(pool, "NewOwner").withArgs(owner, newOwner)
        })
    })

    describe("mint", async () => {
        it('should create new tokens', async () => {
            const { pool } = await setupTests()
            expect(await pool.totalSupply()).to.be.eq(0)
            const etherAmount = parseEther("1")
            const amount = await pool.callStatic.mint(
                  user1.address,
                  etherAmount,
                  0,
                  { value: etherAmount }
            )
            await expect(
                pool.mint(user1.address, parseEther("2"), 0, { value: etherAmount })
            ).to.be.revertedWith('PoolMintAmountIn()')
            await expect(
                pool.mint(user1.address, etherAmount, 0, { value: etherAmount })
            ).to.emit(pool, "Transfer").withArgs(
                AddressZero,
                user1.address,
                amount
            )
            expect(await pool.totalSupply()).to.be.not.eq(0)
            expect(await pool.balanceOf(user1.address)).to.be.eq(amount)
            const poolData = await pool.getPoolParams()
            const netAmount = amount
            expect(netAmount.toString()).to.be.eq(etherAmount.toString())
        })

        it('should revert with invalid recipient', async () => {
            const { pool } = await setupTests()
            const etherAmount = parseEther("0.00012")
            await expect(pool.mint(AddressZero, etherAmount, 0, { value: etherAmount })
            ).to.be.revertedWith('PoolMintInvalidRecipient()')
        })

        it('should revert with order below minimum', async () => {
            const { pool } = await setupTests()
            const etherAmount = parseEther("0.00012")
            await expect(pool.mint(user1.address, etherAmount, 0, { value: etherAmount })
            ).to.be.revertedWith('PoolAmountSmallerThanMinumum(1000)')
        })

        it('should revert if user not whitelisted when whitelist enabled', async () => {
            const { pool } = await setupTests()
            const etherAmount = parseEther("1")
            const source = `
            contract Kyc {
                mapping(address => bool) whitelisted;
                function whitelistUser(address user) public { whitelisted[user] = true; }
                function isWhitelistedUser(address user) public view returns (bool) { return whitelisted[user] == true; }
            }`
            const kyc = await deployContract(user1, source)
            await pool.setKycProvider(kyc.address)
            const recipient = user1.address
            // TODO: verify we are reverting when recipient is not whitelisted, vs when caller is not whitelisted
            await expect(
                pool.mint(recipient, etherAmount, 0, { value: etherAmount })
            ).to.be.revertedWith('PoolCallerNotWhitelisted()')
            await kyc.whitelistUser(recipient)
            const mintedAmount = await pool.callStatic.mint(recipient, etherAmount, 0, { value: etherAmount })
            await expect(
                pool.mint(recipient, etherAmount, 0, { value: etherAmount })
            ).to.emit(pool, "Transfer").withArgs(AddressZero, recipient, mintedAmount)
        })

        it('should allocate fee tokens to fee recipient', async () => {
            const { pool } = await setupTests()
            const etherAmount = parseEther("1")
            const transactionFee = 50
            await pool.setTransactionFee(transactionFee)
            let feeCollector = (await pool.getPoolParams()).feeCollector
            expect(await pool.owner()).to.be.eq(feeCollector)
            // when fee collector is mint recipient, fee collector receives full amount
            let mintedAmount = await pool.callStatic.mint(user1.address, etherAmount, 0, { value: etherAmount })
            await expect(
                pool.mint(user1.address, etherAmount, 0, { value: etherAmount })
            ).to.emit(pool, "Transfer").withArgs(AddressZero, feeCollector, mintedAmount)
            // when fee collector not same as recipient, fee gets allocated to fee recipient
            let fee = mintedAmount.div(10000).mul(transactionFee)
            mintedAmount = await pool.callStatic.mint(user2.address, etherAmount, 0, { value: etherAmount })
            // minted amount changes as second holder is charged the spread
            fee = mintedAmount.div(10000).mul(transactionFee)
            // TODO: verify why we cannot get the correct log arguments
            await expect(
                pool.mint(user2.address, etherAmount, 0, { value: etherAmount })
            )
                .to.emit(pool, "Transfer") //.withArgs(AddressZero, feeCollector, fee)
                //.and.to.emit(pool, "Transfer").withArgs(AddressZero, user2.address, mintedAmount)
            await pool.changeFeeCollector(user3.address)
            feeCollector = (await pool.getPoolParams()).feeCollector
            expect(feeCollector).to.be.eq(user3.address)
            // this time, user1 is charged the spread, which will be same as user2's minted amount spread
            await pool.mint(user1.address, etherAmount, 0, { value: etherAmount })
            // TODO: verify why we have a ≃ 1.2% difference in the following comparison
            //expect(await pool.balanceOf(user3.address)).to.be.eq(fee)
        })

        it('should read from storage with previously burnt supply', async () => {
            const { pool } = await setupTests()
            let etherAmount = parseEther("0.1")
            // we forward some ether to the pool, so we can test edge case where nav would be affected
            await user1.sendTransaction({ to: pool.address, value: parseEther("0.4")})
            expect((await pool.getPoolTokens()).unitaryValue).to.be.eq(parseEther("1"))
            await pool.mint(user1.address, etherAmount, 0, { value: etherAmount })
            expect(await pool.totalSupply()).to.be.eq(etherAmount)
            expect((await pool.getPoolTokens()).unitaryValue).to.be.eq(parseEther("1"))
            let ethBalance = await hre.ethers.provider.getBalance(pool.address)
            expect(ethBalance).to.be.eq(parseEther("0.5"))
            await timeTravel({ seconds: 2592000, mine: true })
            // initially minted pool tokens are same as ether amount
            await pool.burn(etherAmount, 1)
            ethBalance = await hre.ethers.provider.getBalance(pool.address)
            expect(ethBalance).to.be.eq(0)
            expect(await pool.totalSupply()).to.be.eq(0)
            expect((await pool.getPoolTokens()).unitaryValue).to.be.eq(parseEther("5"))
            await pool.mint(user1.address, etherAmount, 0, { value: etherAmount })
            ethBalance = await hre.ethers.provider.getBalance(pool.address)
            expect(ethBalance).to.be.eq(parseEther("0.1"))
            // a higher unitary value results in a lower amount of pool tokens
            expect(await pool.totalSupply()).to.be.eq(parseEther("0.02"))
            expect((await pool.getPoolTokens()).unitaryValue).to.be.eq(parseEther("5"))
        })

        it('should include univ3npm position tokens', async () => {
            const { pool, uniswapV3Npm } = await setupTests()
            expect(await uniswapV3Npm.balanceOf(pool.address)).to.be.eq(0)
            // mint univ3 position from user1, as univ3 will add tokenId to recipient. MockUniswapNpm does not use input params
            // other than the recipient, and will return weth balance which will return 0 in oracle, as won't be able to find price feed?
            // TODO: we could use mint params in mockuniv3npm
            const mintParams = {
                token0: AddressZero,
                token1: AddressZero,
                fee: 1,
                tickLower: 1,
                tickUpper: 1,
                amount0Desired: 1,
                amount1Desired: 1,
                amount0Min: 1,
                amount1Min: 1,
                recipient: pool.address,
                deadline: 1
            }
            await uniswapV3Npm.mint(mintParams)
            expect(await uniswapV3Npm.balanceOf(pool.address)).to.be.eq(1)
            const etherAmount = parseEther("11")
            // first mint will only update storage with inintial value and not include the univ3 position tokens
            // pools from versions before v4 will already have a stored value, so will include univ3 position tokens
            await expect(
                pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
            ).to.emit(pool, "Transfer").withArgs(
                AddressZero,
                user1.address,
                etherAmount
            )
            // first mint will update storage with initial value and will use that one to calculate minted tokens
            expect(await pool.totalSupply()).to.be.eq(etherAmount)
            // TODO: could calculate the value from positions(id) and verify new nav
            // TODO: should also test with very small values returned (as previously was 1.00000000000000001)

            // updating nav will prompt going through position tokens, updating active tokens in storage, making a call to oracle extension
            await expect(
                pool.updateUnitaryValue()
            ).to.emit(pool, "NewNav").withArgs(
                user1.address,
                pool.address,
                parseEther("200.685071384723181610")
            )
            expect((await pool.getPoolTokens()).unitaryValue).to.be.deep.eq(parseEther("200.685071384723181610"))
            // second mint will use the previously stored value
            const newNav = parseEther("200.685071384723181610")
            const expectedAmount = etherAmount.mul(parseEther("1")).div(newNav)
            expect(expectedAmount).to.be.deep.eq(parseEther("0.054812248485152427"))
            await expect(
                pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
            )
                .to.emit(pool, "Transfer").withArgs(
                    AddressZero,
                    user1.address,
                    expectedAmount
                )
                .and.to.not.emit(pool, "NewNav")
            expect((await pool.getPoolTokens()).unitaryValue).to.be.deep.eq(newNav)
        })
    })

    describe("burn", async () => {
        it('should burn tokens', async () => {
            const { authority, pool } = await setupTests()
            const etherAmount = parseEther("1")
            await pool.mint(user1.address, etherAmount, 0, { value: etherAmount })
            const userPoolBalance = await pool.balanceOf(user1.address)
            // TODO: following comment requires decreasing lockup to 1 second, however minimum is now 10 seconds
            // and 2-block attacks are possible with 1-2 block lockup
            // TODO: should be able to burn after 1 second, requires 2
            await timeTravel({ seconds: 2592000, mine: true })
            expect(await hre.ethers.provider.getBalance(pool.address)).to.be.deep.eq(etherAmount)
            const preBalance = await hre.ethers.provider.getBalance(user1.address)
            const netRevenue = await pool.callStatic.burn(userPoolBalance, 1)
            const { unitaryValue } = await pool.getPoolTokens()
            expect(netRevenue).to.be.eq(BigNumber.from(userPoolBalance).mul(100).div(100).mul(unitaryValue).div(etherAmount))
            // the following is true with fee set as 0
            await expect(
                pool.burn(userPoolBalance, 1)
            ).to.emit(pool, "Transfer").withArgs(
                user1.address,
                AddressZero,
                userPoolBalance
            )
            const spreadAmount = BigNumber.from(etherAmount).sub(etherAmount.div(100).mul(100).div(100).mul(100))
            expect(await hre.ethers.provider.getBalance(pool.address)).to.be.deep.eq(spreadAmount)
            const postBalance = await hre.ethers.provider.getBalance(user1.address)
            expect(postBalance).to.be.gt(preBalance)
        })

        it('should allocate fee tokens to fee recipient', async () => {
            const { pool } = await setupTests()
            const etherAmount = parseEther("1")
            await pool.mint(user1.address, etherAmount, 0, { value: etherAmount })
            await timeTravel({ seconds: 2592000, mine: true })
            const transactionFee = 50
            await pool.setTransactionFee(transactionFee)
            let userPoolBalance = await pool.balanceOf(user1.address)
            await expect(
                pool.burn(userPoolBalance.div(2), 1)
            ).to.emit(pool, "Transfer").withArgs(user1.address, AddressZero, userPoolBalance.div(2))
            const feeCollector = user3.address
            await pool.changeFeeCollector(feeCollector)
            userPoolBalance = await pool.balanceOf(user1.address)
            const fee = userPoolBalance.div(10000).mul(transactionFee)
            const burntAmount = userPoolBalance.sub(fee)
            await expect(
                pool.burn(userPoolBalance, 1)
            )
                .to.emit(pool, "Transfer").withArgs(user1.address, feeCollector, fee)
                .and.to.emit(pool, "Transfer").withArgs(user1.address, AddressZero, burntAmount)
        })
    })

    it('should revert without enough base token balance', async () => {
        const { pool, uniswapV3Npm } = await setupTests()
        // mint univ3 position, so nav will be higher and pool won't have enough base currency
        const mintParams = {
            token0: AddressZero,
            token1: AddressZero,
            fee: 1,
            tickLower: 1,
            tickUpper: 1,
            amount0Desired: 1,
            amount1Desired: 1,
            amount0Min: 1,
            amount1Min: 1,
            recipient: pool.address,
            deadline: 1
        }
        await uniswapV3Npm.mint(mintParams)
        const etherAmount = parseEther("11")
        await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
        await timeTravel({ seconds: 2592000, mine: true })
        await expect(
            pool.burn(parseEther("1"), 1)
        ).to.be.revertedWith('NativeTransferFailed()')
    })

    describe("initializePool", async () => {
        it('should revert when already initialized', async () => {
            const { pool } = await setupTests()
            let symbol = utils.formatBytes32String("TEST")
            symbol = utils.hexDataSlice(symbol, 0, 8)
            await expect(pool.initializePool())
                .to.be.revertedWith("VM Exception while processing transaction: reverted with custom error 'PoolAlreadyInitialized()'")
        })
    })

    describe("updateUnitaryValue", async () => {
        it('should update storage when caller is any wallet', async () => {
            const { pool } = await setupTests()
            await pool.setOwner(user2.address)
            await expect(pool.updateUnitaryValue())
                .to.be.revertedWith('PoolSupplyIsNullOrDust()')
            const etherAmount = parseEther("0.1")
            expect(
                await pool.mint(user1.address, etherAmount, 0, { value: etherAmount })
            ).to.emit(pool, "NewNav").withArgs(
                user1.address,
                pool.address,
                parseEther("1")
            )
            await expect(pool.updateUnitaryValue())
                .to.not.emit(pool, "NewNav")
        })

        it('should update storage when caller is owner', async () => {
            const { pool } = await setupTests()
            await expect(pool.updateUnitaryValue())
                .to.be.revertedWith('PoolSupplyIsNullOrDust()')
            const etherAmount = parseEther("0.1")
            await expect(
                pool.mint(user1.address, etherAmount, 0, { value: etherAmount })
            ).to.emit(pool, "NewNav").withArgs(
                user1.address,
                pool.address,
                parseEther("1")
            )
            await expect(pool.updateUnitaryValue())
                .to.not.emit(pool, "NewNav")
        })

        it('should update unitary value when base token balance increases', async () => {
            const { pool } = await setupTests()
            let etherAmount = parseEther("0.1")
            await pool.mint(user1.address, etherAmount, 0, { value: etherAmount })
            etherAmount = parseEther("0.4")
            await user1.sendTransaction({ to: pool.address, value: etherAmount})
            await expect(pool.updateUnitaryValue())
                .to.emit(pool, "NewNav").withArgs(
                    user1.address,
                    pool.address,
                    parseEther("5")
                )
        })

        it('should revert with previously burnt supply', async () => {
            const { pool } = await setupTests()
            let etherAmount = parseEther("0.1")
            await pool.mint(user1.address, etherAmount, 0, { value: etherAmount })
            let ethBalance = await hre.ethers.provider.getBalance(pool.address)
            expect(ethBalance).to.be.eq(etherAmount)
            await timeTravel({ seconds: 2592000, mine: true })
            await pool.burn(etherAmount, 1)
            ethBalance = await hre.ethers.provider.getBalance(pool.address)
            expect(ethBalance).to.be.eq(0)
            await expect(pool.updateUnitaryValue()).to.be.revertedWith('PoolSupplyIsNullOrDust()')
        })
    })

    describe("setKycProvider", async () => {
        it('should revert if caller not pool owner', async () => {
            const { pool } = await setupTests()
            await expect(
                pool.connect(user2).setKycProvider(user2.address)
            ).to.be.revertedWith('PoolCallerIsNotOwner()')
        })

        it('should set pool kyc provider', async () => {
            const { pool } = await setupTests()
            expect((await pool.getPoolParams()).kycProvider).to.be.eq(AddressZero)
            await expect(pool.setKycProvider(user2.address))
                .to.be.revertedWith('PoolInputIsNotContract()')
            await expect(pool.setKycProvider(pool.address))
                .to.emit(pool, "KycProviderSet").withArgs(pool.address, pool.address)
            expect((await pool.getPoolParams()).kycProvider).to.be.eq(pool.address)
        })

        it('should allow reset kyc provider', async () => {
            const { pool } = await setupTests()
            expect((await pool.getPoolParams()).kycProvider).to.be.eq(AddressZero)
            await expect(pool.setKycProvider(AddressZero))
                .to.be.revertedWith('OwnerActionInputIsSameAsCurrent()')
        })
    })

    describe("changeFeeCollector", async () => {
        it('should revert if caller not pool owner', async () => {
            const { pool } = await setupTests()
            await expect(
                pool.connect(user2).changeFeeCollector(user2.address)
            ).to.be.revertedWith('PoolCallerIsNotOwner()')
        })

        it('should set fee collector', async () => {
            const { pool } = await setupTests()
            // default fee collector is pool owner
            expect((await pool.getPoolParams()).feeCollector).to.be.eq(await pool.owner())
            await expect(
                pool.changeFeeCollector(user2.address)
            ).to.emit(pool, "NewCollector").withArgs(user1.address, pool.address, user2.address)
            expect((await pool.getPoolParams()).feeCollector).to.be.eq(user2.address)
        })

        it('should revert if new is same as current', async () => {
            const { pool } = await setupTests()
            const currentCollector = await pool.owner()
            // first time we update storage
            await expect(
                pool.changeFeeCollector(currentCollector)
            ).to.emit(pool, "NewCollector").withArgs(user1.address, pool.address, currentCollector)
            await expect(
                pool.changeFeeCollector(currentCollector)
            ).to.be.revertedWith('OwnerActionInputIsSameAsCurrent()')
        })
    })

    describe("changeSpread", async () => {
        it('should revert if caller not pool owner', async () => {
            const { pool } = await setupTests()
            await expect(
                pool.connect(user2).changeSpread(1)
            ).to.be.revertedWith('PoolCallerIsNotOwner()')
        })

        it('should revert with rogue values', async () => {
            const { pool } = await setupTests()
            // spread must always be != 0, otherwise default value from immutable storage will be returned (i.e. initial spread)
            await expect(
                pool.changeSpread(0)
            ).to.be.revertedWith('PoolSpreadInvalid(500)')
            await expect(
                pool.changeSpread(1001)
            ).to.be.revertedWith('PoolSpreadInvalid(500)')
        })

        it('should change spread', async () => {
            const { pool } = await setupTests()
            expect((await pool.getPoolParams()).spread).to.be.eq(500)
            await expect(pool.changeSpread(100))
                .to.emit(pool, "SpreadChanged").withArgs(pool.address, 100)
            expect((await pool.getPoolParams()).spread).to.be.eq(100)
        })

        it('should revert if same as current', async () => {
            const { pool } = await setupTests()
            expect((await pool.getPoolParams()).spread).to.be.eq(500)
            // first time we update storage
            await expect(pool.changeSpread(500))
                .to.emit(pool, "SpreadChanged").withArgs(pool.address, 500)
            await expect(pool.changeSpread(500))
                .to.be.revertedWith('OwnerActionInputIsSameAsCurrent()')
        })
    })

    describe("changeMinPeriod", async () => {
        it('should revert if caller not pool owner', async () => {
            const { pool } = await setupTests()
            await expect(
                pool.connect(user2).changeMinPeriod(1)
            ).to.be.revertedWith('PoolCallerIsNotOwner()')
        })

        it('should revert with rogue values', async () => {
            const { pool } = await setupTests()
            // min lockup is 10 seconds.
            await expect(
                pool.changeMinPeriod(1)
            ).to.be.revertedWith('PoolLockupPeriodInvalid(10, 2592000)')
            // max 30 days lockup
            await expect(
                pool.changeMinPeriod(2592001)
            ).to.be.revertedWith('PoolLockupPeriodInvalid(10, 2592000)')
        })

        it('should change spread', async () => {
            const { pool } = await setupTests()
            expect((await pool.getPoolParams()).minPeriod).to.be.eq(2592000)
            const newPeriod = 2592000 - 2591990
            await expect(pool.changeMinPeriod(newPeriod))
                .to.emit(pool, "MinimumPeriodChanged").withArgs(pool.address, newPeriod)
            expect((await pool.getPoolParams()).minPeriod).to.be.eq(newPeriod)
        })

        it('will revert if spread same as current', async () => {
            const { pool } = await setupTests()
            expect((await pool.getPoolParams()).minPeriod).to.be.eq(2592000)
            let newPeriod = 2592000 - 2591990
            await expect(pool.changeMinPeriod(newPeriod))
                .to.emit(pool, "MinimumPeriodChanged").withArgs(pool.address, newPeriod)
            expect((await pool.getPoolParams()).minPeriod).to.be.eq(newPeriod)
            newPeriod = 2592000
            await expect(pool.changeMinPeriod(newPeriod))
                .to.emit(pool, "MinimumPeriodChanged").withArgs(pool.address, newPeriod)
            expect((await pool.getPoolParams()).minPeriod).to.be.eq(newPeriod)
            await expect(pool.changeMinPeriod(newPeriod))
                .to.be.revertedWith('OwnerActionInputIsSameAsCurrent()')
            expect((await pool.getPoolParams()).minPeriod).to.be.eq(newPeriod)
        })
    })

    describe("purgeInativeTokensAndApps", async () => {
        it('should revert if caller is not pool owner', async () => {
            const { pool } = await setupTests()
            await expect(
                pool.connect(user2).purgeInactiveTokensAndApps()
            ).to.be.revertedWith('PoolCallerIsNotOwner()')
        })

        it('should not revert if nothing is found', async () => {
            const { pool } = await setupTests()
            await expect(pool.purgeInactiveTokensAndApps()).to.not.be.reverted
        })

        it('should not remove an active token', async () => {
            const { pool, uniswapV3Npm, oracle } = await setupTests()
            const wethAddress = await uniswapV3Npm.WETH9()
            const mintParams = {
                token0: wethAddress,
                token1: AddressZero,
                fee: 1,
                tickLower: 1,
                tickUpper: 1,
                amount0Desired: 1,
                amount1Desired: 1,
                amount0Min: 1,
                amount1Min: 1,
                recipient: pool.address,
                deadline: 1
            }
            await uniswapV3Npm.mint(mintParams)
            const etherAmount = parseEther("12")
            await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
            // first mint does not prompt nav calculations, so lp tokens are not included in active tokens
            let activeTokens = (await pool.getActiveTokens()).activeTokens
            expect(activeTokens.length).to.be.eq(0)
            let isWethInActiveTokens = activeTokens.includes(wethAddress)
            expect(isWethInActiveTokens).to.be.false
            const poolKey = { currency0: AddressZero, currency1: wethAddress, fee: 0, tickSpacing: MAX_TICK_SPACING, hooks: oracle.address }
            await oracle.initializeObservations(poolKey)
            await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
            activeTokens = (await pool.getActiveTokens()).activeTokens
            // second mint will prompt nav calculations, so lp tokens are included in active tokens
            expect(activeTokens.length).to.be.eq(1)
            isWethInActiveTokens = activeTokens.includes(wethAddress)
            expect(isWethInActiveTokens).to.be.true
            // will execute and not remove any token
            await expect(pool.purgeInactiveTokensAndApps()).to.not.be.reverted
            activeTokens = (await pool.getActiveTokens()).activeTokens
            expect(activeTokens.length).to.be.eq(1)
        })

        it('should not remove an active applications', async () => {
            const { pool, uniswapV3Npm, uniswapV4Posm } = await setupTests()
            const wethAddress = await uniswapV3Npm.WETH9()
            // TODO: move definitions to constants file
            // must fix typechain error to import from uni shared/v4Helpers
            const MAX_UINT128 = '0xffffffffffffffffffffffffffffffff'
            const USDC_WETH = {
                poolKey: {
                  currency0: wethAddress,
                  currency1: AddressZero,
                  fee: 500,
                  tickSpacing: 10,
                  hooks: AddressZero,
                },
                price: BigNumber.from('1282621508889261311518273674430423'),
                tickLower: 193800,
                tickUpper: 193900,
            }
            // mint in v4 Posm is a mock method
            await uniswapV4Posm.mint(
                USDC_WETH.poolKey,
                USDC_WETH.tickLower,
                USDC_WETH.tickUpper,
                1, // liquidity
                MAX_UINT128,
                MAX_UINT128,
                pool.address,
                '0x' // hookData
            )
            const etherAmount = parseEther("12")
            await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
            // first mint does not prompt nav calculations, so lp tokens are not included in active tokens
            let activeTokens = (await pool.getActiveTokens()).activeTokens
            expect(activeTokens.length).to.be.eq(0)
            await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
            activeTokens = (await pool.getActiveTokens()).activeTokens
            // second mint will prompt nav calculations, so lp tokens are included in active tokens
            expect(activeTokens.length).to.be.eq(0)
            expect(await uniswapV4Posm.nextTokenId()).to.be.eq(2)
            expect(await uniswapV4Posm.balanceOf(pool.address)).to.be.eq(1)
            // will execute and not remove any token
            await expect(pool.purgeInactiveTokensAndApps()).to.not.be.reverted
            activeTokens = (await pool.getActiveTokens()).activeTokens
            expect(activeTokens.length).to.be.eq(0)
        })
    })
})
