import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber, Contract } from "ethers";
import { calculateProxyAddress, calculateProxyAddressWithCallback } from "../../src/utils/proxies";
import { encodePath, FeeAmount } from "../utils/path";
import { getAddress } from "ethers/lib/utils";

describe("AUniswap", async () => {
    const [ user1, user2, user3 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        const GrgTokenInstance = await deployments.get("RigoToken")
        const GrgToken = await hre.ethers.getContractFactory("RigoToken")
        const AuthorityInstance = await deployments.get("Authority")
        const Authority = await hre.ethers.getContractFactory("Authority")
        const authority = Authority.attach(AuthorityInstance.address)
        // we never call uniswap adapter directly, therefore do not attach to ABI
        const AUniswapInstance = await deployments.get("AUniswap")
        await authority.setAdapter(AUniswapInstance.address, true)
        // "88316456": "mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))",
        // "c391b77c": "uniswapv3Npm()",
        // "3fc8cef3": "weth()"
        // "42966c68": "burn(uint256)",
        // "fc6f7865": "collect((uint256,address,uint128,uint128))",
        // "13ead562": "createAndInitializePoolIfNecessary(address,address,uint24,uint160)",
        // "0c49ccbe": "decreaseLiquidity((uint256,uint128,uint256,uint256,uint256))",
        // "219f5d17": "increaseLiquidity((uint256,uint256,uint256,uint256,uint256,uint256))",
        // "12210e8a": "refundETH()",
        // "df2ab5bb": "sweepToken(address,uint256,address)",
        // "49404b7c": "unwrapWETH9(uint256,address)",
        // "1c58db4f": "wrapETH(uint256)"
        await authority.addMethod("0x88316456", AUniswapInstance.address)
        await authority.addMethod("0xc391b77c", AUniswapInstance.address)
        await authority.addMethod("0x3fc8cef3", AUniswapInstance.address)
        await authority.addMethod("0x42966c68", AUniswapInstance.address)
        await authority.addMethod("0xfc6f7865", AUniswapInstance.address)
        await authority.addMethod("0x13ead562", AUniswapInstance.address)
        await authority.addMethod("0x0c49ccbe", AUniswapInstance.address)
        await authority.addMethod("0x219f5d17", AUniswapInstance.address)
        await authority.addMethod("0x12210e8a", AUniswapInstance.address)
        await authority.addMethod("0xdf2ab5bb", AUniswapInstance.address)
        await authority.addMethod("0x49404b7c", AUniswapInstance.address)
        await authority.addMethod("0x1c58db4f", AUniswapInstance.address)
        const AMulticallInstance = await deployments.get("AMulticall")
        await authority.setAdapter(AMulticallInstance.address, true)
        // "ac9650d8": "multicall(bytes[])"
        await authority.addMethod("0xac9650d8", AMulticallInstance.address)
        // "5ae401dc": "multicall(uint256,bytes[])"
        await authority.addMethod("0x5ae401dc", AMulticallInstance.address)
        // "1f0464d1": "multicall(bytes32,bytes[])"
        await authority.addMethod("0x1f0464d1", AMulticallInstance.address)
        // we also need to approve method in EWhitelist so that staticcall can be performed
        const EWhitelist = await hre.ethers.getContractFactory("EWhitelist")
        const eWhitelist = await EWhitelist.deploy(authority.address)
        await authority.setAdapter(eWhitelist.address, true)
        // "ab37f486": "isWhitelistedToken(address)"
        await authority.addMethod("0xab37f486", eWhitelist.address)
        const factory = Factory.attach(RigoblockPoolProxyFactory.address)
        const { newPoolAddress } = await factory.callStatic.createPool(
            'testpool',
            'TEST',
            AddressZero
        )
        await factory.createPool('testpool','TEST',AddressZero)
        const { newPoolAddress: baseTokenPool } = await factory.callStatic.createPool(
            'grgBasedPool',
            'GRGP',
            GrgTokenInstance.address
        )
        await factory.createPool('grgBasedPool','GRGP',GrgTokenInstance.address)
        return {
            grgToken: GrgToken.attach(GrgTokenInstance.address),
            aUniswap: AUniswapInstance.address,
            authority,
            newPoolAddress,
            baseTokenPool,
            eWhitelist,
        }
    })

    describe("mint", async () => {
        it('should mint an NFT', async () => {
            const { grgToken, newPoolAddress, eWhitelist } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            const amount = parseEther("100")
            // we send both Ether and GRG to the pool
            await user1.sendTransaction({ to: newPoolAddress, value: amount})
            await grgToken.transfer(newPoolAddress, amount)
            await pool.createAndInitializePoolIfNecessary(grgToken.address, grgToken.address, 1, 1)
            // hardhat does not understand that this mint method has different selector than rigoblock pool mint, therefore we encode it.
            const encodedMintData = pool.interface.encodeFunctionData(
                'mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))',
                [{
                    token0: grgToken.address,
                    token1: grgToken.address,
                    fee: 10,
                    tickLower: 1,
                    tickUpper: 200,
                    amount0Desired: 100,
                    amount1Desired: 100,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: pool.address,
                    deadline: 1
                }]
            )
            await expect(user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedMintData}))
                .to.be.revertedWith("AUNISWAP_TOKEN_NOT_WHITELISTED_ERROR")
            await eWhitelist.whitelistToken(grgToken.address)
            await user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedMintData})
            await eWhitelist.removeToken(grgToken.address)
            // position must exist, the tokenId of the first position is 1
            await expect(
                pool.increaseLiquidity({
                    tokenId: 1,
                    amount0Desired: 100,
                    amount1Desired: 100,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: 1
                })
            ).to.be.revertedWith("AUNISWAP_TOKEN_NOT_WHITELISTED_ERROR")
            const wethAddress = await pool.weth()
            await eWhitelist.whitelistToken(wethAddress)
            // the following transaction sets approval to WETH9 in TestUniswapNpm.sol as it reads positions(tokenId) but won't revert.
            await pool.increaseLiquidity({
                tokenId: 1,
                amount0Desired: 100,
                amount1Desired: 100,
                amount0Min: 0,
                amount1Min: 0,
                deadline: 1
            })
            // will revert as position 5 does not exist
            await expect(
                pool.increaseLiquidity({
                    tokenId: 5,
                    amount0Desired: 100,
                    amount1Desired: 100,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: 1
                })
            ).to.be.reverted
            await pool.decreaseLiquidity({
                tokenId: 1,
                liquidity: 25,
                amount0Min: 0,
                amount1Min: 0,
                deadline: 1
            })
            await pool.collect({
                tokenId: 1,
                recipient: pool.address,
                amount0Max: parseEther("10000"),
                amount1Max: parseEther("10000")
            })
            // hardhat does not understand method is different from rigoblock pool burn, hence we encode it.
            //await pool.burn(1)
            const encodedBurnData = pool.interface.encodeFunctionData(
                'burn(uint256)',
                [1]
            )
            await user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedBurnData})
            await pool.wrapETH(parseEther("100"))
            await pool.wrapETH(0)
            await pool.refundETH()
        })

        it('should revert if token is EOA', async () => {
            const { grgToken, newPoolAddress } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            const amount = parseEther("100")
            // we send both Ether and GRG to the pool
            await user1.sendTransaction({ to: newPoolAddress, value: amount})
            await grgToken.transfer(newPoolAddress, amount)
            await pool.createAndInitializePoolIfNecessary(grgToken.address, user2.address, 1, 1)
            const encodedMintData = pool.interface.encodeFunctionData(
                'mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))',
                [{
                    token0: grgToken.address,
                    token1: user2.address,
                    fee: 10,
                    tickLower: 1,
                    tickUpper: 200,
                    amount0Desired: 100,
                    amount1Desired: 100,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: pool.address,
                    deadline: 1
                }]
            )
            await expect(
                user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedMintData})
            ).to.be.revertedWith("AUNISWAP_TOKEN_NOT_WHITELISTED_ERROR")
        })

        it('should allow minting and adding 1-sided liquidity', async () => {
            const { grgToken, newPoolAddress, eWhitelist } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            //const Weth = await hre.ethers.getContractFactory("WETH9")
            //const weth = await Weth.deploy()
            const wethAddress = await pool.weth()
            const amount = parseEther("100")
            // we send both Ether and GRG to the pool
            await user1.sendTransaction({ to: newPoolAddress, value: amount})
            await grgToken.transfer(newPoolAddress, amount)
            await pool.createAndInitializePoolIfNecessary(grgToken.address, wethAddress, 1, 1)
            await eWhitelist.whitelistToken(grgToken.address)
            await eWhitelist.whitelistToken(wethAddress)
            let encodedMintData = pool.interface.encodeFunctionData(
                'mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))',
                [{
                    token0: grgToken.address,
                    token1: wethAddress,
                    fee: 10,
                    tickLower: 1,
                    tickUpper: 200,
                    amount0Desired: 0,
                    amount1Desired: 100,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: pool.address,
                    deadline: 1
                }]
            )
            await user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedMintData})
            await pool.increaseLiquidity({
                tokenId: 1,
                amount0Desired: 0,
                amount1Desired: 100,
                amount0Min: 0,
                amount1Min: 0,
                deadline: 1
            })
            encodedMintData = pool.interface.encodeFunctionData(
                'mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))',
                [{
                    token0: grgToken.address,
                    token1: wethAddress,
                    fee: 10,
                    tickLower: 1,
                    tickUpper: 200,
                    amount0Desired: 100,
                    amount1Desired: 0,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: pool.address,
                    deadline: 1
                }]
            )
            await user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedMintData})
            await pool.increaseLiquidity({
                tokenId: 2,
                amount0Desired: 200,
                amount1Desired: 0,
                amount0Min: 0,
                amount1Min: 0,
                deadline: 1
            })
        })

        // TODO: do not remove this test if we remove AUniswap, or move it to AUniswapRouter (also means we can keep AUniswap for uni v3 liquidity methods)
        // TODO: assert that with null total supply nothing changes to unitary value even when app tokens are returned to EApps
        // TODO: probably this test already works with new uniswap router adapter, which uses the MockUniswapRouter
        it('should prompt eapps looping through uni position', async () => {
            const { grgToken, newPoolAddress, eWhitelist } = await setupTests()
            let Pool = await hre.ethers.getContractFactory("AUniswap")
            let pool = Pool.attach(newPoolAddress)
            const wethAddress = await pool.weth()
            const amount = parseEther("100")
            // we send both Ether and GRG to the pool
            // token transfers will prompt also GRG balances to be returned to EApps, and unitary value to increase, plus EOracle to be called
            await user1.sendTransaction({ to: newPoolAddress, value: amount})
            await grgToken.transfer(newPoolAddress, amount)
            await pool.createAndInitializePoolIfNecessary(grgToken.address, wethAddress, 1, 1)
            // this is because old uniswap adapter uses the rb token whitelist. In new uni router adapter tests, we use an oracle
            await eWhitelist.whitelistToken(grgToken.address)
            await eWhitelist.whitelistToken(wethAddress)
            let encodedMintData = pool.interface.encodeFunctionData(
                'mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))',
                [{
                    token0: grgToken.address,
                    token1: wethAddress,
                    fee: 10,
                    tickLower: 1,
                    tickUpper: 200,
                    amount0Desired: 0,
                    amount1Desired: 100,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: pool.address,
                    deadline: 1
                }]
            )
            await user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedMintData})
            Pool = await hre.ethers.getContractFactory("RigoblockV3Pool")
            pool = Pool.attach(newPoolAddress)
            // an update nav call will prompt going through position tokens, updating active tokens in storage, making a call to oracle extension
            // TODO: this will fail with null total supply
            const etherAmount = parseEther("10")
            // TODO: first mint will only update storage with inintial value, second will loop through the calculations
            await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
            // nav will be 1 here
            await pool.mint(user1.address, etherAmount, 1, { value: etherAmount })
            // nav should be 1 + positions tokens value here, as we've sent weth and grg to the pool
        })
    })

    describe("increaseLiquidity", async () => {
        it('should allow adding liquidity to non-whitelisted base token', async () => {
            const { grgToken, baseTokenPool, eWhitelist } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(baseTokenPool)
            const amount = parseEther("100")
            // we send both Ether and GRG to the pool
            await user1.sendTransaction({ to: baseTokenPool, value: amount})
            await grgToken.transfer(baseTokenPool, amount)
            const wethAddress = await pool.weth()
            await pool.createAndInitializePoolIfNecessary(grgToken.address, wethAddress, 1, 1)
            const encodedMintData = pool.interface.encodeFunctionData(
                'mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))',
                [{
                    token0: grgToken.address,
                    token1: wethAddress,
                    fee: 10,
                    tickLower: 1,
                    tickUpper: 200,
                    amount0Desired: 100,
                    amount1Desired: 100,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: pool.address,
                    deadline: 1
                }]
            )
            await expect(
                user1.sendTransaction({ to: baseTokenPool, value: 0, data: encodedMintData})
            ).to.be.revertedWith("AUNISWAP_TOKEN_NOT_WHITELISTED_ERROR")
            // only 1 token gets whitelisted, the other is the base token
            await eWhitelist.whitelistToken(wethAddress)
            await user1.sendTransaction({ to: baseTokenPool, value: 0, data: encodedMintData})
            await pool.increaseLiquidity({
                tokenId: 1,
                amount0Desired: 100,
                amount1Desired: 100,
                amount0Min: 0,
                amount1Min: 0,
                deadline: 1
            })
        })

        it('should not allow adding liquidity to non-owned position', async () => {
            const { grgToken, newPoolAddress, baseTokenPool, eWhitelist } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const etherPool = Pool.attach(newPoolAddress)
            const tokenPool = Pool.attach(baseTokenPool)
            const amount = parseEther("100")
            // we send both Ether and GRG to the token-based pool
            await user1.sendTransaction({ to: baseTokenPool, value: amount})
            await grgToken.transfer(baseTokenPool, amount)
            const wethAddress = await etherPool.weth()
            await etherPool.createAndInitializePoolIfNecessary(grgToken.address, wethAddress, 1, 1)
            await eWhitelist.whitelistToken(grgToken.address)
            await eWhitelist.whitelistToken(wethAddress)
            // first pool mints position, second adds liquidity to same position
            const encodedMintData = etherPool.interface.encodeFunctionData(
                'mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))',
                [{
                    token0: grgToken.address,
                    token1: wethAddress,
                    fee: 10,
                    tickLower: 1,
                    tickUpper: 200,
                    amount0Desired: 100,
                    amount1Desired: 100,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: etherPool.address,
                    deadline: 1
                }]
            )
            await user1.sendTransaction({ to: etherPool.address, value: 0, data: encodedMintData})
            await expect(
                tokenPool.increaseLiquidity({
                    tokenId: 1,
                    amount0Desired: 100,
                    amount1Desired: 100,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: 1
              })
            ).to.be.reverted
        })
    })

    // if we also swap in multicall we will need to whitelist target token, otherwise tx will be reverted with error
    describe("multicall", async () => {
        it('should send transaction in multicall format', async () => {
            const { grgToken, aUniswap, authority, newPoolAddress } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            const amount = parseEther("100")
            // we send both Ether and GRG to the pool
            await user1.sendTransaction({ to: newPoolAddress, value: amount})
            await grgToken.transfer(newPoolAddress, amount)
            const encodedCreateData = pool.interface.encodeFunctionData(
                'createAndInitializePoolIfNecessary',
                [grgToken.address, grgToken.address, 1, 1]
            )
            const MulticallPool = await hre.ethers.getContractFactory("AMulticall")
            const multicallPool = MulticallPool.attach(newPoolAddress)
            let encodedMulticallData = multicallPool.interface.encodeFunctionData(
                'multicall(bytes[])',
                [ [encodedCreateData] ]
            )
            await user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedMulticallData})
            // while original uniswap client sends value for ETH transactions, we wrap ETH within the pool first.
            const encodedWrapData = pool.interface.encodeFunctionData(
                'wrapETH',
                [parseEther("100")]
            )
            encodedMulticallData = multicallPool.interface.encodeFunctionData(
                'multicall(bytes[])',
                [ [encodedWrapData, encodedCreateData] ]
            )
            await user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedMulticallData})
            const encodedUnwrapData = pool.interface.encodeFunctionData(
                'unwrapWETH9(uint256,address)',
                [parseEther("70"), pool.address]
            )
            encodedMulticallData = multicallPool.interface.encodeFunctionData(
                'multicall(bytes[])',
                [ [encodedUnwrapData] ]
            )
            await user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedMulticallData})
            // will fail silently in Weth contract when not enough wrapped ETH
            await expect(user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedMulticallData}))
                .to.be.revertedWith("Transaction reverted without a reason")
            const encodedSweepData = pool.interface.encodeFunctionData(
                'sweepToken(address,uint256,address)',
                [
                    grgToken.address,
                    50,
                    pool.address
                ]
            )
            encodedMulticallData = multicallPool.interface.encodeFunctionData(
                'multicall(bytes[])',
                [ [encodedSweepData] ]
            )
            await user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedMulticallData})
            const encodedRefundData = pool.interface.encodeFunctionData(
                'refundETH'
            )
            encodedMulticallData = multicallPool.interface.encodeFunctionData(
                'multicall(bytes[])',
                [ [encodedRefundData] ]
            )
            await user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedMulticallData})
            // remove refundETH method
            await authority.removeMethod("0x12210e8a", aUniswap)
            await expect(
                user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedMulticallData})
            ).to.be.revertedWith('PoolMethodNotAllowed()')
        })

        it('should send multicall with deadline', async () => {
            const { grgToken, aUniswap, authority, newPoolAddress } = await setupTests()
            const pool = await hre.ethers.getContractAt("IRigoblockPoolExtended", newPoolAddress)
            const amount = parseEther("100")
            // we send both Ether and GRG to the pool
            await user1.sendTransaction({ to: newPoolAddress, value: amount})
            await grgToken.transfer(newPoolAddress, amount)
            const encodedCreateData = pool.interface.encodeFunctionData(
                'createAndInitializePoolIfNecessary',
                [grgToken.address, grgToken.address, 1, 1]
            )
            const encodedWrapData = pool.interface.encodeFunctionData(
                'wrapETH',
                [parseEther("100")]
            )
            const currentBlock = await ethers.provider.getBlock('latest');
            let timestamp = currentBlock.timestamp
            let encodedMulticallData = pool.interface.encodeFunctionData(
                'multicall(uint256,bytes[])',
                [ timestamp, [encodedWrapData, encodedCreateData] ]
            )
            await expect(user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedMulticallData}))
                .to.be.revertedWith("AMULTICALL_DEADLINE_PAST_ERROR")
            timestamp += 1
            encodedMulticallData = pool.interface.encodeFunctionData(
                'multicall(uint256,bytes[])',
                [ timestamp, [encodedWrapData, encodedCreateData] ]
            )
            await user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedMulticallData})
        })

        it('should send multicall with previous blockhash', async () => {
            const { grgToken, aUniswap, authority, newPoolAddress } = await setupTests()
            const pool = await hre.ethers.getContractAt("IRigoblockPoolExtended", newPoolAddress)
            const amount = parseEther("100")
            // we send both Ether and GRG to the pool
            await user1.sendTransaction({ to: newPoolAddress, value: amount})
            await grgToken.transfer(newPoolAddress, amount)
            const encodedCreateData = pool.interface.encodeFunctionData(
                'createAndInitializePoolIfNecessary',
                [grgToken.address, grgToken.address, 1, 1]
            )
            const encodedWrapData = pool.interface.encodeFunctionData(
                'wrapETH',
                [parseEther("100")]
            )
            let targetBlock = await ethers.provider.getBlock('latest')
            let blockHash = targetBlock.hash
            let encodedMulticallData = pool.interface.encodeFunctionData(
                'multicall(bytes32,bytes[])',
                [ blockHash, [encodedWrapData, encodedCreateData] ]
            )
            await user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedMulticallData})
            targetBlock = await ethers.provider.getBlock(targetBlock.number - 1)
            blockHash = targetBlock.hash
            encodedMulticallData = pool.interface.encodeFunctionData(
                'multicall(bytes32,bytes[])',
                [ blockHash, [encodedWrapData, encodedCreateData] ]
            )
            await expect(user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedMulticallData}))
                .to.be.revertedWith("AMULTICALL_BLOCKHASH_ERROR")
        })
    })

    describe("burn", async () => {
        it('should call uniswap npm', async () => {
            const { grgToken, authority, aUniswap, newPoolAddress } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            await expect(authority.addMethod("0x42966c68", aUniswap))
                .to.be.revertedWith("SELECTOR_EXISTS_ERROR")
            await pool.burn(100)
        })
    })

    // when we overwrite an input in adapter, bytes declaration must be memory, otherwise calldata if input passed to next function.
    describe("swapExactTokensForTokens", async () => {
        it('should call uniswap router', async () => {
            const { grgToken, authority, aUniswap, newPoolAddress, eWhitelist } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            await authority.addMethod("0x472b43f3", aUniswap)
            const Weth = await hre.ethers.getContractFactory("WETH9")
            const weth = await Weth.deploy()
            await expect(pool.swapExactTokensForTokens(
                100,
                100,
                [grgToken.address, weth.address],
                newPoolAddress
            )).to.be.revertedWith("AUNISWAP_TOKEN_NOT_WHITELISTED_ERROR")
            await eWhitelist.whitelistToken(weth.address)
            await expect(pool.swapExactTokensForTokens(
                100,
                100,
                [user1.address, weth.address],
                newPoolAddress
            )).to.be.revertedWith("AUNISWAP_APPROVE_TARGET_NOT_CONTRACT_ERROR")
            await pool.swapExactTokensForTokens(
                100,
                100,
                [grgToken.address, weth.address],
                newPoolAddress
            )
        })

        it('should allow swap for non-whitelisted base token', async () => {
            const { grgToken, authority, aUniswap, baseTokenPool, eWhitelist } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(baseTokenPool)
            await authority.addMethod("0x472b43f3", aUniswap)
            const Weth = await hre.ethers.getContractFactory("WETH9")
            const weth = await Weth.deploy()
            await expect(pool.swapExactTokensForTokens(
                100,
                100,
                [grgToken.address, weth.address],
                baseTokenPool
            )).to.be.revertedWith("AUNISWAP_TOKEN_NOT_WHITELISTED_ERROR")
            await eWhitelist.whitelistToken(weth.address)
            await pool.swapExactTokensForTokens(
                100,
                100,
                [grgToken.address, weth.address],
                baseTokenPool
            )
        })

        it('should allow multi-hop swap', async () => {
            const { grgToken, authority, aUniswap, newPoolAddress, eWhitelist } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            await authority.addMethod("0x472b43f3", aUniswap)
            const Weth = await hre.ethers.getContractFactory("WETH9")
            const weth = await Weth.deploy()
            await eWhitelist.whitelistToken(weth.address)
            await expect(pool.swapExactTokensForTokens(
                100,
                100,
                [grgToken.address, weth.address, newPoolAddress],
                newPoolAddress
            )).to.be.revertedWith("AUNISWAP_TOKEN_NOT_WHITELISTED_ERROR")
            await pool.swapExactTokensForTokens(
                100,
                100,
                [grgToken.address, user1.address, weth.address],
                newPoolAddress
            )
            await pool.swapExactTokensForTokens(
                100,
                100,
                [grgToken.address, user1.address, user2.address, weth.address],
                newPoolAddress
            )
        })
    })

    describe("swapTokensForExactTokens", async () => {
        it('should call uniswap router', async () => {
            const { grgToken, authority, aUniswap, newPoolAddress, eWhitelist } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            await authority.addMethod("0x42712a67", aUniswap)
            const Weth = await hre.ethers.getContractFactory("WETH9")
            const weth = await Weth.deploy()
            await expect(pool.swapTokensForExactTokens(
                100,
                100,
                [weth.address, grgToken.address],
                newPoolAddress
            )).to.be.revertedWith("AUNISWAP_TOKEN_NOT_WHITELISTED_ERROR")
            await eWhitelist.whitelistToken(grgToken.address)
            await expect(pool.swapTokensForExactTokens(
                100,
                100,
                [user1.address, grgToken.address],
                newPoolAddress
            )).to.be.revertedWith("AUNISWAP_APPROVE_TARGET_NOT_CONTRACT_ERROR")
            await pool.swapTokensForExactTokens(
                100,
                100,
                [weth.address, grgToken.address],
                newPoolAddress
            )
        })

        it('should allow multi-hop swap', async () => {
            const { grgToken, authority, aUniswap, newPoolAddress, eWhitelist } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            await authority.addMethod("0x42712a67", aUniswap)
            const Weth = await hre.ethers.getContractFactory("WETH9")
            const weth = await Weth.deploy()
            await eWhitelist.whitelistToken(grgToken.address)
            await expect(pool.swapTokensForExactTokens(
                100,
                100,
                [weth.address, grgToken.address, newPoolAddress],
                newPoolAddress
            )).to.be.revertedWith("AUNISWAP_TOKEN_NOT_WHITELISTED_ERROR")
            await pool.swapTokensForExactTokens(
                100,
                100,
                [weth.address, user1.address, grgToken.address],
                newPoolAddress
            )
            await pool.swapTokensForExactTokens(
                100,
                100,
                [weth.address, user1.address, user2.address, grgToken.address],
                newPoolAddress
            )
        })

        it('should revert with rogue path', async () => {
            const { grgToken, authority, aUniswap, newPoolAddress, eWhitelist } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            await authority.addMethod("0x42712a67", aUniswap)
            const Weth = await hre.ethers.getContractFactory("WETH9")
            const weth = await Weth.deploy()
            await eWhitelist.whitelistToken(grgToken.address)
            // array decoding will fail when checking whitelisted token
            await expect(pool.swapTokensForExactTokens(
                100,
                100,
                [],
                newPoolAddress
            )).to.be.revertedWith("reverted with panic code 0x32 (Array accessed at an out-of-bounds or negative index)")
        })
    })

    // tokenIn is the token that goes into the swap router, tokenOut is the token that is received
    describe("exactInputSingle", async () => {
        it('should call uniswap router', async () => {
            const { grgToken, authority, aUniswap, newPoolAddress, eWhitelist } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            await authority.addMethod("0x04e45aaf", aUniswap)
            const Weth = await hre.ethers.getContractFactory("WETH9")
            const weth = await Weth.deploy()
            await expect(pool.exactInputSingle({
                tokenIn: grgToken.address,
                tokenOut: weth.address,
                fee: 0,
                recipient: newPoolAddress,
                amountIn: 20,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 4
            })).to.be.revertedWith("AUNISWAP_TOKEN_NOT_WHITELISTED_ERROR")
            await eWhitelist.whitelistToken(weth.address)
            await expect(pool.exactInputSingle({
                tokenIn: user1.address,
                tokenOut: weth.address,
                fee: 0,
                recipient: newPoolAddress,
                amountIn: 20,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 4
            })).to.be.revertedWith("AUNISWAP_APPROVE_TARGET_NOT_CONTRACT_ERROR")
            await pool.exactInputSingle({
                tokenIn: grgToken.address,
                tokenOut: weth.address,
                fee: 0,
                recipient: newPoolAddress,
                amountIn: 20,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 4
            })
        })
    })

    describe("exactInput", async () => {
        it('should call uniswap router', async () => {
            const { grgToken, authority, aUniswap, newPoolAddress, eWhitelist } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            await authority.addMethod("0xb858183f", aUniswap)
            const Weth = await hre.ethers.getContractFactory("WETH9")
            const weth = await Weth.deploy()
            await expect(pool.exactInput({
                path: encodePath([weth.address, grgToken.address], [FeeAmount.MEDIUM]),
                recipient: newPoolAddress,
                amountIn: 20,
                amountOutMinimum: 1
            })).to.be.revertedWith("AUNISWAP_TOKEN_NOT_WHITELISTED_ERROR")
            await eWhitelist.whitelistToken(grgToken.address)
            await expect(pool.exactInput({
                path: encodePath([user1.address, grgToken.address], [FeeAmount.MEDIUM]),
                recipient: newPoolAddress,
                amountIn: 20,
                amountOutMinimum: 1
            })).to.be.revertedWith("AUNISWAP_APPROVE_TARGET_NOT_CONTRACT_ERROR")
            // fee amount is irrelevant as long as we test on the mock router and do not query for the actual pool
            await pool.exactInput({
                path: encodePath([weth.address, grgToken.address], [FeeAmount.MEDIUM]),
                recipient: newPoolAddress,
                amountIn: 20,
                amountOutMinimum: 1
            })
        })

        it('should pass checks with multi-hop swap', async () => {
            const { grgToken, authority, aUniswap, newPoolAddress, eWhitelist } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            await authority.addMethod("0xb858183f", aUniswap)
            const Weth = await hre.ethers.getContractFactory("WETH9")
            const weth = await Weth.deploy()
            // we can place any address between tokenIn and tokenOut as it should not affect checks
            await expect(pool.exactInput({
                path: encodePath([weth.address, user1.address, grgToken.address], [FeeAmount.MEDIUM, FeeAmount.MEDIUM]),
                recipient: newPoolAddress,
                amountIn: 20,
                amountOutMinimum: 1
            })).to.be.revertedWith("AUNISWAP_TOKEN_NOT_WHITELISTED_ERROR")
            await eWhitelist.whitelistToken(grgToken.address)
            await pool.exactInput({
                path: encodePath([weth.address, user1.address, grgToken.address], [FeeAmount.MEDIUM, FeeAmount.MEDIUM]),
                recipient: newPoolAddress,
                amountIn: 20,
                amountOutMinimum: 1
            })
            await pool.exactInput({
                path: encodePath(
                    [weth.address, user1.address, user2.address, grgToken.address],
                    [FeeAmount.MEDIUM, FeeAmount.MEDIUM, FeeAmount.MEDIUM]
                ),
                recipient: newPoolAddress,
                amountIn: 20,
                amountOutMinimum: 1
            })
            await pool.exactInput({
                path: encodePath(
                    [weth.address, user1.address, user2.address, user3.address, grgToken.address],
                    [FeeAmount.MEDIUM, FeeAmount.MEDIUM, FeeAmount.MEDIUM, FeeAmount.HIGH]
                ),
                recipient: newPoolAddress,
                amountIn: 20,
                amountOutMinimum: 1
            })
        })

        it('should revert multi-hop if tokenOut not whitelited but token1 is', async () => {
            const { grgToken, authority, aUniswap, newPoolAddress, eWhitelist } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            await authority.addMethod("0xb858183f", aUniswap)
            const Weth = await hre.ethers.getContractFactory("WETH9")
            const weth = await Weth.deploy()
            await expect(pool.exactInput({
                path: encodePath([weth.address, grgToken.address, user1.address], [FeeAmount.MEDIUM, FeeAmount.MEDIUM]),
                recipient: newPoolAddress,
                amountIn: 20,
                amountOutMinimum: 1
            })).to.be.revertedWith("AUNISWAP_TOKEN_NOT_WHITELISTED_ERROR")
            await eWhitelist.whitelistToken(grgToken.address)
            await expect(pool.exactInput({
                path: encodePath([weth.address, grgToken.address, user1.address], [FeeAmount.MEDIUM, FeeAmount.MEDIUM]),
                recipient: newPoolAddress,
                amountIn: 20,
                amountOutMinimum: 1
            })).to.be.revertedWith("AUNISWAP_TOKEN_NOT_WHITELISTED_ERROR")
            await pool.exactInput({
                path: encodePath([weth.address, user1.address, grgToken.address], [FeeAmount.MEDIUM, FeeAmount.MEDIUM]),
                recipient: newPoolAddress,
                amountIn: 20,
                amountOutMinimum: 1
            })
        })
    })

    // hardhat does not recognize methods with same name but different signature/inputs
    describe("exactOutputSingle", async () => {
        it('should call uniswap router', async () => {
            const { grgToken, authority, aUniswap, newPoolAddress, eWhitelist } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            await authority.addMethod("0x5023b4df", aUniswap)
            const Weth = await hre.ethers.getContractFactory("WETH9")
            const weth = await Weth.deploy()
            await expect(pool.exactOutputSingle({
                tokenIn: weth.address,
                tokenOut: grgToken.address,
                fee: 0,
                recipient: newPoolAddress,
                amountOut: 20,
                amountInMaximum: 1,
                sqrtPriceLimitX96: 4
            })).to.be.revertedWith("AUNISWAP_TOKEN_NOT_WHITELISTED_ERROR")
            await eWhitelist.whitelistToken(grgToken.address)
            await expect(pool.exactOutputSingle({
                tokenIn: user1.address,
                tokenOut: grgToken.address,
                fee: 0,
                recipient: newPoolAddress,
                amountOut: 20,
                amountInMaximum: 1,
                sqrtPriceLimitX96: 4
            })).to.be.revertedWith("AUNISWAP_APPROVE_TARGET_NOT_CONTRACT_ERROR")
            await pool.exactOutputSingle({
                tokenIn: weth.address,
                tokenOut: grgToken.address,
                fee: 0,
                recipient: newPoolAddress,
                amountOut: 20,
                amountInMaximum: 1,
                sqrtPriceLimitX96: 4
            })
        })
    })

    // exactOutput (multi-hop) has route inverted to exactInput, i.e. first token in path is tokenOut, last is tokenIn
    describe("exactOutput", async () => {
        it('should call uniswap router', async () => {
            const { grgToken, authority, aUniswap, newPoolAddress, eWhitelist } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            await authority.addMethod("0x09b81346", aUniswap)
            const Weth = await hre.ethers.getContractFactory("WETH9")
            const weth = await Weth.deploy()
            await expect(pool.exactOutput({
                path: encodePath([grgToken.address, weth.address], [FeeAmount.MEDIUM]),
                recipient: newPoolAddress,
                amountOut: 20,
                amountInMaximum: 10
            })).to.be.revertedWith("AUNISWAP_TOKEN_NOT_WHITELISTED_ERROR")
            await eWhitelist.whitelistToken(grgToken.address)
            await expect(pool.exactOutput({
                path: encodePath([grgToken.address, user1.address], [FeeAmount.MEDIUM]),
                recipient: newPoolAddress,
                amountOut: 20,
                amountInMaximum: 10
            })).to.be.revertedWith("AUNISWAP_APPROVE_TARGET_NOT_CONTRACT_ERROR")
            await pool.exactOutput({
                path: encodePath([grgToken.address, weth.address], [FeeAmount.MEDIUM]),
                recipient: newPoolAddress,
                amountOut: 20,
                amountInMaximum: 10
            })
        })

        it('should succeed if multi-hop token1 not whitelisted', async () => {
            const { grgToken, authority, aUniswap, newPoolAddress, eWhitelist } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            await authority.addMethod("0x09b81346", aUniswap)
            const Weth = await hre.ethers.getContractFactory("WETH9")
            const weth = await Weth.deploy()
            await expect(pool.exactOutput({
                path: encodePath([grgToken.address, user1.address, weth.address], [FeeAmount.MEDIUM, FeeAmount.MEDIUM]),
                recipient: newPoolAddress,
                amountOut: 20,
                amountInMaximum: 10
            })).to.be.revertedWith("AUNISWAP_TOKEN_NOT_WHITELISTED_ERROR")
            await eWhitelist.whitelistToken(grgToken.address)
            await pool.exactOutput({
                path: encodePath([grgToken.address, user1.address, weth.address], [FeeAmount.MEDIUM, FeeAmount.MEDIUM]),
                recipient: newPoolAddress,
                amountOut: 20,
                amountInMaximum: 10
            })
            await pool.exactOutput({
                path: encodePath(
                    [grgToken.address, user1.address, user2.address, weth.address],
                    [FeeAmount.MEDIUM, FeeAmount.MEDIUM, FeeAmount.MEDIUM]
                ),
                recipient: newPoolAddress,
                amountOut: 20,
                amountInMaximum: 10
            })
            await pool.exactOutput({
                path: encodePath(
                    [grgToken.address, user1.address, user2.address, user3.address, weth.address],
                    [FeeAmount.MEDIUM, FeeAmount.MEDIUM, FeeAmount.MEDIUM, FeeAmount.HIGH]
                ),
                recipient: newPoolAddress,
                amountOut: 20,
                amountInMaximum: 10
            })
        })

        it('should revert multi-hop if tokenOut not whitelited but token1 is', async () => {
            const { grgToken, authority, aUniswap, newPoolAddress, eWhitelist } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            await authority.addMethod("0x09b81346", aUniswap)
            const Weth = await hre.ethers.getContractFactory("WETH9")
            const weth = await Weth.deploy()
            await expect(pool.exactOutput({
                path: encodePath([grgToken.address, weth.address, user1.address], [FeeAmount.MEDIUM, FeeAmount.MEDIUM]),
                recipient: newPoolAddress,
                amountOut: 20,
                amountInMaximum: 10
            })).to.be.revertedWith("AUNISWAP_TOKEN_NOT_WHITELISTED_ERROR")
            // eWhitelist requires an address to be a contract
            await eWhitelist.whitelistToken(newPoolAddress)
            await expect(pool.exactOutput({
                path: encodePath([grgToken.address, newPoolAddress, weth.address], [FeeAmount.MEDIUM, FeeAmount.MEDIUM]),
                recipient: newPoolAddress,
                amountOut: 20,
                amountInMaximum: 10
            })).to.be.revertedWith("AUNISWAP_TOKEN_NOT_WHITELISTED_ERROR")
            await pool.exactOutput({
                path: encodePath([newPoolAddress, weth.address, grgToken.address], [FeeAmount.MEDIUM, FeeAmount.MEDIUM]),
                recipient: newPoolAddress,
                amountOut: 20,
                amountInMaximum: 10
            })
        })
    })

    describe("sweepToken", async () => {
        it('should call uniswap router', async () => {
            const { grgToken, authority, aUniswap, newPoolAddress } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            let encodedSweepData
            encodedSweepData = pool.interface.encodeFunctionData(
                'sweepToken(address,uint256,address)',
                [
                    grgToken.address,
                    50,
                    pool.address
                ]
            )
            await user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedSweepData})
            encodedSweepData = pool.interface.encodeFunctionData(
                'sweepToken(address,uint256)',
                [grgToken.address, 50]
            )
            await expect(user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedSweepData}))
                .to.be.revertedWith('PoolMethodNotAllowed()')
            await authority.addMethod("0xe90a182f", aUniswap)
            await user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedSweepData})
        })
    })

    describe("sweepTokenWithFee", async () => {
        it('should call uniswap router', async () => {
            const { grgToken, authority, aUniswap, newPoolAddress } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            let encodedSweepData
            encodedSweepData = pool.interface.encodeFunctionData(
                'sweepTokenWithFee(address,uint256,address,uint256,address)',
                [
                    grgToken.address,
                    50,
                    pool.address,
                    50,
                    grgToken.address
                ]
            )
            await authority.addMethod("0xe0e189a0", aUniswap)
            await user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedSweepData})
            encodedSweepData = pool.interface.encodeFunctionData(
                'sweepTokenWithFee(address,uint256,uint256,address)',
                [grgToken.address, 50, 50, grgToken.address]
            )
            await authority.addMethod("0x3068c554", aUniswap)
            await user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedSweepData})
        })
    })

    describe("unwrapWETH9", async () => {
        it('should call WETH contract', async () => {
            const { grgToken, authority, aUniswap, newPoolAddress } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            const amount = parseEther("100")
            await user1.sendTransaction({ to: newPoolAddress, value: amount})
            await pool.wrapETH(amount)
            expect(await hre.ethers.provider.getBalance(newPoolAddress)).to.be.eq(0)
            const rogueRecipient = user2.address
            const rogueBalance = await hre.ethers.provider.getBalance(rogueRecipient)
            let encodedUnwrapData
            const unwrapAmount = 50
            encodedUnwrapData = pool.interface.encodeFunctionData(
                'unwrapWETH9(uint256,address)',
                [unwrapAmount, rogueRecipient]
            )
            await expect(authority.addMethod("0x49404b7c", aUniswap)).to.be.revertedWith("SELECTOR_EXISTS_ERROR")
            await user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedUnwrapData})
            // unwrapped token returned to pool regardless recipient input
            expect(await hre.ethers.provider.getBalance(rogueRecipient)).to.be.eq(rogueBalance)
            expect(await hre.ethers.provider.getBalance(newPoolAddress)).to.be.eq(unwrapAmount)
            encodedUnwrapData = pool.interface.encodeFunctionData(
                'unwrapWETH9(uint256)',
                [50]
            )
            await authority.addMethod("0x49616997", aUniswap)
            await user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedUnwrapData})
        })
    })

    describe("unwrapWETH9WithFee", async () => {
        it('should call WETH contract', async () => {
            const { grgToken, authority, aUniswap, newPoolAddress } = await setupTests()
            const Pool = await hre.ethers.getContractFactory("AUniswap")
            const pool = Pool.attach(newPoolAddress)
            // following methods are marked as virtual, do not require wrapping ETH first.
            let encodedUnwrapData
            encodedUnwrapData = pool.interface.encodeFunctionData(
                'unwrapWETH9WithFee(uint256,address,uint256,address)',
                [50, newPoolAddress, 50, newPoolAddress]
            )
            await authority.addMethod("0x9b2c0a37", aUniswap)
            await user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedUnwrapData})
            encodedUnwrapData = pool.interface.encodeFunctionData(
                'unwrapWETH9WithFee(uint256,uint256,address)',
                [50, 50, newPoolAddress]
            )
            await authority.addMethod("0xd4ef38de", aUniswap)
            await user1.sendTransaction({ to: newPoolAddress, value: 0, data: encodedUnwrapData})
        })
    })
})
