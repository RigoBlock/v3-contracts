// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {SmartPool} from "../../contracts/protocol/SmartPool.sol";
import {ExtensionsMap} from "../../contracts/protocol/deps/ExtensionsMap.sol";
import {ExtensionsMapDeployer} from "../../contracts/protocol/deps/ExtensionsMapDeployer.sol";
import {EApps} from "../../contracts/protocol/extensions/EApps.sol";
import {EUpgrade} from "../../contracts/protocol/extensions/EUpgrade.sol";
import {EOracle} from "../../contracts/protocol/extensions/EOracle.sol";
import {ECrosschain} from "../../contracts/protocol/extensions/ECrosschain.sol";
import {ENavView} from "../../contracts/protocol/extensions/ENavView.sol";
import {IECrosschain} from "../../contracts/protocol/extensions/adapters/interfaces/IECrosschain.sol";
import {IAuthority} from "../../contracts/protocol/interfaces/IAuthority.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {DeploymentParams, Extensions} from "../../contracts/protocol/types/DeploymentParams.sol";

/// @title UnitTestFixture - Minimal deployment for unit tests without forks
/// @notice Deploys real SmartPool implementation and pool proxy on local network
contract UnitTestFixture is Test {
    struct Deployment {
        SmartPool implementation;
        ECrosschain eCrosschain;
        EUpgrade eUpgrade;
        EOracle eOracle;
        ENavView eNavView;
        EApps eApps;
        ExtensionsMap extensionsMap;
        address pool;
        address authority;
        address factory;
        address tokenJar;
        address wrappedNative;
    }

    Deployment public deployment;

    address public registry;
    address public stakingProxy;

    /// @notice Deploy minimal infrastructure for unit tests
    function deployFixture() public virtual {
        console2.log("=== Deploying Unit Test Fixture ===");
        address deployer = address(this);

        // Deploy minimal mock authority (needs code at address)
        deployment.authority = deployCode("out/Authority.sol/Authority.json", abi.encode(address(this)));
        IAuthority(deployment.authority).setWhitelister(deployer, true);

        // TODO: update if we implement tokenJar in this package
        deployment.tokenJar = address(0);

        // TODO: it turns out implementation needs upgrade extension which needs factory, which needs implementation - recursive.
        // It was implemented so because originally we only had adapters (mapped from authority). Review deployment flow in a future major release.
        registry = deployCode("out/PoolRegistry.sol/PoolRegistry.json", abi.encode(deployment.authority, address(this)));
        address originalImplementationAddress = 0xeb0c08Ad44af89BcBB5Ed6dD28caD452311B8516;
        deployment.factory = deployCode("out/RigoblockPoolProxyFactory.sol/RigoblockPoolProxyFactory.json", abi.encode(originalImplementationAddress, registry));
        IAuthority(deployment.authority).setFactory(deployment.factory, true);

        // Deploy ExtensionsMap with ECrosschain - needs deployed factory
        _deployExtensions();

        // Deploy SmartPool implementation
        deployment.implementation = new SmartPool(
            deployment.authority,
            address(deployment.extensionsMap),
            deployment.tokenJar
        );
        console2.log("Deployed SmartPool implementation:", address(deployment.implementation));

        // upgrade implementation to latest
        IRigoblockPoolProxyFactory(deployment.factory).setImplementation(address(deployment.implementation));

        console2.log("=== Unit Test Fixture Complete ===");
    }

    /// @notice Deploy ExtensionsMap with ECrosschain
    function _deployExtensions() private {
        deployment.wrappedNative = deployCode("out/WETH9.sol/WETH9.json");
        _deployStakingSuite();
    
        address mockUniv4Posm = deployCode("out/MockUniswapNpm.sol/MockUniswapNpm.json", abi.encode(deployment.wrappedNative));
        address mockOracle = deployCode("out/MockOracle.sol/MockOracle.json");

        // Deploy extensions - will require mockCall or, as for EOracle.getTwap, mockCall on the oracle contract (due to foundry limitation on mockCall for internal calls)
        deployment.eApps = new EApps(stakingProxy, mockUniv4Posm);
        deployment.eOracle = new EOracle(mockOracle, deployment.wrappedNative);
        deployment.eUpgrade = new EUpgrade(deployment.factory);
        deployment.eCrosschain = new ECrosschain();
        deployment.eNavView = new ENavView(stakingProxy, mockUniv4Posm);

        console2.log("Deployed EApps:", address(deployment.eApps));
        console2.log("Deployed EOracle:", address(deployment.eOracle));
        console2.log("Deployed EUpgrade:", address(deployment.eUpgrade));
        console2.log("Deployed ECrosschain:", address(deployment.eCrosschain));
        console2.log("Deployed ENavView:", address(deployment.eNavView));

        ExtensionsMapDeployer deployer = new ExtensionsMapDeployer();

        Extensions memory extensions = Extensions({
            eApps: address(deployment.eApps),
            eOracle: address(deployment.eOracle),
            eUpgrade: address(deployment.eUpgrade),
            eCrosschain: address(deployment.eCrosschain),
            eNavView: address(deployment.eNavView)
        });

        DeploymentParams memory params = DeploymentParams({
            extensions: extensions,
            wrappedNative: deployment.wrappedNative
        });

        bytes32 salt = keccak256("unit-test-extensions-map");
        address extensionsMapAddr = deployer.deployExtensionsMap(params, salt);
        deployment.extensionsMap = ExtensionsMap(extensionsMapAddr);
        console2.log("Deployed ExtensionsMap:", address(deployment.extensionsMap));
    }

    // This is required to avoid having to mock many returned calls from the staking proxy made by the EApps extension
    function _deployStakingSuite() private {
        address grg = deployCode("out/RigoToken.sol/RigoToken.json", abi.encode(address(this), address(this), address(this))); 
        address grgTransferProxy = deployCode("out/ERC20Proxy.sol/ERC20Proxy.json", abi.encode(address(this)));
        address grgVault = deployCode("out/GrgVault.sol/GrgVault.json", abi.encode(grgTransferProxy, grg, address(this)));
        IERC20Proxy(grgTransferProxy).addAuthorizedAddress(grgVault);
        address staking = deployCode("out/Staking.sol/Staking.json", abi.encode(grgVault, registry, grg));
        stakingProxy = deployCode("out/StakingProxy.sol/StakingProxy.json", abi.encode(staking, address(this)));
    }
}

interface IERC20Proxy {
    function addAuthorizedAddress(address target) external;
}

