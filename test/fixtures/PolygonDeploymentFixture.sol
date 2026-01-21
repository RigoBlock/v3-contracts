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
import {Extensions, DeploymentParams} from "../../contracts/protocol/types/DeploymentParams.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {IPoolRegistry} from "../../contracts/protocol/interfaces/IPoolRegistry.sol";
import {IAuthority} from "../../contracts/protocol/interfaces/IAuthority.sol";
import {ISmartPool} from "../../contracts/protocol/ISmartPool.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {IOwnedUninitialized} from "../../contracts/utils/owned/IOwnedUninitialized.sol";

/// @title PolygonDeploymentFixture
/// @notice Fixture for testing SmartPool on Polygon PoS with POL as native currency
/// @dev This fixture tests that POL (address(0)) behaves like ETH on Ethereum
contract PolygonDeploymentFixture is Test {
    address public AUTHORITY = Constants.AUTHORITY;
    address public FACTORY = Constants.FACTORY;

    // TODO: this tuple will result in coverage stack-too-deep error if the contract is included.
    // Currently excluded from coverage and just used for running local tests to assert polygon chain compatibility.
    struct PolygonChainDeployment {
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
    
    // Polygon deployment
    PolygonChainDeployment public polygon;
    
    // Test accounts
    address public poolOwner;
    address public user;
    
    // Fork ID
    uint256 public polygonForkId;
    
    struct ChainConfig {
        address spokePool;
        address multicallHandler;
        address wrappedNative;
        uint256 chainId;
        address oracle;
        address uniV4Posm;
        address grgStakingProxy;
    }
    
    /// @notice Deploy fixture on Polygon chain
    /// @param baseTokenAddress Address to use as base token (address(0) for POL native)
    function deployFixture(address baseTokenAddress) public {
        poolOwner = makeAddr("polygonPoolOwner");
        user = makeAddr("polygonUser");

        console2.log("Authority:", AUTHORITY);
        
        console2.log("=== Deploying Polygon Deployment Fixture ===");

        // Create Polygon fork
        polygonForkId = vm.createSelectFork("polygon", Constants.POLYGON_BLOCK);
        polygon = _setupPolygon(baseTokenAddress);
        console2.log("Polygon deployment completed");
        
        console2.log("=== Fixture Deployment Complete ===");
    }

    function _setupPolygon(address baseTokenAddress) private returns (PolygonChainDeployment memory deployment) {
        ChainConfig memory config = getPolygonConfig();

        // Give user balance for testing
        // POL as native (need ETH balance for gas + value)
        deal(user, 1000 ether); // Native POL
        
        // Also give some USDC for alternative tests
        deal(Constants.POLY_USDC, user, 1000000e6);
        
        deployment = _deployExtensions(config);
        deployment.implementation = _deployNewImplementation(deployment.extensionsMap);
        deployment.pool = _updateFactoryAndCreatePool(baseTokenAddress, deployment.implementation, deployment.aIntentsAdapter);
        deployment.baseToken = baseTokenAddress;
        deployment.spokePool = config.spokePool;
        
        return deployment;
    }
    
    function _deployExtensions(ChainConfig memory config) public returns (PolygonChainDeployment memory deployment) {
        // 1. Deploy extensions
        deployment.eApps = new EApps(config.grgStakingProxy, config.uniV4Posm);
        deployment.eOracle = new EOracle(config.oracle, config.wrappedNative);
        deployment.eUpgrade = new EUpgrade(Constants.FACTORY);
        deployment.eNavView = new ENavView(config.grgStakingProxy, config.uniV4Posm);
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
        bytes32 newSalt = keccak256(abi.encodePacked("TEST_POLYGON_EXTENSIONS_MAP_V1_", block.chainid));
        address extensionsMapAddr = deployment.extensionsMapDeployer.deployExtensionsMap(params, newSalt);
        deployment.extensionsMap = ExtensionsMap(extensionsMapAddr);
        console2.log("Deployed ExtensionsMap:", address(deployment.extensionsMap));

        // 4. Deploy new AIntents
        deployment.aIntentsAdapter = new AIntents(config.spokePool);
        console2.log("Deployed AIntents:", address(deployment.aIntentsAdapter));
        
        return deployment;
    }
    
    function _deployNewImplementation(ExtensionsMap extensionsMapParam) public returns (SmartPool) {
        // Deploy mock TokenJar
        address mockTokenJar = address(0x4444444444444444444444444444444444444444);
        
        // Deploy new SmartPool implementation
        SmartPool impl = new SmartPool(
            AUTHORITY,
            address(extensionsMapParam),
            mockTokenJar
        );
        console2.log("Deployed SmartPool implementation:", address(impl));
        return impl;
    }
    
    function _updateFactoryAndCreatePool(address baseTokenAddress, SmartPool impl, AIntents adapter) public returns (address) {
        // Update factory to use new implementation
        address registry = IRigoblockPoolProxyFactory(Constants.FACTORY).getRegistry();
        address rigoblockDao = IPoolRegistry(registry).rigoblockDao();
        console2.log("RigoblockDao:", rigoblockDao);
        
        vm.prank(rigoblockDao);
        IRigoblockPoolProxyFactory(Constants.FACTORY).setImplementation(address(impl));
        console2.log("Updated factory implementation");
        
        // Deploy a new pool from factory
        vm.prank(poolOwner);
        (address poolAddr, ) = IRigoblockPoolProxyFactory(Constants.FACTORY).createPool(
            "Polygon POL Pool",
            "PPOL",
            baseTokenAddress
        );
        console2.log("Created pool:", poolAddr);
        console2.log("Base token:", baseTokenAddress);
        console2.log("Chain:", block.chainid);
        
        // Add adapter selectors to authority
        address authorityOwner = IOwnedUninitialized(AUTHORITY).owner();
        console2.log("Using authority owner for authority:", authorityOwner);

        vm.startPrank(authorityOwner);
        
        // Whitelist the adapter 
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

        if (baseTokenAddress == address(0)) {
            // Native POL mint
            uint256 mintAmount = ISmartPool(payable(poolAddr)).mint{value: 100 ether}(user, 100 ether, 0);
            console2.log("Minted pool with native POL:", mintAmount);
        } else {
            // ERC20 mint
            IERC20(baseTokenAddress).approve(poolAddr, type(uint256).max);
            uint256 mintAmount = ISmartPool(payable(poolAddr)).mint(user, 100000e6, 0);
            console2.log("Minted pool with base token:", mintAmount);
        }
        
        vm.stopPrank();
        
        return poolAddr;
    }
    
    /// @notice Helper to get chain config for Polygon
    function getPolygonConfig() public pure returns (ChainConfig memory) {
        return ChainConfig({
            spokePool: address(0), // Polygon doesn't have Across SpokePool yet
            multicallHandler: Constants.POLY_MULTICALL_HANDLER,
            wrappedNative: Constants.POLY_WPOL,
            chainId: Constants.POLYGON_CHAIN_ID,
            grgStakingProxy: Constants.POLYGON_GRG_STAKING,
            uniV4Posm: Constants.POLYGON_UNISWAP_V4_POSM,
            oracle: Constants.POLYGON_ORACLE
        });
    }
    
    /// @notice Convenience accessor for pool
    function pool() public view returns (address) {
        return polygon.pool;
    }
    
    /// @notice Convenience accessor for base token
    function baseToken() public view returns (address) {
        return polygon.baseToken;
    }
}
