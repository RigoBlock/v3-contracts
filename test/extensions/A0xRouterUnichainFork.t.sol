// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Constants} from "../../contracts/test/Constants.sol";

import {A0xRouter} from "../../contracts/protocol/extensions/adapters/A0xRouter.sol";
import {IA0xRouter} from "../../contracts/protocol/extensions/adapters/interfaces/IA0xRouter.sol";
import {SmartPool} from "../../contracts/protocol/SmartPool.sol";

import {ExtensionsMapDeployer} from "../../contracts/protocol/deps/ExtensionsMapDeployer.sol";
import {EApps} from "../../contracts/protocol/extensions/EApps.sol";
import {EOracle} from "../../contracts/protocol/extensions/EOracle.sol";
import {EUpgrade} from "../../contracts/protocol/extensions/EUpgrade.sol";
import {ECrosschain} from "../../contracts/protocol/extensions/ECrosschain.sol";
import {ENavView} from "../../contracts/protocol/extensions/ENavView.sol";
import {EnumerableSet} from "../../contracts/protocol/libraries/EnumerableSet.sol";

import {IAuthority} from "../../contracts/protocol/interfaces/IAuthority.sol";
import {IOwnedUninitialized} from "../../contracts/utils/owned/IOwnedUninitialized.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {IPoolRegistry} from "../../contracts/protocol/interfaces/IPoolRegistry.sol";
import {IEUpgrade} from "../../contracts/protocol/extensions/adapters/interfaces/IEUpgrade.sol";
import {Extensions, DeploymentParams} from "../../contracts/protocol/types/DeploymentParams.sol";

import {ISettlerActions} from "0x-settler/src/ISettlerActions.sol";
import {IAllowanceHolder} from "0x-settler/src/allowanceholder/IAllowanceHolder.sol";
import {ISettlerTakerSubmitted} from "0x-settler/src/interfaces/ISettlerTakerSubmitted.sol";
import {IDeployer} from "0x-settler/src/deployer/IDeployer.sol";
import {Feature} from "0x-settler/src/deployer/Feature.sol";

