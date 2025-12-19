// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {AIntents} from "../../contracts/protocol/extensions/adapters/AIntents.sol";
import {EAcrossHandler} from "../../contracts/protocol/extensions/EAcrossHandler.sol";
import {EApps} from "../../contracts/protocol/extensions/EApps.sol";
import {ENavView} from "../../contracts/protocol/extensions/ENavView.sol";
import {EOracle} from "../../contracts/protocol/extensions/EOracle.sol";
import {EUpgrade} from "../../contracts/protocol/extensions/EUpgrade.sol";
import {ExtensionsMap} from "../../contracts/protocol/deps/ExtensionsMap.sol";
import {ExtensionsMapDeployer} from "../../contracts/protocol/deps/ExtensionsMapDeployer.sol";
import {SmartPool} from "../../contracts/protocol/SmartPool.sol";
import {Extensions, DeploymentParams} from "../../contracts/protocol/types/DeploymentParams.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {IPoolRegistry} from "../../contracts/protocol/interfaces/IPoolRegistry.sol";
import {IAuthority} from "../../contracts/protocol/interfaces/IAuthority.sol";
import {ISmartPool} from "../../contracts/protocol/ISmartPool.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";

/// @title RealDeploymentFixture
/// @notice Fixture that uses actual deployed SmartPool infrastructure for testing
/// @dev This deploys new extensions and implementation but uses existing factory/authority
contract RealDeploymentFixture is Test {
    // Chain-specific addresses - using same constants as ENavViewFork.t.sol
    address constant GRG_STAKING = 0x730dDf7b602dB822043e0409d8926440395e07fE;
    address constant UNISWAP_V4_POSM = 0x00000000000000000000000000000000DeaDBeef; // Placeholder for now
    address constant ORACLE = 0xB13250f0Dc8ec6dE297E81CDA8142DB51860BaC4;
    
    // Deployed contracts (same across most chains)
    address constant AUTHORITY = 0x7F427F11eB24f1be14D0c794f6d5a9830F18FBf1;
    address constant FACTORY = 0x4aA9e5A5A244C81C3897558C5cF5b752EBefA88f;
    address constant REGISTRY = 0x19Be0f8D5f35DB8c2d2f50c9a3742C5d1eB88907;
    
    // Across SpokePools by chain
    address constant ARB_SPOKE_POOL = 0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A;
    address constant OPT_SPOKE_POOL = 0x6f26Bf09B1C792e3228e5467807a900A503c0281;
    address constant BASE_SPOKE_POOL = 0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64;
    
    // WETH addresses by chain
    address constant WETH_ARB = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant WETH_OPT = 0x4200000000000000000000000000000000000006;
    address constant WETH_BASE = 0x4200000000000000000000000000000000000006;
    
    // Deployed new contracts
    EAcrossHandler public handler;
    AIntents public adapter;
    ExtensionsMap public extensionsMap;
    ExtensionsMapDeployer public extensionsMapDeployer;
    SmartPool public implementation;
    
    // Created pool
    address public pool;
    
    // Test accounts
    address public poolOwner;
    address public user;
    
    struct ChainConfig {
        address spokePool;
        address weth;
        uint256 chainId;
    }
    
    /// @notice Deploy fixture on a specific fork
    /// @param config Chain-specific configuration
    /// @param baseToken Token to use as base token for pool
    /// @param referencePool Existing pool to read authority and factory addresses from
    function deployFixture(ChainConfig memory config, address baseToken, address referencePool) public {
        poolOwner = makeAddr("poolOwner");
        user = makeAddr("user");
        
        console2.log("=== Deploying Real Infrastructure Fixture ===");
        
        // Read infrastructure addresses from existing pool
        address authorityAddress = ISmartPool(payable(referencePool)).authority();
        console2.log("Authority (from pool):", authorityAddress);
        
        _deployExtensions(config);
        _deployNewImplementation(authorityAddress);
        _updateFactoryAndCreatePool(baseToken, authorityAddress);
        
        console2.log("=== Fixture Deployment Complete ===");
    }
    
    function _deployExtensions(ChainConfig memory config) private {
        handler = new EAcrossHandler(config.spokePool);
        console2.log("Deployed EAcrossHandler:", address(handler));
        
        // 2. Deploy new AIntents
        adapter = new AIntents(config.spokePool);
        console2.log("Deployed AIntents:", address(adapter));
        
        // 3. Deploy ExtensionsMapDeployer
        extensionsMapDeployer = new ExtensionsMapDeployer();
        console2.log("Deployed ExtensionsMapDeployer:", address(extensionsMapDeployer));
        
        // 4. Use existing deployed extensions from the deployer contract
        // This way if extensions already exist, the deployer will skip deployment
        Extensions memory extensions = Extensions({
            eApps: address(0), // Will be deployed by extensionsMapDeployer if needed
            eNavView: address(0), // Will be deployed by extensionsMapDeployer if needed
            eOracle: address(0), // Will be deployed by extensionsMapDeployer if needed
            eUpgrade: address(0), // Will be deployed by extensionsMapDeployer if needed
            eAcrossHandler: address(handler)
        });
        
        DeploymentParams memory params = DeploymentParams({
            extensions: extensions,
            wrappedNative: config.weth
        });
        
        // 5. Deploy new ExtensionsMap with different salt to avoid collision
        bytes32 newSalt = keccak256("TEST_EXTENSIONS_MAP_V1");
        address extensionsMapAddr = extensionsMapDeployer.deployExtensionsMap(params, newSalt);
        extensionsMap = ExtensionsMap(extensionsMapAddr);
        console2.log("Deployed ExtensionsMap:", address(extensionsMap));
    }
    
    function _deployNewImplementation(address authorityAddress) private {
        // Deploy mock TokenJar (using a simple mock address for deterministic deployment)
        address mockTokenJar = address(0x4444444444444444444444444444444444444444);
        
        // Deploy new SmartPool implementation
        implementation = new SmartPool(
            authorityAddress,
            address(extensionsMap),
            mockTokenJar
        );
        console2.log("Deployed SmartPool implementation:", address(implementation));
    }
    
    function _updateFactoryAndCreatePool(address baseToken, address authorityAddress) private {
        // Update factory to use new implementation
        // We need to prank as the RigoblockDao from the registry
        address registry = IRigoblockPoolProxyFactory(FACTORY).getRegistry();
        address rigoblockDao = IPoolRegistry(registry).rigoblockDao();
        console2.log("RigoblockDao:", rigoblockDao);
        
        vm.prank(rigoblockDao);
        IRigoblockPoolProxyFactory(FACTORY).setImplementation(address(implementation));
        console2.log("Updated factory implementation");
        
        // Deploy a new pool from factory
        vm.prank(poolOwner);
        (address poolAddr, ) = IRigoblockPoolProxyFactory(FACTORY).createPool(
            "Test Pool",
            "TEST",
            baseToken
        );
        pool = poolAddr;
        console2.log("Created pool:", pool);
        
        // 10. Add adapter selector to authority
        // Authority uses whitelister pattern - use RigoblockDao as it typically has permissions
        address rigoblockDaoAuth = IPoolRegistry(registry).rigoblockDao();
        console2.log("Using RigoblockDao for authority:", rigoblockDaoAuth);
        
        // Add depositV3 selector to authority mapping
        bytes4 depositV3Selector = AIntents(address(adapter)).depositV3.selector;
        
        vm.prank(rigoblockDaoAuth);
        IAuthority(authorityAddress).addMethod(depositV3Selector, address(adapter));
        console2.log("Added depositV3 selector to authority");
        
        // Fund the pool for testing
        deal(baseToken, pool, 1000000e6); // 1M base token
        console2.log("Funded pool with tokens");
    }
    
    /// @notice Helper to get chain config for Arbitrum
    function getArbitrumConfig() public pure returns (ChainConfig memory) {
        return ChainConfig({
            spokePool: ARB_SPOKE_POOL,
            weth: WETH_ARB,
            chainId: 42161
        });
    }
    
    /// @notice Helper to get chain config for Optimism
    function getOptimismConfig() public pure returns (ChainConfig memory) {
        return ChainConfig({
            spokePool: OPT_SPOKE_POOL,
            weth: WETH_OPT,
            chainId: 10
        });
    }
    
    /// @notice Helper to get chain config for Base
    function getBaseConfig() public pure returns (ChainConfig memory) {
        return ChainConfig({
            spokePool: BASE_SPOKE_POOL,
            weth: WETH_BASE,
            chainId: 8453
        });
    }
}
