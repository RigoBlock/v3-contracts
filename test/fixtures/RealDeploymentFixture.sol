// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Constants} from "../../contracts/test/Constants.sol";
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
    address public AUTHORITY = Constants.AUTHORITY;

    // Deployed new contracts
    EAcrossHandler public eAcrossHandler;
    EApps public eApps;
    EOracle public eOracle;
    EUpgrade public eUpgrade;
    ENavView public eNavView;
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
        address wrappedNative;
        uint256 chainId;
        address oracle;
        address uniV4Posm;
        address grgStakingProxy;
    }
    
    /// @notice Deploy fixture on a specific fork
    /// @param baseToken Token to use as base token for pool
    function deployFixture(address baseToken) public {
        poolOwner = makeAddr("poolOwner");
        user = makeAddr("user");

        console2.log("Authority:", AUTHORITY);
        
        console2.log("=== Deploying Real Infrastructure Fixture ===");

        vm.createSelectFork("mainnet", Constants.MAINNET_BLOCK);
        _setupEthereum(baseToken);

        vm.createSelectFork("base", Constants.BASE_BLOCK);
        _setupBase(baseToken);
        
        console2.log("=== Fixture Deployment Complete ===");
    }

    function _setupEthereum(address baseToken) private {
        ChainConfig memory config = getEthereumConfig();
        
        _deployExtensions(config);
        _deployNewImplementation();
        _updateFactoryAndCreatePool(baseToken);
    }

    function _setupBase(address baseToken) private {
        ChainConfig memory config = getBaseConfig();
        
        _deployExtensions(config);
        _deployNewImplementation();
        _updateFactoryAndCreatePool(baseToken);
    }
    
    function _deployExtensions(ChainConfig memory config) private {
        // 1. Deploy new AIntents
        adapter = new AIntents(config.spokePool);
        console2.log("Deployed AIntents:", address(adapter));
        
        // 2. Deploy ExtensionsMapDeployer
        extensionsMapDeployer = new ExtensionsMapDeployer();
        console2.log("Deployed ExtensionsMapDeployer:", address(extensionsMapDeployer));
        
        // 3. Deploy extensions - will have different address from deployed (deployer address)
        eApps = new EApps(config.grgStakingProxy, config.uniV4Posm);
        eOracle = new EOracle(config.oracle, config.wrappedNative);
        eUpgrade = new EUpgrade(Constants.FACTORY);
        eNavView = new ENavView(config.grgStakingProxy, config.uniV4Posm);
        eAcrossHandler = new EAcrossHandler(config.spokePool);
        console2.log("Deployed extensions successfully");

        Extensions memory extensions = Extensions({
            eApps: address(eApps),
            eOracle: address(eOracle),
            eUpgrade: address(eUpgrade),
            eNavView: address(eNavView),
            eAcrossHandler: address(eAcrossHandler)
        });
        
        DeploymentParams memory params = DeploymentParams({
            extensions: extensions,
            wrappedNative: config.wrappedNative
        });
        
        // 5. Deploy new ExtensionsMap with different salt to avoid collision
        bytes32 newSalt = keccak256("TEST_EXTENSIONS_MAP_V1");
        address extensionsMapAddr = extensionsMapDeployer.deployExtensionsMap(params, newSalt);
        extensionsMap = ExtensionsMap(extensionsMapAddr);
        console2.log("Deployed ExtensionsMap:", address(extensionsMap));
    }
    
    function _deployNewImplementation() private {
        // Deploy mock TokenJar (using a simple mock address for deterministic deployment)
        address mockTokenJar = address(0x4444444444444444444444444444444444444444);
        
        // Deploy new SmartPool implementation
        implementation = new SmartPool(
            AUTHORITY,
            address(extensionsMap),
            mockTokenJar
        );
        console2.log("Deployed SmartPool implementation:", address(implementation));
    }
    
    function _updateFactoryAndCreatePool(address baseToken) private {
        // Update factory to use new implementation
        // We need to prank as the RigoblockDao from the registry
        address registry = IRigoblockPoolProxyFactory(Constants.FACTORY).getRegistry();
        address rigoblockDao = IPoolRegistry(registry).rigoblockDao();
        console2.log("RigoblockDao:", rigoblockDao);
        
        vm.prank(rigoblockDao);
        IRigoblockPoolProxyFactory(Constants.FACTORY).setImplementation(address(implementation));
        console2.log("Updated factory implementation");
        
        // Deploy a new pool from factory
        vm.prank(poolOwner);
        (address poolAddr, ) = IRigoblockPoolProxyFactory(Constants.FACTORY).createPool(
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

        vm.prank(rigoblockDaoAuth);

        // first need to whitelist the adapter and set self as whitelister
        IAuthority(AUTHORITY).setAdapter(address(adapter), true);
        if (!IAuthority(AUTHORITY).isWhitelister(rigoblockDaoAuth)) {
            IAuthority(AUTHORITY).setWhitelister(rigoblockDaoAuth, true);
        }


        IAuthority(AUTHORITY).addMethod(AIntents.depositV3.selector, address(adapter));
        IAuthority(AUTHORITY).addMethod(AIntents.getEscrowAddress.selector, address(adapter));
        console2.log("Added depositV3 and getEscrowAddress selectors to authority");
        
        // Fund the pool for testing
        deal(baseToken, pool, 1000000e6); // 1M base token
        console2.log("Funded pool with tokens");
    }
    
    /// @notice Helper to get chain config for Optimism
    function getEthereumConfig() public pure returns (ChainConfig memory) {
        return ChainConfig({
            spokePool: Constants.ETH_SPOKE_POOL,
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
            wrappedNative: Constants.BASE_WETH,
            chainId: Constants.BASE_CHAIN_ID,
            grgStakingProxy: Constants.GRG_STAKING,
            uniV4Posm: Constants.BASE_UNISWAP_V4_POSM,
            oracle: Constants.BASE_ORACLE
        });
    }

    /// @notice Helper to get chain config for Base
    function getPolygonConfig() public pure returns (ChainConfig memory) {
        return ChainConfig({
            spokePool: Constants.BASE_SPOKE_POOL,
            wrappedNative: Constants.POLY_WPOL,
            chainId: Constants.POLYGON_CHAIN_ID,
            grgStakingProxy: Constants.POLYGON_GRG_STAKING,
            uniV4Posm: Constants.POLYGON_UNISWAP_V4_POSM,
            oracle: Constants.POLYGON_ORACLE
        });
    }
}
