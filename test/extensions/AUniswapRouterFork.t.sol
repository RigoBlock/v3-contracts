// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Constants} from "../../contracts/test/Constants.sol";

import {EApps} from "../../contracts/protocol/extensions/EApps.sol";
import {ECrosschain} from "../../contracts/protocol/extensions/ECrosschain.sol";
import {EERC20} from "../../contracts/protocol/extensions/EERC20.sol";
import {ENavView} from "../../contracts/protocol/extensions/ENavView.sol";
import {EOracle} from "../../contracts/protocol/extensions/EOracle.sol";
import {EUpgrade} from "../../contracts/protocol/extensions/EUpgrade.sol";
import {SmartPool} from "../../contracts/protocol/SmartPool.sol";
import {ExtensionsMapDeployer} from "../../contracts/protocol/deps/ExtensionsMapDeployer.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {IAuthority} from "../../contracts/protocol/interfaces/IAuthority.sol";
import {IOwnedUninitialized} from "../../contracts/utils/owned/IOwnedUninitialized.sol";
import {IPoolRegistry} from "../../contracts/protocol/interfaces/IPoolRegistry.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {IAUniswapRouter} from "../../contracts/protocol/extensions/adapters/interfaces/IAUniswapRouter.sol";
import {IEApps} from "../../contracts/protocol/extensions/adapters/interfaces/IEApps.sol";

import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {AUniswapDecoder} from "../../contracts/protocol/extensions/adapters/AUniswapDecoder.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {DeploymentParams, Extensions, EAppsParams} from "../../contracts/protocol/types/DeploymentParams.sol";

