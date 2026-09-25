// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {Test, console2} from "forge-std/Test.sol";

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
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {ISmartPoolOwnerActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolOwnerActions.sol";
import {IAUniswapRouter} from "../../contracts/protocol/extensions/adapters/interfaces/IAUniswapRouter.sol";
import {IAIntents} from "../../contracts/protocol/extensions/adapters/interfaces/IAIntents.sol";
import {IEApps} from "../../contracts/protocol/extensions/adapters/interfaces/IEApps.sol";
import {EnumerableSet} from "../../contracts/protocol/libraries/EnumerableSet.sol";
import {DeploymentParams, Extensions, EAppsParams} from "../../contracts/protocol/types/DeploymentParams.sol";

import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {PathKey} from "@uniswap/v4-periphery/src/libraries/PathKey.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

interface IPermit2Forwarder {
    function permit2() external view returns (IAllowanceTransfer);
}

/// @dev Re-declaration of Universal Router's V3SwapRouter.V3TooLittleReceived(), which the adapter
/// propagates raw. The upstream file (lib/universal-router/contracts/modules/uniswap/v3/V3SwapRouter.sol)
/// cannot be imported in this 0.8.28 test job: it pulls in the v3-core module, whose submodule is
/// not checked out under lib/universal-router/lib/.
error V3TooLittleReceived();

/// @title AUniswapRouterExecuteForkTest
/// @notice Fork migration of the `execute` block of test/extensions/AUniswapRouter.spec.ts (hardhat
///         mocks) against the real Universal Router 2.1.2, real V3/V2 pools and the real BackGeoOracle
///         on an Arbitrum fork. Mock-only assertions were ported to the closest real-contract
///         equivalent; adaptations are documented per test.
contract AUniswapRouterExecuteForkTest is Test {
    address private constant AUTHORITY = Constants.AUTHORITY;
    address private constant FACTORY = Constants.FACTORY;
    address private constant TOKEN_JAR = Constants.TOKEN_JAR;
    address private constant WETH = Constants.ARB_WETH;
    address private constant USDC = Constants.ARB_USDC;
    address private constant ORACLE = Constants.ARB_ORACLE;
    address private constant POSM = Constants.ARB_UNISWAP_V4_POSM;
    address private constant UNIVERSAL_ROUTER = Constants.ARB_UNIVERSAL_ROUTER;

    // Universal Router sentinel recipients (v4-periphery ActionConstants).
    address private constant MSG_SENDER = 0x0000000000000000000000000000000000000001;
    address private constant ADDRESS_THIS = 0x0000000000000000000000000000000000000002;

    // Command type bytes (test/shared/planner.ts CommandType).
    bytes1 private constant CMD_V3_SWAP_EXACT_IN = 0x00;
    bytes1 private constant CMD_V3_SWAP_EXACT_OUT = 0x01;
    bytes1 private constant CMD_SWEEP = 0x04;
    bytes1 private constant CMD_TRANSFER = 0x05;
    bytes1 private constant CMD_PAY_PORTION = 0x06;
    bytes1 private constant CMD_PAY_PORTION_FULL_PRECISION = 0x07;
    bytes1 private constant CMD_V2_SWAP_EXACT_IN = 0x08;
    bytes1 private constant CMD_V2_SWAP_EXACT_OUT = 0x09;
    bytes1 private constant CMD_WRAP_ETH = 0x0b;
    bytes1 private constant CMD_UNWRAP_WETH = 0x0c;
    bytes1 private constant CMD_BALANCE_CHECK_ERC20 = 0x0e;
    bytes1 private constant CMD_V4_SWAP = 0x10;
    bytes1 private constant CMD_EXECUTE_SUB_PLAN = 0x21;

    // sqrtPriceX96 of ~3000 USDC per ETH (same constant as AUniswapRouterFork.t.sol).
    uint160 private constant SQRT_PRICE_3000 = 4_339_505_179_874_779_475_002_393;

    address private poolOwner;
    address private pool;
    address private aUniswapRouter;
    address private permit2;

    function setUp() public {
        vm.createSelectFork("arbitrum", Constants.ARB_BLOCK);

        poolOwner = makeAddr("poolOwner");

        // AUniswapRouter is pinned to solc 0.8.37 while fork tests stay on 0.8.28; forge
        // compiles it in its own job and we deploy the artifact (deployCode), keeping the
        // test's compilation job free of the router source. Same pattern as AUniswapRouterFork.t.sol.
        aUniswapRouter = deployCode(
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
        bytes32 salt = keccak256(abi.encodePacked("AUNISWAP_ROUTER_EXECUTE_FORK_TEST", block.chainid));
        address extensionsMapAddr = mapDeployer.deployExtensionsMap(params, salt);

        SmartPool impl = new SmartPool(AUTHORITY, extensionsMapAddr, TOKEN_JAR);

        address registry = IRigoblockPoolProxyFactory(FACTORY).getRegistry();
        address rigoblockDao = IPoolRegistry(registry).rigoblockDao();
        vm.prank(rigoblockDao);
        IRigoblockPoolProxyFactory(FACTORY).setImplementation(address(impl));

        vm.prank(poolOwner);
        (pool, ) = IRigoblockPoolProxyFactory(FACTORY).createPool("UniRouterExecutePool", "UREP", WETH);

        address authorityOwner = IOwnedUninitialized(AUTHORITY).owner();
        vm.startPrank(authorityOwner);
        IAuthority(AUTHORITY).setAdapter(aUniswapRouter, true);
        if (!IAuthority(AUTHORITY).isWhitelister(authorityOwner)) {
            IAuthority(AUTHORITY).setWhitelister(authorityOwner, true);
        }
        // The production Authority maps these selectors to the previously deployed adapter;
        // repoint them at the adapter under test. `execute` is overloaded on IAUniswapRouter, so its
        // selectors are encoded manually (expected values per AUniswapRouter.spec.ts).
        _repointMethod(IAUniswapRouter.modifyLiquidities.selector, aUniswapRouter);
        _repointMethod(bytes4(keccak256("execute(bytes,bytes[],uint256)")), aUniswapRouter); // 0x3593564c
        _repointMethod(bytes4(keccak256("execute(bytes,bytes[])")), aUniswapRouter); // 0x24856bc3
        vm.stopPrank();

        permit2 = address(IPermit2Forwarder(POSM).permit2());

        deal(WETH, poolOwner, 1 ether);
        deal(USDC, poolOwner, 10_000e6);
        vm.startPrank(poolOwner);
        IERC20(WETH).approve(pool, 1 ether);
        IERC20(USDC).approve(pool, 10_000e6);
        ISmartPoolActions(pool).mint(poolOwner, 1 ether, 0);
        vm.stopPrank();

        // Fund the pool with USDC for swaps.
        deal(USDC, pool, 10_000e6);

        _seedEthUsdcPool();
    }

    /// @notice Migrated from "should execute a v4 swap". The mock swap succeeded without pool
    ///         balance; against the real PoolManager the ETH input must be settled, so the plan
    ///         adds SETTLE + TAKE and success is asserted via the pool's received USDC.
    function test_Execute_V4SwapExactInSingle_Native_Succeeds() public {
        uint256 amountIn = 0.1 ether;
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: _ethUsdcKey(),
                zeroForOne: true,
                amountIn: uint128(amountIn),
                amountOutMinimum: 100e6,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(Currency.wrap(address(0)), amountIn, true);
        params[2] = abi.encode(Currency.wrap(USDC), pool, uint256(0));
        (bytes memory commands, bytes[] memory inputs) = _v4Swap(
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE), uint8(Actions.TAKE)),
            params
        );

        vm.prank(poolOwner);
        vm.expectRevert(IAUniswapRouter.InsufficientNativeBalance.selector);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());

        deal(pool, 1 ether);
        uint256 usdcBefore = IERC20(USDC).balanceOf(pool);
        vm.prank(poolOwner);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());
        assertGt(IERC20(USDC).balanceOf(pool), usdcBefore, "pool must receive USDC");
        assertEq(UNIVERSAL_ROUTER.balance, 0, "router must not keep ETH");
    }

    /// @notice Migrated from "should revert if deadline past". 1:1.
    function test_Execute_DeadlinePast_Reverts() public {
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(Currency.wrap(USDC), pool, uint256(1));
        (bytes memory commands, bytes[] memory inputs) = _v4Swap(abi.encodePacked(uint8(Actions.TAKE)), params);

        vm.prank(poolOwner);
        vm.expectRevert(IAUniswapRouter.TransactionDeadlinePassed.selector);
        IAUniswapRouter(pool).execute(commands, inputs, block.timestamp - 1);
    }

    /// @notice Migrated from "should set approval with settle action". The mock test settled GRG;
    ///         GRG has no real v4 pool or price feed on Arbitrum, so USDC is settled instead. The
    ///         two-layer approval assertions are identical.
    function test_Execute_Settle_SetsPermit2Approvals() public {
        uint256 amountIn = 100e6;
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: _ethUsdcKey(),
                zeroForOne: false,
                amountIn: uint128(amountIn),
                amountOutMinimum: 0.01 ether,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(Currency.wrap(USDC), amountIn, true);
        params[2] = abi.encode(Currency.wrap(address(0)), pool, uint256(0));
        (bytes memory commands, bytes[] memory inputs) = _v4Swap(
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE), uint8(Actions.TAKE)),
            params
        );

        assertEq(IERC20(USDC).allowance(pool, permit2), 0, "pool must not have approved permit2 yet");

        vm.prank(poolOwner);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());

        // permit2 pulls tokens via ERC20 transferFrom, consuming the pool's allowance by the pulled amount
        assertEq(
            IERC20(USDC).allowance(pool, permit2),
            type(uint256).max - amountIn,
            "pool must hold (nearly) max erc20 approval to permit2"
        );
        (uint160 amount, uint48 expiration, uint48 nonce) = IAllowanceTransfer(permit2).allowance(
            pool,
            USDC,
            UNIVERSAL_ROUTER
        );
        assertEq(amount, type(uint160).max, "permit2 approval to universal router must be max uint160");
        assertEq(expiration, uint48(block.timestamp), "permit2 approval must expire within the block");
        assertEq(nonce, 0, "permit2 nonce must be 0");
    }

    /// @notice Migrated from "should transfer eth to universal router with exactInSingle". The mock
    ///         router kept the ETH, so balance was asserted; the real router settles the ETH into
    ///         the PoolManager, so success of the swap plus a cleared router balance is asserted.
    ///         A SETTLE action closes the native delta the mock ignored.
    function test_Execute_TransfersNative_ExactInSingle() public {
        uint256 amountIn = 0.1 ether;
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: _ethUsdcKey(),
                zeroForOne: true,
                amountIn: uint128(amountIn),
                amountOutMinimum: 100e6,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(Currency.wrap(address(0)), uint256(ActionConstants.OPEN_DELTA), false);
        params[2] = abi.encode(Currency.wrap(USDC), pool, uint256(0));
        (bytes memory commands, bytes[] memory inputs) = _v4Swap(
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE), uint8(Actions.TAKE)),
            params
        );

        vm.prank(poolOwner);
        vm.expectRevert(IAUniswapRouter.InsufficientNativeBalance.selector);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());

        deal(pool, 1 ether);
        uint256 usdcBefore = IERC20(USDC).balanceOf(pool);
        vm.prank(poolOwner);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());
        assertGt(IERC20(USDC).balanceOf(pool), usdcBefore, "pool must receive USDC");
        assertEq(UNIVERSAL_ROUTER.balance, 0, "router must not keep ETH");
    }

    /// @notice Migrated from "should transfer eth to universal router with exactIn" (multihop path).
    ///         Same adaptation as the exactInSingle variant.
    function test_Execute_TransfersNative_ExactIn() public {
        uint256 amountIn = 0.1 ether;
        PathKey[] memory path = new PathKey[](1);
        path[0] = _pathKey(USDC);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputParams({
                currencyIn: Currency.wrap(address(0)),
                path: path,
                minHopPriceX36: new uint256[](0),
                amountIn: uint128(amountIn),
                amountOutMinimum: 100e6
            })
        );
        params[1] = abi.encode(Currency.wrap(address(0)), uint256(ActionConstants.OPEN_DELTA), false);
        params[2] = abi.encode(Currency.wrap(USDC), pool, uint256(0));
        (bytes memory commands, bytes[] memory inputs) = _v4Swap(
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN), uint8(Actions.SETTLE), uint8(Actions.TAKE)),
            params
        );

        vm.prank(poolOwner);
        vm.expectRevert(IAUniswapRouter.InsufficientNativeBalance.selector);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());

        deal(pool, 1 ether);
        uint256 usdcBefore = IERC20(USDC).balanceOf(pool);
        vm.prank(poolOwner);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());
        assertGt(IERC20(USDC).balanceOf(pool), usdcBefore, "pool must receive USDC");
        assertEq(UNIVERSAL_ROUTER.balance, 0, "router must not keep ETH");
    }

    /// @notice Migrated from "should not transfer eth to universal router with exactIn when selling
    ///         token for native". The mock plan was deliberately unbalanced; on the real pool a
    ///         genuine USDC->ETH swap succeeds and the router must hold no ETH afterwards.
    function test_Execute_DoesNotTransferNative_ExactIn_TokenForNative() public {
        uint256 amountIn = 100e6;
        PathKey[] memory path = new PathKey[](1);
        path[0] = _pathKey(address(0));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputParams({
                currencyIn: Currency.wrap(USDC),
                path: path,
                minHopPriceX36: new uint256[](0),
                amountIn: uint128(amountIn),
                amountOutMinimum: 0.01 ether
            })
        );
        params[1] = abi.encode(Currency.wrap(USDC), amountIn, true);
        params[2] = abi.encode(Currency.wrap(address(0)), pool, uint256(0));
        (bytes memory commands, bytes[] memory inputs) = _v4Swap(
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN), uint8(Actions.SETTLE), uint8(Actions.TAKE)),
            params
        );

        assertEq(UNIVERSAL_ROUTER.balance, 0, "router starts with no ETH");

        uint256 ethBefore = pool.balance;
        vm.prank(poolOwner);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());
        assertEq(UNIVERSAL_ROUTER.balance, 0, "router must not receive ETH when selling token for native");
        assertGt(pool.balance, ethBefore, "pool must receive ETH");
    }

    /// @notice Migrated from "should transfer eth to universal router with exactOutSingle". The mock
    ///         kept the full maxIn; the real router only consumes the owed amount, so a trailing
    ///         SWEEP refunds the unused ETH to the pool and the router balance is asserted to be 0.
    function test_Execute_TransfersNative_ExactOutSingle() public {
        uint256 maxAmountIn = 0.1 ether;
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactOutputSingleParams({
                poolKey: _ethUsdcKey(),
                zeroForOne: true,
                amountOut: 100e6,
                amountInMaximum: uint128(maxAmountIn),
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(Currency.wrap(address(0)), uint256(ActionConstants.OPEN_DELTA), false);
        params[2] = abi.encode(Currency.wrap(USDC), pool, uint256(0));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(
            abi.encodePacked(uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE), uint8(Actions.TAKE)),
            params
        );
        inputs[1] = abi.encode(address(0), pool, uint256(0));
        bytes memory commands = abi.encodePacked(CMD_V4_SWAP, CMD_SWEEP);

        vm.prank(poolOwner);
        vm.expectRevert(IAUniswapRouter.InsufficientNativeBalance.selector);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());

        deal(pool, 1 ether);
        uint256 usdcBefore = IERC20(USDC).balanceOf(pool);
        vm.prank(poolOwner);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());
        assertEq(IERC20(USDC).balanceOf(pool) - usdcBefore, 100e6, "pool must receive the exact USDC amount");
        assertEq(UNIVERSAL_ROUTER.balance, 0, "unused ETH must be swept back from the router");
    }

    /// @notice Migrated from "should not transfer eth to universal router with exactOutSingle if
    ///         currencyOut is native". 1:1 intent: a genuine USDC->ETH exactOut swap sends no ETH
    ///         to the router.
    function test_Execute_DoesNotTransferNative_ExactOutSingle_NativeOut() public {
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactOutputSingleParams({
                poolKey: _ethUsdcKey(),
                zeroForOne: false,
                amountOut: 0.02 ether,
                amountInMaximum: 100e6,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(Currency.wrap(USDC), uint256(ActionConstants.OPEN_DELTA), true);
        params[2] = abi.encode(Currency.wrap(address(0)), pool, uint256(0));
        (bytes memory commands, bytes[] memory inputs) = _v4Swap(
            abi.encodePacked(uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE), uint8(Actions.TAKE)),
            params
        );

        assertEq(UNIVERSAL_ROUTER.balance, 0, "router starts with no ETH");

        uint256 ethBefore = pool.balance;
        vm.prank(poolOwner);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());
        assertEq(UNIVERSAL_ROUTER.balance, 0, "router must not receive ETH when currencyOut is native");
        assertEq(pool.balance - ethBefore, 0.02 ether, "pool must receive the exact ETH amount");
    }

    /// @notice Migrated from "should transfer eth to universal router with exactOut" (multihop,
    ///         reversed path). Same adaptation as the exactOutSingle variant, including the SWEEP
    ///         of the unused maxIn.
    function test_Execute_TransfersNative_ExactOut() public {
        uint256 maxAmountIn = 0.1 ether;
        PathKey[] memory path = new PathKey[](1);
        path[0] = _pathKey(address(0));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactOutputParams({
                currencyOut: Currency.wrap(USDC),
                path: path,
                minHopPriceX36: new uint256[](0),
                amountOut: 100e6,
                amountInMaximum: uint128(maxAmountIn)
            })
        );
        params[1] = abi.encode(Currency.wrap(address(0)), uint256(ActionConstants.OPEN_DELTA), false);
        params[2] = abi.encode(Currency.wrap(USDC), pool, uint256(0));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(
            abi.encodePacked(uint8(Actions.SWAP_EXACT_OUT), uint8(Actions.SETTLE), uint8(Actions.TAKE)),
            params
        );
        inputs[1] = abi.encode(address(0), pool, uint256(0));
        bytes memory commands = abi.encodePacked(CMD_V4_SWAP, CMD_SWEEP);

        vm.prank(poolOwner);
        vm.expectRevert(IAUniswapRouter.InsufficientNativeBalance.selector);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());

        deal(pool, 1 ether);
        uint256 usdcBefore = IERC20(USDC).balanceOf(pool);
        vm.prank(poolOwner);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());
        assertEq(IERC20(USDC).balanceOf(pool) - usdcBefore, 100e6, "pool must receive the exact USDC amount");
        assertEq(UNIVERSAL_ROUTER.balance, 0, "unused ETH must be swept back from the router");
    }

    /// @notice Migrated from "should not transfer eth to universal router with exactOut if
    ///         currencyOut is native". 1:1 intent with a genuine ETH-output exactOut swap.
    function test_Execute_DoesNotTransferNative_ExactOut_NativeOut() public {
        PathKey[] memory path = new PathKey[](1);
        path[0] = _pathKey(USDC);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactOutputParams({
                currencyOut: Currency.wrap(address(0)),
                path: path,
                minHopPriceX36: new uint256[](0),
                amountOut: 0.02 ether,
                amountInMaximum: 100e6
            })
        );
        params[1] = abi.encode(Currency.wrap(USDC), uint256(ActionConstants.OPEN_DELTA), true);
        params[2] = abi.encode(Currency.wrap(address(0)), pool, uint256(0));
        (bytes memory commands, bytes[] memory inputs) = _v4Swap(
            abi.encodePacked(uint8(Actions.SWAP_EXACT_OUT), uint8(Actions.SETTLE), uint8(Actions.TAKE)),
            params
        );

        assertEq(UNIVERSAL_ROUTER.balance, 0, "router starts with no ETH");

        uint256 ethBefore = pool.balance;
        vm.prank(poolOwner);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());
        assertEq(UNIVERSAL_ROUTER.balance, 0, "router must not receive ETH when currencyOut is native");
        assertEq(pool.balance - ethBefore, 0.02 ether, "pool must receive the exact ETH amount");
    }

    /// @notice Migrated from "should revert if recipient is not pool". 1:1: TAKE to a third party
    ///         reverts at decode time.
    function test_Execute_RecipientNotPool_Reverts() public {
        address recipient = makeAddr("recipient");
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(Currency.wrap(USDC), recipient, uint256(1));
        (bytes memory commands, bytes[] memory inputs) = _v4Swap(abi.encodePacked(uint8(Actions.TAKE)), params);

        vm.prank(poolOwner);
        vm.expectRevert(IAUniswapRouter.RecipientNotSmartPoolOrRouter.selector);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());
    }

    /// @notice Migrated from "should revert settle if tokenOut does not have a price feed". Phase 1
    ///         is 1:1 with an unfed token (a fresh address instead of mock-GRG). Phase 2 cannot
    ///         initialize observations for an arbitrary token on the real oracle, so it asserts
    ///         that the same plan shape succeeds for a fed token (USDC) instead.
    function test_Execute_TokenOutWithoutPriceFeed_Reverts() public {
        address unfedToken = makeAddr("unfedToken");
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(Currency.wrap(unfedToken), pool, uint256(1));
        (bytes memory commands, bytes[] memory inputs) = _v4Swap(abi.encodePacked(uint8(Actions.TAKE)), params);

        vm.prank(poolOwner);
        vm.expectRevert(abi.encodeWithSelector(EnumerableSet.TokenPriceFeedDoesNotExist.selector, unfedToken));
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());

        // same plan shape against a fed token succeeds via a genuine swap
        test_Execute_TakeCurrency_Succeeds();
    }

    /// @notice Migrated from "should take a currency". The mock TAKE succeeded with no settled
    ///         balance; the real PoolManager only credits what a swap produced, so a genuine
    ///         USDC->ETH swap precedes the TAKE. The taken currency is ETH.
    function test_Execute_TakeCurrency_Succeeds() public {
        uint256 amountIn = 100e6;
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: _ethUsdcKey(),
                zeroForOne: false,
                amountIn: uint128(amountIn),
                amountOutMinimum: 0.01 ether,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(Currency.wrap(USDC), amountIn, true);
        params[2] = abi.encode(Currency.wrap(address(0)), pool, uint256(0.005 ether));
        params[3] = abi.encode(Currency.wrap(address(0)), pool, uint256(0));
        (bytes memory commands, bytes[] memory inputs) = _v4Swap(
            abi.encodePacked(
                uint8(Actions.SWAP_EXACT_IN_SINGLE),
                uint8(Actions.SETTLE),
                uint8(Actions.TAKE),
                uint8(Actions.TAKE)
            ),
            params
        );

        uint256 ethBefore = pool.balance;
        vm.prank(poolOwner);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());
        assertGt(pool.balance - ethBefore, 0.005 ether, "pool must receive the taken ETH currency");
    }

    /// @notice Migrated from "should decode v4 payment methods" (SETTLE_ALL, TAKE_ALL, TAKE_PORTION).
    ///         Active-token assertions mirror the .ts ones: [USDC, ETH] on a WETH-based pool
    ///         (mock pool was ETH-based and excluded ETH).
    function test_Execute_DecodeV4PaymentMethods() public {
        deal(pool, 0.1 ether);
        uint256 amountIn = 0.01 ether;
        bytes[] memory params = new bytes[](7);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: _ethUsdcKey(),
                zeroForOne: true,
                amountIn: uint128(amountIn),
                amountOutMinimum: 10e6,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(Currency.wrap(address(0)), amountIn); // SETTLE_ALL
        params[2] = abi.encode(Currency.wrap(USDC), uint256(1)); // TAKE_ALL
        params[3] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: _ethUsdcKey(),
                zeroForOne: false,
                amountIn: uint128(10e6),
                amountOutMinimum: 0.001 ether,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[4] = abi.encode(Currency.wrap(USDC), uint128(10e6), true); // SETTLE
        params[5] = abi.encode(Currency.wrap(address(0)), pool, uint256(5_000)); // TAKE_PORTION 50%
        params[6] = abi.encode(Currency.wrap(address(0)), pool, uint256(0)); // TAKE remainder
        (bytes memory commands, bytes[] memory inputs) = _v4Swap(
            abi.encodePacked(
                uint8(Actions.SWAP_EXACT_IN_SINGLE),
                uint8(Actions.SETTLE_ALL),
                uint8(Actions.TAKE_ALL),
                uint8(Actions.SWAP_EXACT_IN_SINGLE),
                uint8(Actions.SETTLE),
                uint8(Actions.TAKE_PORTION),
                uint8(Actions.TAKE)
            ),
            params
        );

        vm.prank(poolOwner);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());

        address[] memory activeTokens = ISmartPoolState(pool).getActiveTokens().activeTokens;
        assertEq(activeTokens.length, 2, "USDC and ETH must be active tokens");
        assertEq(activeTokens[0], USDC, "first active token must be USDC");
        assertEq(activeTokens[1], address(0), "second active token must be ETH");
    }

    /// @notice Migrated from "should wrap/unwrap native". 1:1 with USDC in place of mock-GRG for
    ///         the balance check; WRAP_ETH amount is forwarded from the pool's own ETH.
    function test_Execute_WrapUnwrapNative() public {
        deal(pool, 0.1 ether);
        bytes memory commands = abi.encodePacked(CMD_WRAP_ETH, CMD_UNWRAP_WETH, CMD_BALANCE_CHECK_ERC20);
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = abi.encode(pool, uint256(1000));
        inputs[1] = abi.encode(pool, uint256(0));
        inputs[2] = abi.encode(pool, USDC, uint256(1));

        uint256 wethBefore = IERC20(WETH).balanceOf(pool);
        vm.prank(poolOwner);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());
        assertEq(IERC20(WETH).balanceOf(pool) - wethBefore, 1000, "pool must receive the wrapped ETH");
    }

    /// @notice Migrated from "should decode WRAP_ETH with CONTRACT_BALANCE flag without overflow".
    ///         1:1: the CONTRACT_BALANCE sentinel must not be added to the forwarded value.
    function test_Execute_WrapEthContractBalanceFlag() public {
        bytes memory commands = abi.encodePacked(CMD_WRAP_ETH, CMD_BALANCE_CHECK_ERC20);
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(pool, ActionConstants.CONTRACT_BALANCE);
        inputs[1] = abi.encode(pool, USDC, uint256(1));

        vm.prank(poolOwner);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());
    }

    /// @notice Migrated from "a direct call should revert". 1:1: calling the adapter outside the
    ///         pool context reverts with DirectCallNotAllowed. The selector is sourced from
    ///         IAIntents, which declares the identically-named error (same signature, same
    ///         selector); AUniswapRouter's own copy is not importable from this 0.8.28 job.
    function test_Execute_DirectCall_Reverts() public {
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(Currency.wrap(USDC), pool, uint256(1));
        (bytes memory commands, bytes[] memory inputs) = _v4Swap(abi.encodePacked(uint8(Actions.TAKE)), params);

        vm.expectRevert(IAIntents.DirectCallNotAllowed.selector);
        IAUniswapRouter(aUniswapRouter).execute(commands, inputs, _deadline());
    }

    /// @notice Migrated from "should propagate string error from universal router". The mock used
    ///         revertMode(1); against the real router a zero-amount V2 exact-in reaches the V2 pair,
    ///         which reverts with the string 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT'.
    function test_Execute_PropagatesStringError() public {
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;
        bytes memory commands = abi.encodePacked(CMD_V2_SWAP_EXACT_IN);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(pool, uint256(0), uint256(0), path, true, new uint256[](0));

        vm.prank(poolOwner);
        vm.expectRevert("UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT");
        IAUniswapRouter(pool).execute(commands, inputs);
    }

    /// @notice Migrated from "should propagate custom error from universal router". The mock used
    ///         revertMode(2); against the real router an unreachable V3 slippage bound reverts with
    ///         the router's V3TooLittleReceived custom error, which must bubble up unchanged.
    function test_Execute_PropagatesCustomError() public {
        bytes memory path = abi.encodePacked(WETH, uint24(500), USDC);
        bytes memory commands = abi.encodePacked(CMD_V3_SWAP_EXACT_IN);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(pool, uint256(0.001 ether), uint256(1e9), path, true, new uint256[](0));

        vm.prank(poolOwner);
        vm.expectRevert(V3TooLittleReceived.selector);
        IAUniswapRouter(pool).execute(commands, inputs);
    }

    /// @notice Migrated from "should execute a subplan". 1:1: an EXECUTE_SUB_PLAN wrapping a genuine
    ///         V4 swap, asserting the pool received the USDC.
    function test_Execute_SubPlan() public {
        deal(pool, 1 ether);
        uint256 amountIn = 0.1 ether;
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: _ethUsdcKey(),
                zeroForOne: true,
                amountIn: uint128(amountIn),
                amountOutMinimum: 100e6,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(Currency.wrap(address(0)), amountIn, true);
        params[2] = abi.encode(Currency.wrap(USDC), pool, uint256(0));
        (bytes memory subCommands, bytes[] memory subInputs) = _v4Swap(
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE), uint8(Actions.TAKE)),
            params
        );

        bytes memory commands = abi.encodePacked(CMD_EXECUTE_SUB_PLAN);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(subCommands, subInputs);

        uint256 usdcBefore = IERC20(USDC).balanceOf(pool);
        vm.prank(poolOwner);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());
        assertGt(IERC20(USDC).balanceOf(pool), usdcBefore, "pool must receive USDC via subplan");
    }

    /// @notice Migrated from "should remove 1 token from active tokens". The ETH taken to the router
    ///         (ADDRESS_THIS) leaves the pool with zero ETH balance, so purge removes ETH and keeps
    ///         the USDC the pool holds (mirrors the .ts GRG/WETH flow).
    function test_Execute_RemoveInactiveTokenFromActiveTokens() public {
        uint256 amountIn = 0.05 ether;
        // fund the pool with exactly the swap input, so no ETH is left for the purge to keep
        deal(pool, amountIn);
        bytes[] memory params = new bytes[](6);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: _ethUsdcKey(),
                zeroForOne: true,
                amountIn: uint128(amountIn),
                amountOutMinimum: 50e6,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(Currency.wrap(address(0)), amountIn, true);
        params[2] = abi.encode(Currency.wrap(USDC), pool, uint256(0));
        params[3] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: _ethUsdcKey(),
                zeroForOne: false,
                amountIn: uint128(10e6),
                amountOutMinimum: 0.001 ether,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[4] = abi.encode(Currency.wrap(USDC), uint128(10e6), true);
        params[5] = abi.encode(Currency.wrap(address(0)), ADDRESS_THIS, uint256(0));
        (bytes memory commands, bytes[] memory inputs) = _v4Swap(
            abi.encodePacked(
                uint8(Actions.SWAP_EXACT_IN_SINGLE),
                uint8(Actions.SETTLE),
                uint8(Actions.TAKE),
                uint8(Actions.SWAP_EXACT_IN_SINGLE),
                uint8(Actions.SETTLE),
                uint8(Actions.TAKE)
            ),
            params
        );

        vm.prank(poolOwner);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());

        address[] memory activeTokens = ISmartPoolState(pool).getActiveTokens().activeTokens;
        assertEq(activeTokens.length, 2, "USDC and ETH must be active tokens");

        vm.prank(poolOwner);
        ISmartPoolOwnerActions(pool).purgeInactiveTokensAndApps();

        activeTokens = ISmartPoolState(pool).getActiveTokens().activeTokens;
        assertEq(activeTokens.length, 1, "ETH must be purged as the pool holds none");
        assertEq(activeTokens[0], USDC, "USDC must stay active as the pool holds a balance");
    }

    /// @notice Migrated from "should process v3 exactIn swap". 1:1 against the real WETH/USDC 0.05%
    ///         V3 pool.
    function test_Execute_V3ExactIn() public {
        bytes memory path = abi.encodePacked(WETH, uint24(500), USDC);
        bytes memory commands = abi.encodePacked(CMD_V3_SWAP_EXACT_IN);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(pool, uint256(0.001 ether), uint256(1), path, true, new uint256[](0));

        uint256 usdcBefore = IERC20(USDC).balanceOf(pool);
        vm.prank(poolOwner);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());
        assertGt(IERC20(USDC).balanceOf(pool), usdcBefore, "pool must receive USDC");
    }

    /// @notice Migrated from "should process v3 exactIn swap by passing sender as recipient flag".
    ///         1:1: MSG_SENDER resolves to the pool, which still receives the USDC.
    function test_Execute_V3ExactIn_SenderAsRecipient() public {
        bytes memory path = abi.encodePacked(WETH, uint24(500), USDC);
        bytes memory commands = abi.encodePacked(CMD_V3_SWAP_EXACT_IN);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(MSG_SENDER, uint256(0.001 ether), uint256(1), path, true, new uint256[](0));

        uint256 usdcBefore = IERC20(USDC).balanceOf(pool);
        vm.prank(poolOwner);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());
        assertGt(IERC20(USDC).balanceOf(pool), usdcBefore, "pool must receive USDC");
    }

    /// @notice Migrated from "should process v3 exactIn swap and unwrap". 1:1: swap output stays on
    ///         the router (ADDRESS_THIS), UNWRAP_WETH forwards the ETH to the pool.
    function test_Execute_V3ExactInAndUnwrap() public {
        bytes memory path = abi.encodePacked(USDC, uint24(500), WETH);
        bytes memory commands = abi.encodePacked(CMD_V3_SWAP_EXACT_IN, CMD_UNWRAP_WETH);
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(ADDRESS_THIS, uint256(100e6), uint256(0.01 ether), path, true, new uint256[](0));
        inputs[1] = abi.encode(pool, uint256(0));

        uint256 ethBefore = pool.balance;
        vm.prank(poolOwner);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());
        assertGt(pool.balance - ethBefore, 0.01 ether, "pool must receive the unwrapped ETH");
    }

    /// @notice Migrated from "should process v3 exactOut". 1:1 against the real V3 pool. Note the
    ///         real router expects the exact-out path reversed (tokenOut first); the .ts spec's
    ///         forward path only worked because the mock ignored it.
    function test_Execute_V3ExactOut() public {
        bytes memory path = abi.encodePacked(USDC, uint24(500), WETH);
        bytes memory commands = abi.encodePacked(CMD_V3_SWAP_EXACT_OUT);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(pool, uint256(100e6), uint256(0.1 ether), path, true, new uint256[](0));

        uint256 usdcBefore = IERC20(USDC).balanceOf(pool);
        vm.prank(poolOwner);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());
        assertEq(IERC20(USDC).balanceOf(pool) - usdcBefore, 100e6, "pool must receive the exact USDC amount");
    }

    /// @notice Migrated from "should process v2 swap". Phases 1-2 run against the real WETH/USDC V2
    ///         pair. Phase 3 (native path with funded pool) is adapted: the real router has no
    ///         ETH->WETH substitution in V2 paths, so the adapter must convert the failure to
    ///         InsufficientNativeBalance whenever the derived value exceeds the pool balance.
    function test_Execute_V2Swap() public {
        // phases 1-2: v2 exact-in and exact-out against the real pair
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;
        bytes memory commands = abi.encodePacked(CMD_V2_SWAP_EXACT_IN, CMD_V2_SWAP_EXACT_OUT);
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(pool, uint256(0.01 ether), uint256(1), path, true, new uint256[](0));
        inputs[1] = abi.encode(pool, uint256(100e6), uint256(0.1 ether), path, true, new uint256[](0));

        uint256 usdcBefore = IERC20(USDC).balanceOf(pool);
        vm.prank(poolOwner);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());
        assertGt(IERC20(USDC).balanceOf(pool), usdcBefore, "pool must receive USDC from the v2 swaps");

        // phase 3: native path with no pool ETH reverts with InsufficientNativeBalance
        address[] memory nativePath = new address[](2);
        nativePath[0] = address(0);
        nativePath[1] = USDC;
        bytes memory nativeCommands = abi.encodePacked(CMD_V2_SWAP_EXACT_IN);
        bytes[] memory nativeInputs = new bytes[](1);
        nativeInputs[0] = abi.encode(pool, uint256(100), uint256(1), nativePath, true, new uint256[](0));

        vm.prank(poolOwner);
        vm.expectRevert(IAUniswapRouter.InsufficientNativeBalance.selector);
        IAUniswapRouter(pool).execute(nativeCommands, nativeInputs, _deadline());

        // phase 4: native path whose derived value exceeds the pool balance also reverts with
        // InsufficientNativeBalance (the real router would otherwise fail pulling ETH via permit2)
        deal(pool, 0.1 ether);
        nativeInputs[0] = abi.encode(pool, uint256(1 ether), uint256(1), nativePath, true, new uint256[](0));
        vm.prank(poolOwner);
        vm.expectRevert(IAUniswapRouter.InsufficientNativeBalance.selector);
        IAUniswapRouter(pool).execute(nativeCommands, nativeInputs, _deadline());

        // phase 5: recipient other than pool or router reverts at decode time
        nativeInputs[0] = abi.encode(poolOwner, uint256(100), uint256(1), nativePath, true, new uint256[](0));
        vm.prank(poolOwner);
        vm.expectRevert(IAUniswapRouter.RecipientNotSmartPoolOrRouter.selector);
        IAUniswapRouter(pool).execute(nativeCommands, nativeInputs, _deadline());
    }

    /// @notice Migrated from "should revert V2_SWAP_EXACT_OUT with native ETH path". 1:1: the
    ///         adapter rejects native exact-out v2 swaps at decode time.
    function test_Execute_V2ExactOutNativePath_Reverts() public {
        address[] memory path = new address[](2);
        path[0] = address(0);
        path[1] = USDC;
        bytes memory commands = abi.encodePacked(CMD_V2_SWAP_EXACT_OUT);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(pool, uint256(100), uint256(1), path, true, new uint256[](0));

        vm.prank(poolOwner);
        vm.expectRevert(abi.encodeWithSelector(IAUniswapRouter.InvalidCommandType.selector, uint256(0x09)));
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());
    }

    /// @notice Migrated from "should process sweep, transfer and pay v3 payment methods". The mock
    ///         moved GRG held by the router; the equivalent real flow swaps WETH->USDC with the
    ///         router as recipient, then TRANSFER / PAY_PORTION / PAY_PORTION_FULL_PRECISION / SWEEP
    ///         clear the router's USDC to the pool.
    function test_Execute_SweepTransferPayPortion() public {
        bytes memory path = abi.encodePacked(WETH, uint24(500), USDC);
        bytes memory commands = abi.encodePacked(
            CMD_V3_SWAP_EXACT_IN,
            CMD_TRANSFER,
            CMD_PAY_PORTION,
            CMD_PAY_PORTION_FULL_PRECISION,
            CMD_SWEEP
        );
        bytes[] memory inputs = new bytes[](5);
        inputs[0] = abi.encode(ADDRESS_THIS, uint256(0.01 ether), uint256(1), path, true, new uint256[](0));
        inputs[1] = abi.encode(USDC, pool, uint256(1e6));
        inputs[2] = abi.encode(USDC, pool, uint256(100));
        inputs[3] = abi.encode(USDC, pool, uint256(1e15));
        inputs[4] = abi.encode(USDC, pool, uint256(0));

        uint256 usdcBefore = IERC20(USDC).balanceOf(pool);
        vm.prank(poolOwner);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());
        assertEq(IERC20(USDC).balanceOf(UNIVERSAL_ROUTER), 0, "payment methods must clear the router");
        assertGt(IERC20(USDC).balanceOf(pool), usdcBefore, "pool must receive the USDC");
    }

    /// @notice Migrated from "should revert when calling unsupported methods". 1:1: every command
    ///         outside the adapter's allowlist reverts with InvalidCommandType at decode time.
    function test_Execute_UnsupportedCommands_Revert() public {
        uint256[11] memory unsupported = [
            uint256(0x02), // PERMIT2_TRANSFER_FROM
            0x03, // PERMIT2_PERMIT_BATCH
            0x0a, // PERMIT2_PERMIT
            0x0d, // PERMIT2_TRANSFER_FROM_BATCH
            0x11, // V3_POSITION_MANAGER_PERMIT
            0x12, // V3_POSITION_MANAGER_CALL
            0x14, // V4_POSITION_MANAGER_CALL
            0x15, // placeholder after V4_POSITION_MANAGER_CALL
            0x20, // placeholder before EXECUTE_SUB_PLAN
            0x22, // placeholder after EXECUTE_SUB_PLAN
            0x0f // placeholder before V4_SWAP
        ];
        for (uint256 i = 0; i < unsupported.length; i++) {
            bytes memory commands = abi.encodePacked(bytes1(uint8(unsupported[i])));
            bytes[] memory inputs = new bytes[](1);
            inputs[0] = hex"";
            vm.prank(poolOwner);
            vm.expectRevert(abi.encodeWithSelector(IAUniswapRouter.InvalidCommandType.selector, unsupported[i]));
            IAUniswapRouter(pool).execute(commands, inputs, _deadline());
        }
    }

    /// @notice Migrated from "logs gas costs for mint when pool has null balance of active tokens".
    ///         Logs mint gas with one then two active tokens; asserts two active tokens at the end.
    function test_Execute_LogsMintGas_NullTokenBalances() public {
        deal(pool, 0.1 ether);
        deal(WETH, poolOwner, 1 ether);
        vm.prank(poolOwner);
        IERC20(WETH).approve(pool, 1 ether);

        _activateUsdc();
        _logMintGas("1st mint gas, 1 active token (stores initial value)");
        _logMintGas("2nd mint gas, 1 active token (calculates nav)");
        _activateEth();
        _logMintGas("3rd mint gas, 2 active tokens (calculates nav)");

        assertEq(ISmartPoolState(pool).getActiveTokens().activeTokens.length, 2);
    }

    /// @notice Migrated from "logs gas costs for mint when pool holds positive GRG balance". The
    ///         pool already holds a positive USDC balance, mirroring the .ts GRG condition.
    function test_Execute_LogsMintGas_PositiveTokenBalance() public {
        deal(pool, 0.1 ether);
        deal(WETH, poolOwner, 2 ether);
        vm.prank(poolOwner);
        IERC20(WETH).approve(pool, 2 ether);

        _activateUsdc();
        _logMintGas("1st mint gas, 1 active token (stores initial value)");
        _logMintGas("2nd mint gas, 1 active token (calculates nav)");
        _activateEth();
        _logMintGas("3rd mint gas, 2 active tokens (calculates nav)");
        _logMintGas("4th mint gas, 2 active tokens (calculates nav, no storage update)");

        assertEq(ISmartPoolState(pool).getActiveTokens().activeTokens.length, 2);
    }

    /// @dev Activates USDC as an active token via a genuine ETH->USDC swap + TAKE to the pool.
    function _activateUsdc() internal {
        uint256 amountIn = 0.01 ether;
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: _ethUsdcKey(),
                zeroForOne: true,
                amountIn: uint128(amountIn),
                amountOutMinimum: 1e6,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(Currency.wrap(address(0)), amountIn, true);
        params[2] = abi.encode(Currency.wrap(USDC), pool, uint256(0));
        (bytes memory commands, bytes[] memory inputs) = _v4Swap(
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE), uint8(Actions.TAKE)),
            params
        );
        vm.prank(poolOwner);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());
    }

    /// @dev Activates ETH as an active token via a genuine USDC->ETH swap + TAKE to the pool.
    function _activateEth() internal {
        uint256 amountIn = 10e6;
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: _ethUsdcKey(),
                zeroForOne: false,
                amountIn: uint128(amountIn),
                amountOutMinimum: 0.001 ether,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(Currency.wrap(USDC), amountIn, true);
        params[2] = abi.encode(Currency.wrap(address(0)), pool, uint256(0));
        (bytes memory commands, bytes[] memory inputs) = _v4Swap(
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE), uint8(Actions.TAKE)),
            params
        );
        vm.prank(poolOwner);
        IAUniswapRouter(pool).execute(commands, inputs, _deadline());
    }

    function _logMintGas(string memory label) internal {
        vm.prank(poolOwner);
        uint256 gasBefore = gasleft();
        ISmartPoolActions(pool).mint(poolOwner, 0.1 ether, 0);
        console2.log(gasBefore - gasleft(), label);
    }

    /// @dev Seeds a full-range ETH/USDC v4 pool from an external LP, so the pool's active-token
    ///      state stays untouched. Assumes the pool is uninitialized at the fork block, same as
    ///      AUniswapRouterFork.t.sol does for its WETH/USDC pool.
    function _seedEthUsdcPool() internal {
        PoolKey memory poolKey = _ethUsdcKey();
        IPositionManager(POSM).initializePool(poolKey, SQRT_PRICE_3000);

        int24 tickLower = -887220;
        int24 tickUpper = 887220;
        uint160 sqrtPa = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPb = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_3000,
            sqrtPa,
            sqrtPb,
            100 ether,
            300_000e6
        );
        uint256 amount0 = SqrtPriceMath.getAmount0Delta(SQRT_PRICE_3000, sqrtPb, liquidity, true);
        uint256 amount1 = SqrtPriceMath.getAmount1Delta(sqrtPa, SQRT_PRICE_3000, liquidity, true);

        address lp = makeAddr("lp");
        vm.deal(lp, amount0);
        deal(USDC, lp, amount1);

        vm.startPrank(lp);
        IERC20(USDC).approve(permit2, type(uint256).max);
        IAllowanceTransfer(permit2).approve(USDC, POSM, type(uint160).max, type(uint48).max);
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            uint256(liquidity),
            uint128(amount0),
            uint128(amount1),
            lp,
            bytes("")
        );
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        IPositionManager(POSM).modifyLiquidities{value: amount0}(abi.encode(actions, params), _deadline());
        vm.stopPrank();
    }

    function _ethUsdcKey() private pure returns (PoolKey memory) {
        return
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(USDC),
                fee: 0,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            });
    }

    function _pathKey(address intermediateCurrency) private pure returns (PathKey memory) {
        return
            PathKey({
                intermediateCurrency: Currency.wrap(intermediateCurrency),
                fee: 0,
                tickSpacing: 60,
                hooks: IHooks(address(0)),
                hookData: bytes("")
            });
    }

    function _v4Swap(
        bytes memory actions,
        bytes[] memory params
    ) private pure returns (bytes memory commands, bytes[] memory inputs) {
        commands = abi.encodePacked(CMD_V4_SWAP);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }

    function _deadline() private view returns (uint256) {
        return block.timestamp + 1 hours;
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
