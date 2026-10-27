// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {SmartPool} from "../../contracts/protocol/SmartPool.sol";
import {ExtensionsMapDeployer} from "../../contracts/protocol/deps/ExtensionsMapDeployer.sol";
import {EAppsLighter} from "../../contracts/protocol/extensions/EAppsLighter.sol";
import {EUpgrade} from "../../contracts/protocol/extensions/EUpgrade.sol";
import {EOracle} from "../../contracts/protocol/extensions/EOracle.sol";
import {ECrosschain} from "../../contracts/protocol/extensions/ECrosschain.sol";
import {EERC20} from "../../contracts/protocol/extensions/EERC20.sol";
import {ALighter} from "../../contracts/protocol/extensions/adapters/ALighter.sol";
import {ILighterInteropManager} from "../../contracts/protocol/extensions/adapters/interfaces/lighter/ILighterInteropManager.sol";
import {ILighterCoreEntrypoint} from "../../contracts/protocol/extensions/adapters/interfaces/lighter/ILighterCoreEntrypoint.sol";
import {IAuthority} from "../../contracts/protocol/interfaces/IAuthority.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {IPoolRegistry} from "../../contracts/protocol/interfaces/IPoolRegistry.sol";
import {IOwnedUninitialized} from "../../contracts/utils/owned/IOwnedUninitialized.sol";
import {ISmartPool} from "../../contracts/protocol/ISmartPool.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {LighterConstants} from "../../contracts/protocol/types/LighterConstants.sol";
import {LighterLib} from "../../contracts/protocol/libraries/LighterLib.sol";
import {DeploymentParams, Extensions, EAppsParams} from "../../contracts/protocol/types/DeploymentParams.sol";
import {SafeTransferLib} from "../../contracts/protocol/libraries/SafeTransferLib.sol";

