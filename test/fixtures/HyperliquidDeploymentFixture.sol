// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {SmartPool} from "../../contracts/protocol/SmartPool.sol";
import {ExtensionsMapDeployer} from "../../contracts/protocol/deps/ExtensionsMapDeployer.sol";
import {EApps} from "../../contracts/protocol/extensions/EApps.sol";
import {EUpgrade} from "../../contracts/protocol/extensions/EUpgrade.sol";
import {EOracle} from "../../contracts/protocol/extensions/EOracle.sol";
import {ECrosschain} from "../../contracts/protocol/extensions/ECrosschain.sol";
import {ENavView} from "../../contracts/protocol/extensions/ENavView.sol";
import {AHyperliquid} from "../../contracts/protocol/extensions/adapters/AHyperliquid.sol";
import {ICoreWriter} from "hyper-evm-lib/interfaces/ICoreWriter.sol";
import {ICoreDepositWallet} from "hyper-evm-lib/interfaces/ICoreDepositWallet.sol";
import {IAuthority} from "../../contracts/protocol/interfaces/IAuthority.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {IPoolRegistry} from "../../contracts/protocol/interfaces/IPoolRegistry.sol";
import {IOwnedUninitialized} from "../../contracts/utils/owned/IOwnedUninitialized.sol";
import {ISmartPool} from "../../contracts/protocol/ISmartPool.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {DeploymentParams, Extensions, EAppsParams} from "../../contracts/protocol/types/DeploymentParams.sol";
import {SafeTransferLib} from "../../contracts/protocol/libraries/SafeTransferLib.sol";

