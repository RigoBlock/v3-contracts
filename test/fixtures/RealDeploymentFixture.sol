// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {ECrosschain} from "../../contracts/protocol/extensions/ECrosschain.sol";
import {EApps} from "../../contracts/protocol/extensions/EApps.sol";
import {ENavView} from "../../contracts/protocol/extensions/ENavView.sol";
import {EOracle} from "../../contracts/protocol/extensions/EOracle.sol";
import {EUpgrade} from "../../contracts/protocol/extensions/EUpgrade.sol";
import {AIntents} from "../../contracts/protocol/extensions/adapters/AIntents.sol";
import {IAIntents} from "../../contracts/protocol/extensions/adapters/interfaces/IAIntents.sol";
import {ExtensionsMap} from "../../contracts/protocol/deps/ExtensionsMap.sol";
import {ExtensionsMapDeployer} from "../../contracts/protocol/deps/ExtensionsMapDeployer.sol";
import {SmartPool} from "../../contracts/protocol/SmartPool.sol";
import {Extensions, DeploymentParams, EAppsParams} from "../../contracts/protocol/types/DeploymentParams.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {IPoolRegistry} from "../../contracts/protocol/interfaces/IPoolRegistry.sol";
import {IAuthority} from "../../contracts/protocol/interfaces/IAuthority.sol";
import {ISmartPool} from "../../contracts/protocol/ISmartPool.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {IOwnedUninitialized} from "../../contracts/utils/owned/IOwnedUninitialized.sol";

