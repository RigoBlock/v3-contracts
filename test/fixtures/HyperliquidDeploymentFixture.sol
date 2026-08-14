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
import {AHyperliquid} from "../../contracts/protocol/extensions/adapters/AHyperliquid.sol";
import {IAHyperliquid} from "../../contracts/protocol/extensions/adapters/interfaces/IAHyperliquid.sol";
import {ICoreWriter} from "hyper-evm-lib/interfaces/ICoreWriter.sol";
import {ICoreDepositWallet} from "hyper-evm-lib/interfaces/ICoreDepositWallet.sol";
import {IAuthority} from "../../contracts/protocol/interfaces/IAuthority.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {ISmartPool} from "../../contracts/protocol/ISmartPool.sol";
import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {DeploymentParams, Extensions, EAppsParams} from "../../contracts/protocol/types/DeploymentParams.sol";
import {SafeTransferLib} from "../../contracts/protocol/libraries/SafeTransferLib.sol";

/// @title HyperliquidDeploymentFixture
/// @notice Deploys real Rigoblock infrastructure on a HyperEVM fork for Hyperliquid integration tests.
/// @dev Uses a dummy EOracle because Uniswap V4 is not deployed on HyperEVM; the pool is restricted to
///  USDC-denominated assets by the Hyperliquid base-token carve-out in MixinPoolValue.
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

        _deployInfrastructure();
        _deployExtensionsAndImplementation();
        _createPool();
        _deployAndAuthorizeAdapter();
        _fundPool();

        console2.log("=== Hyperliquid HyperEVM Fixture Complete ===");
        console2.log("Pool:", pool);
        console2.log("AHyperliquid:", aHyperliquid);
    }

    function _deployInfrastructure() private {
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

        console2.log("Authority:", authority);
        console2.log("Registry:", registry);
        console2.log("Factory:", factory);
    }

    function _deployExtensionsAndImplementation() private {
        // HyperEVM has no Uniswap V4 or GRG staking; pass zero addresses for those dependencies.
        address grgStakingProxy = address(0);
        address univ4Posm = address(0);

        // Dummy oracle hook: EOracle is never queried for USDC on HyperEVM thanks to the carve-out,
        // but it is still deployed to satisfy the ExtensionsMap constructor.
        address dummyOracle = address(0x2);

        EApps eApps = new EApps(EAppsParams({grgStakingProxy: grgStakingProxy, univ4Posm: univ4Posm}));
        EOracle eOracle = new EOracle(dummyOracle, HYPER_WHYPE);
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

        IRigoblockPoolProxyFactory(factory).setImplementation(implementation);

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

        IAuthority(authority).setAdapter(aHyperliquid, true);
        _addOrReplaceMethod(ICoreDepositWallet.deposit.selector, aHyperliquid);
        _addOrReplaceMethod(ICoreDepositWallet.depositFor.selector, aHyperliquid);
        _addOrReplaceMethod(ICoreWriter.sendRawAction.selector, aHyperliquid);

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