/// @title HyperliquidDeploymentFixture
/// @notice Deploys real Rigoblock infrastructure on a HyperEVM fork for Hyperliquid integration tests.
/// @dev Uses a dummy EOracle because Uniswap V4 / BackGeoOracle are not deployed on HyperEVM; the
///  pool is restricted to USDC-denominated assets by the Hyperliquid carve-out in EOracle.
/// @dev Before the live HyperEVM Rigoblock deployment, the fixture deploys its own Authority/Registry/Factory.
///  After launch, it detects live contracts at the addresses in Constants and reuses them, so the same
///  fixture works both pre- and post-launch.
/// @dev Uniswap V4 / Universal Router, GRG staking and GMX are not deployed on HyperEVM. The fixture
///  asserts that the corresponding Constants are address(0). 0x Settler is deployed on HyperEVM and
///  uses the canonical Constants.ZERO_EX_ALLOWANCE_HOLDER and Constants.ZERO_EX_DEPLOYER addresses.
///  If a future upgrade adds Uniswap V4 on HyperEVM, the fixture assertions will fail and the tests/docs
///  must be reviewed before the constants are updated.
contract HyperliquidDeploymentFixture is Test {
    using SafeTransferLib for address;

    // HyperEVM chain config
    address public constant HYPER_USDC = Constants.HYPER_USDC;
    address public constant HYPER_WHYPE = Constants.HYPER_WHYPE;
    uint256 public constant HYPEREVM_CHAIN_ID = Constants.HYPEREVM_CHAIN_ID;
    uint256 public constant HYPEREVM_BLOCK = Constants.HYPEREVM_BLOCK;

    address public authority;
    address public registry;
    address public factory;
    address public implementation;
    address public extensionsMap;
    address public aHyperliquid;
    address public pool;
    address public poolOwner;
    address public user;

    /// @notice True when the fixture reuses the live Authority/Registry/Factory from Constants.
    bool public usingLiveInfrastructure;

    /// @notice Deploy the fixture on a HyperEVM fork.
    function deployFixture() public {
        vm.createSelectFork("hyperliquid", HYPEREVM_BLOCK);
        require(block.chainid == HYPEREVM_CHAIN_ID, "Not HyperEVM fork");

        poolOwner = makeAddr("poolOwner");
        user = makeAddr("user");

        console2.log("=== Deploying Hyperliquid HyperEVM Fixture ===");
        console2.log("Fork block:", block.number);
        console2.log("USDC:", HYPER_USDC);
        console2.log("WHYPE:", HYPER_WHYPE);

        _assertNoExternalProtocolsOnHyperEVM();
        _setupInfrastructure();
        _deployExtensionsAndImplementation();
        _createPool();
        _deployAndAuthorizeAdapter();
        _fundPool();

        console2.log("=== Hyperliquid HyperEVM Fixture Complete ===");
        console2.log("Pool:", pool);
        console2.log("AHyperliquid:", aHyperliquid);
    }

    /// @notice Future-proofing guardrail: Uniswap V4 is not deployed on HyperEVM at fixture time.
    /// @dev If these addresses become non-zero, the fixture (and the tests that rely on Hyperliquid
    ///  being restricted to USDC) will fail. This is intentional: adding Uniswap V4 support on
    ///  HyperEVM requires explicit test updates and a security review of which tokens and
    ///  applications may become activatable. 0x Settler is already deployed on HyperEVM and uses the
    ///  canonical addresses in Constants.ZERO_EX_ALLOWANCE_HOLDER / Constants.ZERO_EX_DEPLOYER.
    function _assertNoExternalProtocolsOnHyperEVM() private pure {
        require(Constants.HYPER_UNISWAP_V4_POSM == address(0), "HyperEVM fixture assumes no Uniswap V4 POSM");
        require(Constants.HYPER_UNIVERSAL_ROUTER == address(0), "HyperEVM fixture assumes no Universal Router");
    }

    /// @notice Uses live Authority/Registry/Factory when available, otherwise deploys a local copy.
    function _setupInfrastructure() private {
        if (Constants.AUTHORITY.code.length > 0 && Constants.FACTORY.code.length > 0) {
            authority = Constants.AUTHORITY;
            factory = Constants.FACTORY;
            registry = IRigoblockPoolProxyFactory(factory).getRegistry();
            usingLiveInfrastructure = true;
            console2.log("Using live HyperEVM infrastructure");
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

        console2.log("Deployed local HyperEVM infrastructure");
        console2.log("Authority:", authority);
        console2.log("Registry:", registry);
        console2.log("Factory:", factory);
    }

    function _deployExtensionsAndImplementation() private {
        // HyperEVM has no Uniswap V4, GRG staking, or BackGeoOracle deployments at fixture time;
        // zero addresses are passed for those dependencies.
        address grgStakingProxy = address(0);
        address univ4Posm = address(0);

        // EOracle is required by ExtensionsMap but has no real oracle on HyperEVM. It treats USDC as
        // having a price feed on HyperEVM because USDC is Hyperliquid's collateral/numeraire.
        address oracle = address(0);

        EApps eApps = new EApps(EAppsParams({grgStakingProxy: grgStakingProxy, univ4Posm: univ4Posm}));
        EOracle eOracle = new EOracle(oracle, HYPER_WHYPE);
        EUpgrade eUpgrade = new EUpgrade(factory);
        ECrosschain eCrosschain = new ECrosschain();
        ENavView eNavView = new ENavView(EAppsParams({grgStakingProxy: grgStakingProxy, univ4Posm: univ4Posm}));

        Extensions memory extensions = Extensions({
            eApps: address(eApps),
            eOracle: address(eOracle),
            eUpgrade: address(eUpgrade),
            eCrosschain: address(eCrosschain),
            eNavView: address(eNavView),
            eGmxCallback: address(0)
        });

        ExtensionsMapDeployer deployer = new ExtensionsMapDeployer();
        DeploymentParams memory params = DeploymentParams({extensions: extensions, wrappedNative: HYPER_WHYPE});
        bytes32 salt = keccak256(abi.encodePacked("HYPERLIQUID_TEST_EXTENSIONS_MAP", block.chainid));
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
        (pool, ) = IRigoblockPoolProxyFactory(factory).createPool("Hyperliquid Test", "HTEST", HYPER_USDC);
        console2.log("Pool:", pool);
    }

    function _deployAndAuthorizeAdapter() private {
        aHyperliquid = address(new AHyperliquid());

        address authorityOwner = IOwnedUninitialized(authority).owner();
        vm.startPrank(authorityOwner);

        IAuthority(authority).setAdapter(aHyperliquid, true);
        _addOrReplaceMethod(ICoreDepositWallet.deposit.selector, aHyperliquid);
        _addOrReplaceMethod(ICoreDepositWallet.depositFor.selector, aHyperliquid);
        _addOrReplaceMethod(ICoreWriter.sendRawAction.selector, aHyperliquid);

        vm.stopPrank();

        console2.log("AHyperliquid authorized");
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
        // Give user and pool plenty of real HyperEVM USDC.
        deal(HYPER_USDC, user, 1_000_000e6);
        deal(HYPER_USDC, pool, 1_000_000e6);

        // Mint pool tokens to the pool itself so it has non-zero supply and NAV for deposit tests.
        vm.startPrank(user);
        HYPER_USDC.safeApprove(pool, type(uint256).max);
        uint256 mintAmount = 100_000e6;
        ISmartPool(payable(pool)).mint(user, mintAmount, 0);
        vm.stopPrank();

        console2.log("Minted pool tokens:", mintAmount);
    }

    /// @notice Returns the HyperEVM USDC balance of the given account.
    function usdcBalance(address account) public view returns (uint256) {
        return IERC20(HYPER_USDC).balanceOf(account);
    }
}