/// @title A0xRouterUnichainForkTest - Replay EXACT production calldata from 3 failing Unichain transactions.
/// @notice The settler calldata is loaded from hex fixtures extracted directly from the on-chain
///  transaction input data. No synthetic approximations — these are the literal bytes that reverted.
/// @dev Transaction hashes (all reverted on Unichain mainnet):
///  TX1 (ETH→GRG, block 41291308): 0xcd79b65d962440ec31a4d7c70c2fd06ffe750c10ec460cf9f066310bb80fc08a
///    Root cause: ActionNotAllowed(0x38c9c147) — BASIC action was not in the allowlist.
///    Actions: NATIVE_CHECK, BASIC(fee), BASIC(WETH.deposit), BASIC(WETH.withdraw), UNISWAPV4, POSITIVE_SLIPPAGE
///  TX2 (GRG→ETH, block 41298720): 0x0d06b5b99bcedfbd1182e48c26c94dbad972ecf221deb64b28722e21fd93f27a
///    Root cause: TokenPriceFeedDoesNotExist(0xEeee...) — ETH sentinel had no price feed mapping.
///    Actions: TRANSFER_FROM, UNISWAPV4, BASIC(WETH.deposit), BASIC(WETH.withdraw), POSITIVE_SLIPPAGE, BASIC(fee)
///  TX3 (GRG→USDC, block 41298808): 0x87b1059a15167b463a84885821c1bffc2076240a319a5f6bc3d5c88532fd427d
///    Root cause: ActionNotAllowed(0x38c9c147) — BASIC action was not in the allowlist.
///    Actions: TRANSFER_FROM, UNISWAPV4, BASIC(WETH.deposit), UNISWAPV3, POSITIVE_SLIPPAGE, BASIC(fee+transfer)
contract A0xRouterUnichainForkTest is Test {
    // 0x infrastructure (same addresses on all chains)
    address constant ALLOWANCE_HOLDER = Constants.ZERO_EX_ALLOWANCE_HOLDER;
    address constant DEPLOYER = Constants.ZERO_EX_DEPLOYER;

    // Rigoblock infrastructure (same across chains)
    address constant AUTHORITY = Constants.AUTHORITY;
    address constant FACTORY = Constants.FACTORY;

    Feature constant TAKER_SUBMITTED_FEATURE = Feature.wrap(2);

    bytes4 constant EXEC_SELECTOR = IAllowanceHolder.exec.selector;

    uint256 unichainFork;
    A0xRouter a0xRouter;
    address pool;
    address poolOwner;
    address currentSettler;

    /// @dev The production pool on Unichain that the failing txs targeted.
    address constant PROD_POOL = Constants.TEST_POOL;

    /// @dev The caller in the production txs.
    address constant PROD_CALLER = 0xcA9F5049c1Ea8FC78574f94B7Cf5bE5fEE354C31;

    /// @dev The settler used as both operator and target in all 3 production txs.
    address constant PROD_SETTLER = 0x6A7dd96F25E70eD5F6beF1ACADd32b697935ff39;

    /// @dev GRG token on Unichain (sellToken in TX2, TX3; buyToken in TX1).
    address constant UNI_GRG = 0x03C2868c6D7fD27575426f395EE081498B1120dd;

    function setUp() public {
        // Fork BEFORE the earliest failing tx (TX1 at block 41291308)
        unichainFork = vm.createSelectFork("unichain", Constants.UNICHAIN_BLOCK);

        // Verify 0x infrastructure
        assertTrue(ALLOWANCE_HOLDER.code.length > 0, "AllowanceHolder not deployed");
        assertTrue(DEPLOYER.code.length > 0, "Deployer not deployed");

        currentSettler = IDeployer(DEPLOYER).ownerOf(Feature.unwrap(TAKER_SUBMITTED_FEATURE));
        assertTrue(currentSettler != address(0), "No settler");
        console2.log("Settler:", currentSettler);

        // Verify the production settler is genuine at this block
        assertEq(currentSettler, PROD_SETTLER, "Settler mismatch at fork block");

        // Deploy fixed adapter
        a0xRouter = new A0xRouter(ALLOWANCE_HOLDER, DEPLOYER);

        // Upgrade the production pool to use the fixed adapter
        _setupProdPool();
    }

    /*//////////////////////////////////////////////////////////////////////////
                    EXACT PRODUCTION CALLDATA REPLAY

    Each test loads the literal settler calldata bytes extracted from the failing
    on-chain transaction. The adapter's validation (settler check, recipient check,
    price feed check, action allowlist) runs against the REAL bytes.

    The swap itself will fail (stale quote, expired deadline) but we verify the
    error is NOT from our adapter's validation layer.
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Replay exact TX1 calldata: ETH→GRG swap (0xcd79b65d, block 41291308).
    ///  operator=settler, token=address(0), amount=0.001 ETH, target=settler.
    ///  Original error: ActionNotAllowed(BASIC) — now BASIC is in allowlist.
    function test_ReplayExact_TX1_ETHToGRG() public {
        // Fund pool with ETH (the pool is the vault — adapter derives value from params)
        deal(pool, 10 ether);

        // Load EXACT settler calldata from production TX1
        bytes memory settlerData = vm.parseBytes(vm.readFile("test/fixtures/unichain/TX1_ETHtoToken_settler.hex"));
        assertTrue(settlerData.length > 0, "Failed to load TX1 settler data");
        console2.log("TX1 settler data length:", settlerData.length);

        // Verify settler selector
        bytes4 sel;
        assembly {
            sel := mload(add(settlerData, 32))
        }
        assertEq(sel, ISettlerTakerSubmitted.execute.selector, "Wrong settler selector");

        // Call with EXACT production params: exec(settler, address(0), 0.001 ETH, settler, settlerData)
        vm.prank(poolOwner);
        try IA0xRouter(pool).exec(
            PROD_SETTLER, // operator (same as production)
            address(0), // token = native ETH (same as production)
            0.001 ether, // amount = 1000000000000000 (same as production)
            payable(PROD_SETTLER), // target (same as production)
            settlerData // EXACT production settler bytes
        ) {
            console2.log("TX1: swap succeeded (unexpected but fine)");
        } catch (bytes memory returnData) {
            _assertNotAdapterValidationError(returnData);
            _logExternalError("TX1", returnData);
        }
    }

    /// @notice Replay exact TX2 calldata: GRG→ETH swap (0x0d06b5b9, block 41298720).
    ///  operator=settler, token=GRG, amount=50e18, target=settler.
    ///  Original error: TokenPriceFeedDoesNotExist(0xEeee...) — now ETH sentinel maps to address(0).
    function test_ReplayExact_TX2_GRGToETH() public {
        // Fund pool with GRG sell token
        deal(UNI_GRG, pool, 100e18);

        // Load EXACT settler calldata from production TX2
        bytes memory settlerData = vm.parseBytes(vm.readFile("test/fixtures/unichain/TX2_TokenToETH_settler.hex"));
        assertTrue(settlerData.length > 0, "Failed to load TX2 settler data");
        console2.log("TX2 settler data length:", settlerData.length);

        // Call with EXACT production params
        vm.prank(poolOwner);
        try IA0xRouter(pool).exec(
            PROD_SETTLER, // operator
            UNI_GRG, // token = GRG (0x03C2868c...)
            50e18, // amount = 50000000000000000000
            payable(PROD_SETTLER), // target
            settlerData // EXACT production settler bytes
        ) {
            console2.log("TX2: swap succeeded (unexpected but fine)");
        } catch (bytes memory returnData) {
            _assertNotAdapterValidationError(returnData);
            _logExternalError("TX2", returnData);
        }
    }

    /// @notice Replay exact TX3 calldata: GRG→USDC swap (0x87b1059a, block 41298808).
    ///  operator=settler, token=GRG, amount=50e18, target=settler.
    ///  buyToken=0x078d782b760474a361dda0af3839290b0ef57ad6 (USDC on Unichain).
    ///  Original error: ActionNotAllowed(BASIC) — now BASIC is in allowlist.
    function test_ReplayExact_TX3_GRGToUSDC() public {
        // Fund pool with GRG sell token
        deal(UNI_GRG, pool, 100e18);

        // Load EXACT settler calldata from production TX3
        bytes memory settlerData = vm.parseBytes(vm.readFile("test/fixtures/unichain/TX3_TokenToToken_settler.hex"));
        assertTrue(settlerData.length > 0, "Failed to load TX3 settler data");
        console2.log("TX3 settler data length:", settlerData.length);

        // Call with EXACT production params
        vm.prank(poolOwner);
        try IA0xRouter(pool).exec(
            PROD_SETTLER, // operator
            UNI_GRG, // token = GRG
            50e18, // amount
            payable(PROD_SETTLER), // target
            settlerData // EXACT production settler bytes
        ) {
            console2.log("TX3: swap succeeded (unexpected but fine)");
        } catch (bytes memory returnData) {
            _assertNotAdapterValidationError(returnData);
            _logExternalError("TX3", returnData);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                            UNIT VALIDATIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Verify the ETH sentinel (0xEeee...ee) maps to address(0) for price feed lookups.
    function test_ETHSentinel_HasPriceFeed() public {
        address ETH_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

        // Minimal settler calldata with ETH sentinel as buyToken
        bytes[] memory actions = new bytes[](0);
        bytes memory settlerData = abi.encodeWithSelector(
            ISettlerTakerSubmitted.execute.selector, pool, ETH_SENTINEL, uint256(1e15), actions, bytes32(0)
        );

        vm.mockCall(ALLOWANCE_HOLDER, abi.encodeWithSelector(EXEC_SELECTOR), abi.encode(bytes("")));

        vm.prank(poolOwner);
        IA0xRouter(pool).exec(currentSettler, Constants.UNI_USDC, 1000e6, payable(currentSettler), settlerData);
    }

    /// @notice Verify BASIC action passes validation.
    function test_BasicAction_PassesValidation() public {
        deal(Constants.UNI_USDC, pool, 10000e6);

        bytes memory basicAction = abi.encodePacked(
            ISettlerActions.BASIC.selector,
            abi.encode(
                Constants.UNI_USDC, uint256(10000), Constants.UNI_WETH, uint256(4), abi.encodeWithSignature("deposit()")
            )
        );

        bytes[] memory actions = new bytes[](1);
        actions[0] = basicAction;

        bytes memory settlerData = abi.encodeWithSelector(
            ISettlerTakerSubmitted.execute.selector, pool, Constants.UNI_WETH, uint256(1e15), actions, bytes32(0)
        );

        vm.prank(poolOwner);
        try IA0xRouter(pool).exec(
            currentSettler, Constants.UNI_USDC, 1000e6, payable(currentSettler), settlerData
        ) {
            revert("Should fail inside settler");
        } catch (bytes memory returnData) {
            _assertNotAdapterValidationError(returnData);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Asserts the revert error is NOT from our adapter's validation layer.
    ///  Any error from AllowanceHolder, settler, or downstream DEX is acceptable.
    function _assertNotAdapterValidationError(bytes memory returnData) internal pure {
        if (returnData.length >= 4) {
            bytes4 errorSelector;
            assembly {
                errorSelector := mload(add(returnData, 32))
            }
            assertTrue(errorSelector != IA0xRouter.CounterfeitSettler.selector, "Blocked by: CounterfeitSettler");
            assertTrue(
                errorSelector != IA0xRouter.RecipientNotSmartPool.selector, "Blocked by: RecipientNotSmartPool"
            );
            assertTrue(
                errorSelector != IA0xRouter.UnsupportedSettlerFunction.selector,
                "Blocked by: UnsupportedSettlerFunction"
            );
            assertTrue(
                errorSelector != IA0xRouter.InvalidSettlerCalldata.selector, "Blocked by: InvalidSettlerCalldata"
            );
            assertTrue(
                errorSelector != IA0xRouter.DirectCallNotAllowed.selector, "Blocked by: DirectCallNotAllowed"
            );
            assertTrue(errorSelector != IA0xRouter.ActionNotAllowed.selector, "Blocked by: ActionNotAllowed");
            assertTrue(
                errorSelector != EnumerableSet.TokenPriceFeedDoesNotExist.selector,
                "Blocked by: TokenPriceFeedDoesNotExist"
            );
        }
    }

    /// @dev Logs the external error for debugging (selector + data length).
    function _logExternalError(string memory txLabel, bytes memory returnData) internal pure {
        if (returnData.length >= 4) {
            bytes4 errorSelector;
            assembly {
                errorSelector := mload(add(returnData, 32))
            }
            console2.log(string.concat(txLabel, ": external error selector:"));
            console2.logBytes4(errorSelector);
            console2.log(string.concat(txLabel, ": error data length:"), returnData.length);
        } else {
            console2.log(string.concat(txLabel, ": empty revert (", vm.toString(returnData.length), " bytes)"));
        }
    }

    /// @dev Deploy the fixed adapter and register it with the production pool's Authority.
    function _setupProdPool() private {
        pool = PROD_POOL;

        // Deploy new extensions with Unichain-specific addresses
        EApps eApps = new EApps(address(0), address(0));
        EOracle eOracle = new EOracle(Constants.UNI_ORACLE, Constants.UNI_WETH);
        EUpgrade eUpgrade = new EUpgrade(FACTORY);
        ENavView eNavView = new ENavView(address(0), address(0));
        ECrosschain eCrosschain = new ECrosschain();

        Extensions memory extensions = Extensions({
            eApps: address(eApps),
            eOracle: address(eOracle),
            eUpgrade: address(eUpgrade),
            eNavView: address(eNavView),
            eCrosschain: address(eCrosschain)
        });

        ExtensionsMapDeployer mapDeployer = new ExtensionsMapDeployer();
        DeploymentParams memory params = DeploymentParams({extensions: extensions, wrappedNative: Constants.UNI_WETH});
        bytes32 salt = keccak256(abi.encodePacked("A0X_UNI_FORK_TEST", block.chainid));
        address extensionsMapAddr = mapDeployer.deployExtensionsMap(params, salt);

        // Deploy new implementation
        SmartPool impl = new SmartPool(AUTHORITY, extensionsMapAddr, Constants.TOKEN_JAR);

        // Upgrade factory implementation
        address registry = IRigoblockPoolProxyFactory(FACTORY).getRegistry();
        address rigoblockDao = IPoolRegistry(registry).rigoblockDao();
        vm.prank(rigoblockDao);
        IRigoblockPoolProxyFactory(FACTORY).setImplementation(address(impl));

        // Upgrade the pool
        poolOwner = IOwnedUninitialized(pool).owner();
        vm.prank(poolOwner);
        IEUpgrade(pool).upgradeImplementation();

        // Register the fixed adapter
        address authorityOwner = IOwnedUninitialized(AUTHORITY).owner();
        vm.startPrank(authorityOwner);
        if (!IAuthority(AUTHORITY).isWhitelister(authorityOwner)) {
            IAuthority(AUTHORITY).setWhitelister(authorityOwner, true);
        }
        address oldAdapter = IAuthority(AUTHORITY).getApplicationAdapter(EXEC_SELECTOR);
        if (oldAdapter != address(0)) {
            IAuthority(AUTHORITY).removeMethod(EXEC_SELECTOR, oldAdapter);
            IAuthority(AUTHORITY).setAdapter(oldAdapter, false);
        }
        IAuthority(AUTHORITY).setAdapter(address(a0xRouter), true);
        IAuthority(AUTHORITY).addMethod(EXEC_SELECTOR, address(a0xRouter));
        vm.stopPrank();
    }
}