/// @title RealDeploymentFixture
/// @notice Fixture that uses actual deployed SmartPool infrastructure for testing
/// @dev This deploys new extensions and implementation but uses existing factory/authority
contract RealDeploymentFixture is Test {
    address public AUTHORITY = Constants.AUTHORITY;

    // Per-chain deployment data
    struct ChainDeployment {
        ECrosschain eCrosschain;
        EApps eApps;
        EOracle eOracle;
        EUpgrade eUpgrade;
        ENavView eNavView;
        AIntents aIntentsAdapter;
        ExtensionsMap extensionsMap;
        ExtensionsMapDeployer extensionsMapDeployer;
        SmartPool implementation;
        address pool;
        address baseToken;
        address spokePool;
    }
    
    // Chain-specific deployments
    ChainDeployment public ethereum;
    ChainDeployment public base;
    
    // Convenience accessors for current active chain (for backward compatibility)
    function eCrosschain() public view returns (ECrosschain) {
        if (block.chainid == Constants.ETHEREUM_CHAIN_ID) return ethereum.eCrosschain;
        if (block.chainid == Constants.BASE_CHAIN_ID) return base.eCrosschain;
        revert("Unsupported chain");
    }
    
    function aIntentsAdapter() public view returns (AIntents) {
        if (block.chainid == Constants.ETHEREUM_CHAIN_ID) return ethereum.aIntentsAdapter;
        if (block.chainid == Constants.BASE_CHAIN_ID) return base.aIntentsAdapter;
        revert("Unsupported chain");
    }
    
    function pool() public view returns (address) {
        if (block.chainid == Constants.ETHEREUM_CHAIN_ID) return ethereum.pool;
        if (block.chainid == Constants.BASE_CHAIN_ID) return base.pool;
        revert("Unsupported chain");
    }
    
    // Test accounts
    address public poolOwner;
    address public user;
    
    // Fork IDs for chain switching
    uint256 public mainnetForkId;
    uint256 public baseForkId;
    
    struct ChainConfig {
        address spokePool;
        address multicallHandler;
        address wrappedNative;
        uint256 chainId;
        address oracle;
        address uniV4Posm;
        address grgStakingProxy;
    }
    
    /// @notice Deploy fixture on specific chains based on number of base tokens provided
    /// @param baseTokens Array of addresses to use as base token - 1 token = single chain, 2+ tokens = multi chain
    function deployFixture(address[] memory baseTokens) public {
        poolOwner = makeAddr("poolOwner");
        user = makeAddr("user");

        console2.log("Authority:", AUTHORITY);
        
        console2.log("=== Deploying Real Infrastructure Fixture ===");

        if (baseTokens.length == 1) {
            // Single chain deployment (Ethereum only)
            mainnetForkId = vm.createSelectFork("mainnet", Constants.MAINNET_BLOCK);
            ethereum = _setupEthereum(baseTokens[0]);
            console2.log("Single chain deployment completed on Ethereum");
        } else if (baseTokens.length == 2) {
            // Multi-chain deployment
            mainnetForkId = vm.createSelectFork("mainnet", Constants.MAINNET_BLOCK);
            ethereum = _setupEthereum(baseTokens[0]);

            baseForkId = vm.createSelectFork("base", Constants.BASE_BLOCK);
            base = _setupBase(baseTokens[1]);
            console2.log("Multi-chain deployment completed");
        } else {
            revert("Only ethereum and base forks atm");
        }
        
        console2.log("=== Fixture Deployment Complete ===");
    }

    function _setupEthereum(address baseToken) private returns (ChainDeployment memory deployment) {
        ChainConfig memory config = getEthereumConfig();

        // user needs balance in order to mint
        deal(Constants.ETH_USDC, user, 1000000e6);
        deal(Constants.ETH_WETH, user, 100e18);
        
        deployment = _deployExtensions(config);
        deployment.implementation = _deployNewImplementation(deployment.extensionsMap);
        deployment.pool = _updateFactoryAndCreatePool(baseToken, deployment.implementation, deployment.aIntentsAdapter);
        deployment.baseToken = baseToken;
        deployment.spokePool = config.spokePool;
        
        return deployment;
    }

    function _setupBase(address baseToken) private returns (ChainDeployment memory deployment) {
        ChainConfig memory config = getBaseConfig();

        // user needs balance in order to mint
        deal(Constants.BASE_USDC, user, 1000000e6);
        deal(Constants.BASE_WETH, user, 100e18);
        
        deployment = _deployExtensions(config);
        deployment.implementation = _deployNewImplementation(deployment.extensionsMap);
        deployment.pool = _updateFactoryAndCreatePool(baseToken, deployment.implementation, deployment.aIntentsAdapter);
        deployment.baseToken = baseToken;
        deployment.spokePool = config.spokePool;
        
        return deployment;
    }
    
    function _deployExtensions(ChainConfig memory config) public returns (ChainDeployment memory deployment) {
        // 1. Deploy extensions - will have different address from deployed (deployer address)
        deployment.eApps = new EApps(EAppsParams({grgStakingProxy: config.grgStakingProxy, univ4Posm: config.uniV4Posm}));
        deployment.eOracle = new EOracle(config.oracle, config.wrappedNative);
        deployment.eUpgrade = new EUpgrade(Constants.FACTORY);
        deployment.eNavView = new ENavView(EAppsParams({grgStakingProxy: config.grgStakingProxy, univ4Posm: config.uniV4Posm}));
        deployment.eCrosschain = new ECrosschain();
        console2.log("Deployed extensions successfully");

        Extensions memory extensions = Extensions({
            eApps: address(deployment.eApps),
            eOracle: address(deployment.eOracle),
            eUpgrade: address(deployment.eUpgrade),
            eNavView: address(deployment.eNavView),
            eCrosschain: address(deployment.eCrosschain)
        });

        // 2. Deploy ExtensionsMapDeployer
        deployment.extensionsMapDeployer = new ExtensionsMapDeployer();
        console2.log("Deployed ExtensionsMapDeployer:", address(deployment.extensionsMapDeployer));
        
        DeploymentParams memory params = DeploymentParams({
            extensions: extensions,
            wrappedNative: config.wrappedNative
        });
        
        // 3. Deploy new ExtensionsMap with different salt to avoid collision
        bytes32 newSalt = keccak256(abi.encodePacked("TEST_EXTENSIONS_MAP_V1_", block.chainid));
        address extensionsMapAddr = deployment.extensionsMapDeployer.deployExtensionsMap(params, newSalt);
        deployment.extensionsMap = ExtensionsMap(extensionsMapAddr);
        console2.log("Deployed ExtensionsMap:", address(deployment.extensionsMap));

        // 4. Deploy new AIntents
        deployment.aIntentsAdapter = new AIntents(config.spokePool);
        console2.log("Deployed AIntents:", address(deployment.aIntentsAdapter));
        
        return deployment;
    }
    
    function _deployNewImplementation(ExtensionsMap extensionsMapParam) public returns (SmartPool) {        
        // Deploy new SmartPool implementation
        SmartPool impl = new SmartPool(
            AUTHORITY,
            address(extensionsMapParam),
            Constants.TOKEN_JAR
        );
        console2.log("Deployed SmartPool implementation:", address(impl));
        return impl;
    }
    
    function _updateFactoryAndCreatePool(address baseToken, SmartPool impl, AIntents adapter) public returns (address) {
        // Update factory to use new implementation
        // We need to prank as the RigoblockDao from the registry
        address registry = IRigoblockPoolProxyFactory(Constants.FACTORY).getRegistry();
        address rigoblockDao = IPoolRegistry(registry).rigoblockDao();
        console2.log("RigoblockDao:", rigoblockDao);
        
        vm.prank(rigoblockDao);
        IRigoblockPoolProxyFactory(Constants.FACTORY).setImplementation(address(impl));
        console2.log("Updated factory implementation");
        
        // Deploy a new pool from factory
        vm.prank(poolOwner);
        (address poolAddr, ) = IRigoblockPoolProxyFactory(Constants.FACTORY).createPool(
            "Test Pool",
            "TEST",
            baseToken
        );
        console2.log("Created pool:", poolAddr);
        console2.log("Base token:", baseToken);
        console2.log("Chain:", block.chainid);
        
        // Add adapter selectors to authority
        // Authority uses whitelister pattern
        address authorityOwner = IOwnedUninitialized(AUTHORITY).owner();
        console2.log("Using authority owner for authority:", authorityOwner);

        vm.startPrank(authorityOwner);
        
        // First whitelist the adapter 
        IAuthority(AUTHORITY).setAdapter(address(adapter), true);
        console2.log("Set intents adapter as whitelisted");
        
        // Check if RigoblockDao is already a whitelister
        bool isWhitelister = IAuthority(AUTHORITY).isWhitelister(authorityOwner);

        if (!isWhitelister) {
            IAuthority(AUTHORITY).setWhitelister(authorityOwner, true);
        }
        
        IAuthority authorityInstance = IAuthority(AUTHORITY);
        authorityInstance.addMethod(IAIntents.depositV3.selector, address(adapter));
        assertEq(authorityInstance.getApplicationAdapter(IAIntents.depositV3.selector), address(adapter), "depositV3 selector should be mapped");
        console2.log("Mapped depositV3 selector in authority");
        
        vm.stopPrank();
        
        // Fund the pool for testing
        vm.startPrank(user);

        IERC20(baseToken).approve(poolAddr, type(uint256).max);
        uint256 mintAmount = ISmartPool(payable(poolAddr)).mint(user, 100000e6, 0);
        console2.log("Minted pool with base token:", mintAmount);
        vm.stopPrank();
        
        return poolAddr;
    }
    
    /// @notice Helper to get chain config for Optimism
    function getEthereumConfig() public pure returns (ChainConfig memory) {
        return ChainConfig({
            spokePool: Constants.ETH_SPOKE_POOL,
            multicallHandler: Constants.ETH_MULTICALL_HANDLER,
            wrappedNative: Constants.ETH_WETH,
            chainId: Constants.ETHEREUM_CHAIN_ID,
            grgStakingProxy: Constants.GRG_STAKING,
            uniV4Posm: Constants.UNISWAP_V4_POSM,
            oracle: Constants.ORACLE
        });
    }
    
    /// @notice Helper to get chain config for Base
    function getBaseConfig() public pure returns (ChainConfig memory) {
        return ChainConfig({
            spokePool: Constants.BASE_SPOKE_POOL,
            multicallHandler: Constants.BASE_MULTICALL_HANDLER,
            wrappedNative: Constants.BASE_WETH,
            chainId: Constants.BASE_CHAIN_ID,
            grgStakingProxy: Constants.BASE_GRG_STAKING,
            uniV4Posm: Constants.BASE_UNISWAP_V4_POSM,
            oracle: Constants.BASE_ORACLE
        });
    }

    /// @notice Helper to get chain config for Base
    function getPolygonConfig() public pure returns (ChainConfig memory) {
        return ChainConfig({
            spokePool: Constants.BASE_SPOKE_POOL,
            multicallHandler: Constants.POLY_MULTICALL_HANDLER,
            wrappedNative: Constants.POLY_WPOL,
            chainId: Constants.POLYGON_CHAIN_ID,
            grgStakingProxy: Constants.POLYGON_GRG_STAKING,
            uniV4Posm: Constants.POLYGON_UNISWAP_V4_POSM,
            oracle: Constants.POLYGON_ORACLE
        });
    }
}