/// @dev Selector-only views of the two overloaded `execute` methods declared on the
/// canonical `IUniversalRouter` (vendored in lib/universal-router, mirrored in node_modules).
/// Solidity cannot apply `.selector` to an overloaded member (`abi.encodeCall` cannot
/// disambiguate interface members either), so each overload needs a single-function view;
/// the adapter resolves its own selectors the same way (local view in AUniswapRouter.sol).
interface IUniversalRouterExecuteDeadline {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IUniversalRouterExecutePlain {
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable;
}

/// @title AUniswapRouterForkTest
/// @notice Fork tests asserting Uni V4 position tracking events emitted by the pool proxy.
contract AUniswapRouterForkTest is Test {
    address private constant AUTHORITY = Constants.AUTHORITY;
    address private constant FACTORY = Constants.FACTORY;
    address private constant TOKEN_JAR = Constants.TOKEN_JAR;
    address private constant WETH = Constants.ARB_WETH;
    address private constant USDC = Constants.ARB_USDC;
    address private constant ORACLE = Constants.ARB_ORACLE;
    address private constant POSM = Constants.ARB_UNISWAP_V4_POSM;
    address private constant UNIVERSAL_ROUTER = Constants.ARB_UNIVERSAL_ROUTER;

    address private poolOwner;
    address private pool;

    function setUp() public {
        vm.createSelectFork("arbitrum", Constants.ARB_BLOCK);

        poolOwner = makeAddr("poolOwner");

        // AUniswapRouter is pinned to solc 0.8.37 while fork tests stay on 0.8.28; forge
        // compiles it in its own job and we deploy the artifact (deployCode), keeping the
        // test's compilation job free of the router source. Same pattern as AStaking below.
        address aUniswapRouter = deployCode(
            "out/AUniswapRouter.sol/AUniswapRouter.json",
            abi.encode(UNIVERSAL_ROUTER, POSM, WETH)
        );

        EApps eApps = new EApps(EAppsParams({grgStakingProxy: Constants.ARB_GRG_STAKING, univ4Posm: POSM}));
        EOracle eOracle = new EOracle(ORACLE, WETH);
        EUpgrade eUpgrade = new EUpgrade(FACTORY);
        ENavView eNavView = new ENavView(EAppsParams({grgStakingProxy: Constants.ARB_GRG_STAKING, univ4Posm: POSM}));
        ECrosschain eCrosschain = new ECrosschain();

        ExtensionsMapDeployer mapDeployer = new ExtensionsMapDeployer();
        DeploymentParams memory params = DeploymentParams({
            extensions: Extensions({
                eApps: address(eApps),
                eOracle: address(eOracle),
                eUpgrade: address(eUpgrade),
                eNavView: address(eNavView),
                eCrosschain: address(eCrosschain),
                eGmxCallback: address(0),
                eErc20: address(new EERC20())
            }),
            wrappedNative: WETH
        });
        bytes32 salt = keccak256(abi.encodePacked("AUNISWAP_ROUTER_FORK_TEST", block.chainid));
        address extensionsMapAddr = mapDeployer.deployExtensionsMap(params, salt);

        SmartPool impl = new SmartPool(AUTHORITY, extensionsMapAddr, TOKEN_JAR);

        address registry = IRigoblockPoolProxyFactory(FACTORY).getRegistry();
        address rigoblockDao = IPoolRegistry(registry).rigoblockDao();
        vm.prank(rigoblockDao);
        IRigoblockPoolProxyFactory(FACTORY).setImplementation(address(impl));

        vm.prank(poolOwner);
        (pool, ) = IRigoblockPoolProxyFactory(FACTORY).createPool("UniRouterEventPool", "UREP", WETH);

        address authorityOwner = IOwnedUninitialized(AUTHORITY).owner();
        vm.startPrank(authorityOwner);
        IAuthority(AUTHORITY).setAdapter(aUniswapRouter, true);
        if (!IAuthority(AUTHORITY).isWhitelister(authorityOwner)) {
            IAuthority(AUTHORITY).setWhitelister(authorityOwner, true);
        }
        // The production Authority maps these selectors to the previously deployed adapter;
        // repoint them at the adapter under test, otherwise pool calls would delegatecall
        // stale production code.
        _repointMethod(IAUniswapRouter.modifyLiquidities.selector, aUniswapRouter);
        _repointMethod(IUniversalRouterExecuteDeadline.execute.selector, aUniswapRouter);
        _repointMethod(IUniversalRouterExecutePlain.execute.selector, aUniswapRouter);
        vm.stopPrank();

        deal(WETH, poolOwner, 1 ether);
        deal(USDC, poolOwner, 10_000e6);
        vm.startPrank(poolOwner);
        IERC20(WETH).approve(pool, 1 ether);
        IERC20(USDC).approve(pool, 10_000e6);
        ISmartPoolActions(pool).mint(poolOwner, 1 ether, 0);
        vm.stopPrank();

        // Fund the pool with USDC for the Uni V4 LP position.
        deal(USDC, pool, 10_000e6);
    }

    /// @notice Minting a new Uni V4 LP position emits UniV4PositionAdded on the pool proxy.
    function test_ModifyLiquidities_Mint_EmitsPositionAdded() public {
        uint256 tokenId = _mintUniV4Position();

        uint256[] memory tokenIds = IEApps(pool).getUniV4TokenIds();
        assertEq(tokenIds.length, 1, "pool must track one position");
        assertEq(tokenIds[0], tokenId, "tracked tokenId must match");
    }

    /// @notice Burning a tracked Uni V4 LP position emits UniV4PositionRemoved on the pool proxy.
    function test_ModifyLiquidities_Burn_EmitsPositionRemoved() public {
        uint256 tokenId = _mintUniV4Position();

        vm.expectEmit(address(pool));
        emit IAUniswapRouter.UniV4PositionRemoved(tokenId);

        _burnUniV4Position(tokenId);

        uint256[] memory tokenIds = IEApps(pool).getUniV4TokenIds();
        assertEq(tokenIds.length, 0, "pool must track no positions after burn");
    }

    /// @notice The Across V4 deposit command (0x40, reserved in UR 2.1.2) is intentionally
    ///         unsupported: Across can move tokens and Permit2 is approved to the router, so
    ///         forwarding an undecoded 0x40 would be a fund-exfiltration path. Documented in
    ///         docs/uniswap/KNOWN_ISSUES.md.
    function test_Execute_AcrossV4DepositV3Command_Reverts() public {
        bytes memory commands = hex"40";
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = hex"";
        vm.prank(poolOwner);
        vm.expectRevert(abi.encodeWithSelector(AUniswapDecoder.InvalidCommandType.selector, uint256(0x40)));
        IAUniswapRouter(pool).execute(commands, inputs, block.timestamp + 1000);
    }

    /// @notice Same fail-closed guarantee for 0x40 with the allow-revert flag set (0xc0):
    ///         the mask strips the flag and the command still reverts at decode time.
    function test_Execute_AcrossV4DepositV3Command_AllowRevertFlag_Reverts() public {
        bytes memory commands = hex"c0";
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = hex"";
        vm.prank(poolOwner);
        vm.expectRevert(abi.encodeWithSelector(AUniswapDecoder.InvalidCommandType.selector, uint256(0x40)));
        IAUniswapRouter(pool).execute(commands, inputs, block.timestamp + 1000);
    }

    /// @notice V4_SWAP actions below SETTLE that are not one of the four swap types revert
    ///         UnsupportedAction at decode time instead of being silently skipped.
    function test_Execute_V4Swap_UnknownActionBelowSettle_Reverts() public {
        bytes memory commands = hex"10"; // V4_SWAP
        bytes[] memory encodedParams = new bytes[](1);
        encodedParams[0] = hex"";
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(hex"02", encodedParams); // action 0x02 < SETTLE, not a swap type
        vm.prank(poolOwner);
        vm.expectRevert(abi.encodeWithSelector(AUniswapDecoder.UnsupportedAction.selector, uint256(0x02)));
        IAUniswapRouter(pool).execute(commands, inputs, block.timestamp + 1000);
    }

    /// @notice PAY_PORTION_FULL_PRECISION (0x07, UR 2.1.2) to the pool: a V3 swap whose output
    ///         stays on the router, a 50% portion payment back to the pool, then a trailing
    ///         SWEEP that clears the router. Positive path against the live 2.1.2 router.
    function test_Execute_PayPortionFullPrecision_ToPool_Succeeds() public {
        uint256 poolUsdcBefore = IERC20(USDC).balanceOf(pool);

        bytes memory path = abi.encodePacked(WETH, uint24(500), USDC);
        bytes memory commands = hex"000704"; // V3_SWAP_EXACT_IN, PAY_PORTION_FULL_PRECISION, SWEEP
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = abi.encode(
            address(0x0000000000000000000000000000000000000002), // ADDRESS_THIS: swap output stays on the router
            0.1 ether,
            0,
            path,
            true, // payerIsUser: router pulls WETH from the pool via Permit2
            new uint256[](0) // minHopPriceX36 (UR 2.1.2 field, empty = no per-hop bound)
        );
        inputs[1] = abi.encode(USDC, pool, 0.5e18); // 50% of router USDC balance to the pool
        inputs[2] = abi.encode(USDC, pool, uint160(1)); // sweep the remainder to the pool

        vm.prank(poolOwner);
        IAUniswapRouter(pool).execute(commands, inputs, block.timestamp + 1000);

        assertGt(IERC20(USDC).balanceOf(pool), poolUsdcBefore, "pool must receive the USDC portion");
        assertEq(IERC20(USDC).balanceOf(UNIVERSAL_ROUTER), 0, "trailing SWEEP must clear the router");
    }

    /// @notice PAY_PORTION_FULL_PRECISION to a third-party recipient reverts at decode time,
    ///         before the Universal Router is called.
    function test_Execute_PayPortionFullPrecision_ToRandomRecipient_Reverts() public {
        address attacker = makeAddr("attacker");
        bytes memory commands = hex"07";
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(USDC, attacker, 1e18);
        vm.prank(poolOwner);
        vm.expectRevert(IAUniswapRouter.RecipientNotSmartPoolOrRouter.selector);
        IAUniswapRouter(pool).execute(commands, inputs, block.timestamp + 1000);
    }

    /// @notice Minting multiple positions in a single call emits one event per added tokenId.
    function test_ModifyLiquidities_MintMultiple_EmitsPositionAddedForEach() public {
        PoolKey memory poolKey = _uniV4PoolKey();

        // Initialize the pool if it does not already exist.
        IPositionManager(POSM).initializePool(poolKey, uint160(4_339_505_179_874_779_475_002_393));

        int24 tickLower = -887220;
        int24 tickUpper = 887220;
        uint256 liquidity = 1e13;
        uint128 amount0Max = type(uint128).max;
        uint128 amount1Max = type(uint128).max;
        bytes memory hookData = "";

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(poolKey, tickLower, tickUpper - 60, liquidity, amount0Max, amount1Max, pool, hookData);
        params[1] = abi.encode(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, pool, hookData);
        params[2] = abi.encode(poolKey.currency0, poolKey.currency1);
        bytes memory unlockData = abi.encode(actions, params);

        uint256 nextTokenId = IPositionManager(POSM).nextTokenId();

        vm.expectEmit(address(pool));
        emit IAUniswapRouter.UniV4PositionAdded(nextTokenId);
        vm.expectEmit(address(pool));
        emit IAUniswapRouter.UniV4PositionAdded(nextTokenId + 1);

        vm.prank(poolOwner);
        IAUniswapRouter(pool).modifyLiquidities(unlockData, block.timestamp + 1 hours);

        uint256[] memory tokenIds = IEApps(pool).getUniV4TokenIds();
        assertEq(tokenIds.length, 2, "pool must track two positions");
    }

    function _mintUniV4Position() private returns (uint256 tokenId) {
        PoolKey memory poolKey = _uniV4PoolKey();

        // Initialize the pool at ~3000 USDC/WETH if it does not already exist.
        IPositionManager(POSM).initializePool(poolKey, uint160(4_339_505_179_874_779_475_002_393));

        tokenId = IPositionManager(POSM).nextTokenId();

        int24 tickLower = -887220;
        int24 tickUpper = 887220;
        uint256 liquidity = 1e13;
        uint128 amount0Max = type(uint128).max;
        uint128 amount1Max = type(uint128).max;
        bytes memory hookData = "";

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, pool, hookData);
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        bytes memory unlockData = abi.encode(actions, params);

        vm.expectEmit(address(pool));
        emit IAUniswapRouter.UniV4PositionAdded(tokenId);

        vm.prank(poolOwner);
        IAUniswapRouter(pool).modifyLiquidities(unlockData, block.timestamp + 1 hours);
    }

    function _burnUniV4Position(uint256 tokenId) private {
        PoolKey memory poolKey = _uniV4PoolKey();

        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), "");
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, pool);
        bytes memory unlockData = abi.encode(actions, params);

        vm.prank(poolOwner);
        IAUniswapRouter(pool).modifyLiquidities(unlockData, block.timestamp + 1 hours);
    }

    function _uniV4PoolKey() private pure returns (PoolKey memory) {
        return
            PoolKey({
                currency0: Currency.wrap(WETH),
                currency1: Currency.wrap(USDC),
                fee: 0,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            });
    }

    function _repointMethod(bytes4 selector, address adapter) private {
        IAuthority authority = IAuthority(AUTHORITY);
        address current = authority.getApplicationAdapter(selector);
        if (current != address(0)) {
            authority.removeMethod(selector, current);
        }
        authority.addMethod(selector, adapter);
    }
}
