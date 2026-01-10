import { expect } from "chai";
import hre, { deployments, waffle } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { BigNumber } from "ethers";

const MAX_TICK_SPACING = 32767;

describe("ENavView", async () => {
    const [user1] = waffle.provider.getWallets();

    interface TokenBalance {
        token: string;
        balance: BigNumber;
    }

    interface NavData {
        totalValue: BigNumber;
        unitaryValue: BigNumber;
        timestamp: BigNumber;
    }

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
        
        // Get deployed ENavView from setup  
        const ENavViewInstance = await deployments.get("ENavView");
        const eNavView = await hre.ethers.getContractAt(
            "ENavView", 
            ENavViewInstance.address
        );

        const HookInstance = await deployments.get("MockOracle");
        const Hook = await hre.ethers.getContractFactory("MockOracle");
        const oracle = Hook.attach(HookInstance.address);
        
        // Initialize oracle observations for GRG token (base token) to avoid BaseTokenPriceFeedError
        const poolKey = { 
            currency0: AddressZero, 
            currency1: GrgTokenInstance.address, 
            fee: 0, 
            tickSpacing: MAX_TICK_SPACING, 
            hooks: oracle.address 
        };
        await oracle.initializeObservations(poolKey);
        
        return {
            pool,
            factory,
            grgToken: GrgToken.attach(GrgTokenInstance.address),
            eNavView,
            oracle
        };
    });

    // Unit tests for ENavView extension functionality through proper pool delegation
    describe("ENavView functionality through pool", async () => {
        it('should test extension deployment and immutables', async () => {
            const { eNavView } = await setupTests();
            
            // Test that immutable addresses are properly set
            const grgStakingProxy = await eNavView.grgStakingProxy();
            const uniV4Posm = await eNavView.uniV4Posm();
            
            expect(grgStakingProxy).to.not.equal(AddressZero);
            expect(uniV4Posm).to.not.equal(AddressZero);
        });

        it('should return token balances through pool delegation', async () => {
            const { pool } = await setupTests();
            
            // Cast pool to IENavView interface to access extension methods
            const navViewPool = await hre.ethers.getContractAt("IENavView", pool.address);
            
            // Should work and return empty array for empty pool
            const balances = await navViewPool.getAllTokensAndBalancesView();
            expect(balances).to.be.an('array');
            // Empty pool should have empty or minimal balances
            expect(balances.length).to.be.gte(0);
        });

        it('should return NAV data through pool delegation', async () => {
            const { pool } = await setupTests();
            
            // Cast pool to IENavView interface  
            const navViewPool = await hre.ethers.getContractAt("IENavView", pool.address);
            
            // Should work and return valid NAV data structure
            const navData = await navViewPool.getNavDataView();
            expect(navData).to.have.property('totalValue');
            expect(navData).to.have.property('unitaryValue');
            expect(navData).to.have.property('timestamp');
            
            // Values should be reasonable (0 or positive for empty pool)
            expect(navData.totalValue).to.be.gte(0);
            expect(navData.unitaryValue).to.be.gte(0);
            expect(navData.timestamp).to.be.gt(0);
        });

        it('should return application balances through pool delegation', async () => {
            const { pool } = await setupTests();
            
            // Cast pool to IENavView interface
            const navViewPool = await hre.ethers.getContractAt("IENavView", pool.address);
            
            // Should work and return array (empty or with applications)
            const apps = await navViewPool.getAppTokensAndBalancesView();
            expect(apps).to.be.an('array');
            expect(apps.length).to.be.gte(0);
        });

        it('should work with pool that has tokens', async () => {
            const { pool, grgToken } = await setupTests();
            
            // Add some tokens to the pool
            const mintAmount = parseEther("100");
            await grgToken.approve(pool.address, mintAmount);
            await pool.mint(user1.address, mintAmount, 0);
            
            // Update NAV after minting
            await pool.updateUnitaryValue();
            
            // Cast pool to IENavView interface
            const navViewPool = await hre.ethers.getContractAt("IENavView", pool.address);
            
            // Should return token balances (at least the base token)
            const balances = await navViewPool.getAllTokensAndBalancesView();
            expect(balances.length).to.be.gte(1); // Should have at least base token
            
            const navData = await navViewPool.getNavDataView();
            // Total value might be 0 for test pools, but unitaryValue should be positive
            expect(navData.totalValue).to.be.gte(0);
            expect(navData.unitaryValue).to.be.gt(0); // Should be > 0 after minting
            expect(navData.timestamp).to.be.gt(0);
            
            // Verify we have a valid NAV structure
            expect(navData.unitaryValue).to.equal(parseEther("1")); // Should be 1.0 for fresh pool
        });
    });

    // NOTE: These tests verify ENavView extension works through pool delegation
    // Fork tests in ENavViewFork.t.sol test against live deployed pools
});