/// @title LighterDeploymentFixture
/// @notice Deploys real Rigoblock infrastructure on a LighterEVM fork for Lighter integration tests.
/// @dev Mirrors HyperliquidDeploymentFixture: no Uniswap V4 / BackGeoOracle on LighterEVM, so the
///  pool is restricted to USDC-denominated assets by the LighterEVM carve-out in EOracle.
/// @dev Requires LIGHTER_RPC_URL (like every other chain's fork suite): a missing or misconfigured
///  URL fails loudly at createSelectFork or at the chainid require below — never silently.
/// @dev READ_CORE is a native LighterEVM precompile that Foundry's EVM does not implement even when
///  forking, so read-precompile return data is mocked (same approach as the Hyperliquid fork tests).
contract LighterDeploymentFixture is Test {
    using SafeTransferLib for address;

    address public constant LIGHTER_USDC = Constants.LIGHTER_USDC;
    /// @dev Canonical WETH9 predeploy on LighterEVM.
    address public constant LIGHTER_WETH = 0x660000000000000000000000000000000000000c;
    uint256 public constant LIGHTEREVM_CHAIN_ID = Constants.LIGHTEREVM_CHAIN_ID;
    uint256 public constant LIGHTEREVM_BLOCK = Constants.LIGHTER_BLOCK;

    address public authority;
    address public registry;
    address public factory;
    address public implementation;
    address public extensionsMap;
    address public aLighter;
    address public pool;
    address public poolOwner;
    address public user;

    /// @notice True when the fixture reuses the live Authority/Registry/Factory from Constants.
    bool public usingLiveInfrastructure;

    /// @notice Deploy the fixture on a LighterEVM fork. Reverts when LIGHTER_RPC_URL is unset
    ///  (createSelectFork) or points at the wrong chain (chainid require) — like every other
    ///  chain's fork suite, so a missing or stale CI secret fails the build instead of skipping.
    function deployFixture() public {
        vm.createSelectFork("lighter", LIGHTEREVM_BLOCK);
        require(block.chainid == LIGHTEREVM_CHAIN_ID, "Not LighterEVM fork");

        poolOwner = makeAddr("poolOwner");
        user = makeAddr("user");

        // READ_CORE is a client-side precompile (no on-chain code; the node intercepts it), which
        // Foundry forks cannot execute. Revert any read by default; tests mock the specific
        // selectors they need (same approach as the Hyperliquid fork tests).
        bytes memory anyCalldata = hex"";
        vm.mockCallRevert(LighterConstants.READ_CORE, anyCalldata, new bytes(0));

        // Default every transaction-status read (0x0000) to "pending" (status 0): the deposit
        // tests then observe the in-flight amount through the adapter path. Tests that need
        // a processed write override with a specific status mock.
        bytes memory pendingStatus = abi.encode(uint8(0), bytes(""));
        vm.mockCall(LighterConstants.READ_CORE, abi.encodePacked(LighterLib._SELECTOR_TX_STATUS), pendingStatus);

        console2.log("=== Deploying Lighter LighterEVM Fixture ===");
        console2.log("Fork block:", block.number);
        console2.log("USDC:", LIGHTER_USDC);

        _assertNoExternalProtocolsOnLighterEVM();
        _setupInfrastructure();
        _deployExtensionsAndImplementation();
        _createPool();
        _deployAndAuthorizeAdapter();
        _fundPool();

        console2.log("=== Lighter LighterEVM Fixture Complete ===");
        console2.log("Pool:", pool);
        console2.log("ALighter:", aLighter);
    }

    /// @notice Future-proofing guardrail: Uniswap V4 is not deployed on LighterEVM at fixture time.
    /// @dev If these addresses become non-zero, the fixture (and the tests that rely on Lighter
    ///  being restricted to USDC) will fail. This is intentional: adding Uniswap V4 support on
    ///  LighterEVM requires explicit test updates and a security review of which tokens and
    ///  applications may become activatable.
    function _assertNoExternalProtocolsOnLighterEVM() private pure {
        require(Constants.LIGHTER_UNISWAP_V4_POSM == address(0), "LighterEVM fixture assumes no Uniswap V4 POSM");
        require(Constants.LIGHTER_UNIVERSAL_ROUTER == address(0), "LighterEVM fixture assumes no Universal Router");
    }

    /// @notice Uses live Authority/Registry/Factory when available, otherwise deploys a local copy.
    function _setupInfrastructure() private {
        if (Constants.AUTHORITY.code.length > 0 && Constants.FACTORY.code.length > 0) {
            authority = Constants.AUTHORITY;
            factory = Constants.FACTORY;
            registry = IRigoblockPoolProxyFactory(factory).getRegistry();
            usingLiveInfrastructure = true;
            console2.log("Using live LighterEVM infrastructure");
            console2.log("Authority:", authority);
            console2.log("Registry:", registry);
            console2.log("Factory:", factory);
        } else {
            _deployLocalInfrastructure();
        }
    }

    /// @notice Deploys a fresh Authority/Registry/Factory for pre-launch testing.
    function _deployLocalInfrastructure() private {
        // Deploy authority with fixture as owner. Authority is compiled with 0.8.17, so use deployCode.
        authority = deployCode("out/Authority.sol/Authority.json", abi.encode(address(this)));
        IAuthority(authority).setWhitelister(address(this), true);

        // Deploy registry and factory via artifacts to avoid mixing Solidity versions in the fixture source.
        registry = deployCode("out/PoolRegistry.sol/PoolRegistry.json", abi.encode(authority, address(this)));
        // Factory needs an initial implementation; we use a placeholder and upgrade later.
        factory = deployCode(
            "out/RigoblockPoolProxyFactory.sol/RigoblockPoolProxyFactory.json",
            abi.encode(address(0x1), registry)
        );

        IAuthority(authority).setFactory(factory, true);

        console2.log("Deployed local LighterEVM infrastructure");
        console2.log("Authority:", authority);
        console2.log("Registry:", registry);
        console2.log("Factory:", factory);
    }

    function _deployExtensionsAndImplementation() private {
        // LighterEVM has no Uniswap V4, GRG staking, or BackGeoOracle deployments at fixture time;
        // zero addresses are passed for those dependencies.
        address grgStakingProxy = address(0);
        address univ4Posm = address(0);

        // EOracle is required by ExtensionsMap but has no real oracle on LighterEVM. It treats USDC as
        // having a price feed on LighterEVM because USDC is Lighter's collateral/numeraire.
        address oracle = address(0);

        EAppsLighter eApps = new EAppsLighter(EAppsParams({grgStakingProxy: grgStakingProxy, univ4Posm: univ4Posm}));
        EOracle eOracle = new EOracle(oracle, LIGHTER_WETH);
        EUpgrade eUpgrade = new EUpgrade(factory);
        ECrosschain eCrosschain = new ECrosschain();
        EERC20 eErc20 = new EERC20();

        Extensions memory extensions = Extensions({
            eApps: address(eApps),
            eOracle: address(eOracle),
            eUpgrade: address(eUpgrade),
            eCrosschain: address(eCrosschain),
            eGmxCallback: address(0),
            eErc20: address(eErc20)
        });

        ExtensionsMapDeployer deployer = new ExtensionsMapDeployer();
        DeploymentParams memory params = DeploymentParams({extensions: extensions, wrappedNative: LIGHTER_WETH});
        bytes32 salt = keccak256(abi.encodePacked("LIGHTER_TEST_EXTENSIONS_MAP", block.chainid));
        extensionsMap = deployer.deployExtensionsMap(params, salt);

        implementation = address(new SmartPool(authority, extensionsMap, Constants.TOKEN_JAR));

        if (usingLiveInfrastructure) {
            address rigoblockDao = IPoolRegistry(registry).rigoblockDao();
            vm.prank(rigoblockDao);
            IRigoblockPoolProxyFactory(factory).setImplementation(implementation);
        } else {
            IRigoblockPoolProxyFactory(factory).setImplementation(implementation);
        }

        console2.log("ExtensionsMap:", extensionsMap);
        console2.log("Implementation:", implementation);
    }

    function _createPool() private {
        vm.prank(poolOwner);
        (pool, ) = IRigoblockPoolProxyFactory(factory).createPool("Lighter Test", "LTEST", LIGHTER_USDC);
        console2.log("Pool:", pool);
    }

    function _deployAndAuthorizeAdapter() private {
        aLighter = address(new ALighter());

        address authorityOwner = IOwnedUninitialized(authority).owner();
        vm.startPrank(authorityOwner);

        // The live Authority owner is not a whitelister; self-grant the role on the fork
        // before registering methods (addMethod is gated by onlyWhitelister).
        if (usingLiveInfrastructure) {
            IAuthority(authority).setWhitelister(authorityOwner, true);
        }

        IAuthority(authority).setAdapter(aLighter, true);
        _addOrReplaceMethod(ILighterInteropManager.sendToCore.selector, aLighter);
        _addOrReplaceMethod(ILighterInteropManager.sendToEvm.selector, aLighter);
        _addOrReplaceMethod(ILighterCoreEntrypoint.createOrder.selector, aLighter);
        _addOrReplaceMethod(ILighterCoreEntrypoint.cancelOrder.selector, aLighter);
        _addOrReplaceMethod(ILighterCoreEntrypoint.cancelAllOrders.selector, aLighter);

        vm.stopPrank();

        console2.log("ALighter authorized");
    }

    function _addOrReplaceMethod(bytes4 selector, address adapter) private {
        address current = IAuthority(authority).getApplicationAdapter(selector);
        if (current == adapter) return;
        if (current != address(0)) {
            IAuthority(authority).removeMethod(selector, current);
        }
        IAuthority(authority).addMethod(selector, adapter);
    }

    function _fundPool() private {
        // Give user and pool plenty of LighterEVM USDC.
        deal(LIGHTER_USDC, user, 1_000_000e6);
        deal(LIGHTER_USDC, pool, 1_000_000e6);

        // Mint pool tokens to the pool itself so it has non-zero supply and NAV for deposit tests.
        vm.startPrank(user);
        LIGHTER_USDC.safeApprove(pool, type(uint256).max);
        uint256 mintAmount = 100_000e6;
        ISmartPool(payable(pool)).mint(user, mintAmount, 0);
        vm.stopPrank();

        console2.log("Minted pool tokens:", mintAmount);
    }

    /// @notice Returns the LighterEVM USDC balance of the given account.
    function usdcBalance(address account) public view returns (uint256) {
        return IERC20(LIGHTER_USDC).balanceOf(account);
    }
}
