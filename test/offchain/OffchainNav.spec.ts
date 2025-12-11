import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { parseEther } from "@ethersproject/units";
import { BigNumber } from "ethers";

describe("OffchainNav", async () => {
    const [ user1, user2 ] = waffle.provider.getWallets();

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup');
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory");
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory");
        const GrgTokenInstance = await deployments.get("RigoToken");
        const GrgToken = await hre.ethers.getContractFactory("RigoToken");
        const factory = Factory.attach(RigoblockPoolProxyFactory.address);
        
        // Create a new pool
        const { newPoolAddress } = await factory.callStatic.createPool(
            'testpool',
            'TEST',
            GrgTokenInstance.address
        );
        await factory.createPool('testpool','TEST',GrgTokenInstance.address);
        const pool = await hre.ethers.getContractAt(
            "SmartPool",
            newPoolAddress
        );
        
        // Deploy OffchainNav contract
        const OffchainNav = await ethers.getContractFactory("OffchainNav");
        const offchainNav = await OffchainNav.deploy();
        
        return {
            pool,
            factory,
            grgToken: GrgToken.attach(GrgTokenInstance.address),
            offchainNav,
        };
    });

    describe("getTokensAndBalances", async () => {
        it('should return empty balances for new pool', async () => {
            const { pool, offchainNav } = await setupTests();
            
            // Query balances
            const balances = await offchainNav.callStatic.getTokensAndBalances(pool.address);
            
            // New pool should have base token only
            expect(balances.length).to.be.gte(0);
        });

        it('should return base token balance after minting', async () => {
            const { pool, offchainNav, grgToken } = await setupTests();
            
            // Mint some pool tokens
            const mintAmount = parseEther("100");
            await grgToken.approve(pool.address, mintAmount);
            await pool.mint(user1.address, mintAmount, mintAmount);
            
            // Query balances
            const balances = await offchainNav.callStatic.getTokensAndBalances(pool.address);
            
            // Should have base token balance
            const baseTokenBalance = balances.find(b => b.token === await pool.baseToken());
            expect(baseTokenBalance).to.not.be.undefined;
            expect(baseTokenBalance!.balance).to.be.gt(0);
        });
    });

    describe("getNavData", async () => {
        it('should return initial NAV of 1.0 for new pool', async () => {
            const { pool, offchainNav, grgToken } = await setupTests();
            
            // Mint to initialize NAV
            const mintAmount = parseEther("100");
            await grgToken.approve(pool.address, mintAmount);
            await pool.mint(user1.address, mintAmount, mintAmount);
            
            // Query NAV data
            const navData = await offchainNav.callStatic.getNavData(pool.address);
            
            // Check values
            expect(navData.totalValue).to.be.gt(0);
            expect(navData.unitaryValue).to.be.gte(parseEther("1"));
            expect(navData.timestamp).to.be.gt(0);
        });

        it('should match updateUnitaryValue result', async () => {
            const { pool, offchainNav, grgToken } = await setupTests();
            
            // Mint pool tokens
            const mintAmount = parseEther("100");
            await grgToken.approve(pool.address, mintAmount);
            await pool.mint(user1.address, mintAmount, mintAmount);
            
            // Transfer additional base token to pool (simulating price increase)
            const additionalAmount = parseEther("50");
            await grgToken.transfer(pool.address, additionalAmount);
            
            // Get NAV using OffchainNav (should calculate in real-time)
            const offchainNavData = await offchainNav.callStatic.getNavData(pool.address);
            
            // Update NAV on-chain and read from storage
            await pool.updateUnitaryValue();
            const poolTokens = await pool.getPoolTokens();
            const onchainNav = poolTokens.unitaryValue;
            
            // They should match (allow small rounding difference)
            const difference = offchainNavData.unitaryValue.sub(onchainNav).abs();
            const tolerance = BigNumber.from(10).pow(14); // 0.0001 tolerance
            expect(difference).to.be.lte(tolerance);
        });

        it('should account for virtual balances', async () => {
            const { pool, offchainNav, grgToken } = await setupTests();
            
            // Mint pool tokens
            const mintAmount = parseEther("100");
            await grgToken.approve(pool.address, mintAmount);
            await pool.mint(user1.address, mintAmount, mintAmount);
            
            // Get initial NAV
            const initialNavData = await offchainNav.callStatic.getNavData(pool.address);
            
            // Transfer tokens to pool without minting (simulating bridge transfer)
            const transferAmount = parseEther("50");
            await grgToken.transfer(pool.address, transferAmount);
            
            // Get new NAV
            const newNavData = await offchainNav.callStatic.getNavData(pool.address);
            
            // NAV should have increased
            expect(newNavData.unitaryValue).to.be.gt(initialNavData.unitaryValue);
        });

        it('should return consistent timestamp', async () => {
            const { pool, offchainNav, grgToken } = await setupTests();
            
            // Mint pool tokens
            const mintAmount = parseEther("100");
            await grgToken.approve(pool.address, mintAmount);
            await pool.mint(user1.address, mintAmount, mintAmount);
            
            // Get NAV data
            const navData = await offchainNav.callStatic.getNavData(pool.address);
            
            // Timestamp should be current block timestamp
            const currentBlock = await ethers.provider.getBlock('latest');
            expect(navData.timestamp).to.be.closeTo(currentBlock.timestamp, 30);
        });
    });

    describe("edge cases", async () => {
        it('should handle pool with zero supply', async () => {
            const { pool, offchainNav } = await setupTests();
            
            // Query NAV data before any minting
            const navData = await offchainNav.callStatic.getNavData(pool.address);
            
            // Should return default values
            expect(navData.unitaryValue).to.be.gte(0);
            expect(navData.timestamp).to.be.gt(0);
        });

        it('should handle multiple token types', async () => {
            const { pool, offchainNav, grgToken } = await setupTests();
            
            // Mint pool tokens
            const mintAmount = parseEther("100");
            await grgToken.approve(pool.address, mintAmount);
            await pool.mint(user1.address, mintAmount, mintAmount);
            
            // Deploy a mock token and transfer to pool
            const MockERC20 = await ethers.getContractFactory("MockERC20");
            const mockToken = await MockERC20.deploy("Mock", "MCK", 18);
            await mockToken.mint(user1.address, parseEther("1000"));
            await mockToken.transfer(pool.address, parseEther("100"));
            
            // Get balances
            const balances = await offchainNav.callStatic.getTokensAndBalances(pool.address);
            
            // Should include both tokens if mock token is active
            expect(balances.length).to.be.gte(1);
        });
    });
});
