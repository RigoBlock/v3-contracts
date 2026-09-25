// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

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
import {ISmartPoolOwnerActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolOwnerActions.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {IAUniswapRouter} from "../../contracts/protocol/extensions/adapters/interfaces/IAUniswapRouter.sol";
import {IEApps} from "../../contracts/protocol/extensions/adapters/interfaces/IEApps.sol";
import {IEOracle} from "../../contracts/protocol/extensions/adapters/interfaces/IEOracle.sol";
import {EnumerableSet} from "../../contracts/protocol/libraries/EnumerableSet.sol";
import {StorageLib} from "../../contracts/protocol/libraries/StorageLib.sol";

import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {DeploymentParams, Extensions, EAppsParams} from "../../contracts/protocol/types/DeploymentParams.sol";

/// @dev Test-local error used to assert raw custom-error propagation from the posm call.
interface IPosmCustomError {
    error PosmCustomError(uint256 code);
}

/// @notice Minimal no-op IHooks implementation. Mined via CREATE2 so that its address carries the
///         AFTER_ADD/REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG bits: the real PoolManager then accepts
///         hook pools (the address bits mandate the companion after-add/remove flags), invokes the
///         hooks during mint, and settles the zero deltas they return, letting the adapter's
///         LiquidityMintHookError check fire after a successful mint.
contract DeltaHook is IHooks {
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeSwap(
        address,
        PoolKey calldata,
        SwapParams calldata,
        bytes calldata
    ) external pure returns (bytes4, BeforeSwapDelta, uint24) {
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, int128) {
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.afterDonate.selector;
    }
}

interface IPosmPermit2 {
    function permit2() external view returns (address);
}

/// @dev ERC-721 view methods of the PositionManager, not exposed on IPositionManager.
interface IPosmErc721 {
    function balanceOf(address owner) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title AUniswapRouterModifyLiquiditiesForkTest
/// @notice Fork tests for the modifyLiquidities flow of AUniswapRouter against the real deployed
///         Uniswap contracts (Universal Router 2.1.2, V4 PositionManager, BackGeoOracle) on Arbitrum.
/// @dev Ports the mock-based `describe("modifyLiquidities")` block of AUniswapRouter.spec.ts,
///      including the mock-only paths: the hook liquidity-delta permission check is exercised
///      against a real mined hook contract, the adapter-level PositionOwner check via targeted
///      storage erasure, and posm error propagation via vm.mockCallRevert.
contract AUniswapRouterModifyLiquiditiesForkTest is Test {
    address private constant AUTHORITY = Constants.AUTHORITY;
    address private constant FACTORY = Constants.FACTORY;
    address private constant TOKEN_JAR = Constants.TOKEN_JAR;
    address private constant WETH = Constants.ARB_WETH;
    address private constant USDC = Constants.ARB_USDC;
    address private constant ORACLE = Constants.ARB_ORACLE;
    address private constant POSM = Constants.ARB_UNISWAP_V4_POSM;
    address private constant UNIVERSAL_ROUTER = Constants.ARB_UNIVERSAL_ROUTER;

    uint160 private constant SQRT_PRICE_WETH_USDC = 4_339_505_179_874_779_475_002_393; // ~3000 USDC/WETH
    uint160 private constant SQRT_PRICE_ETH_WETH = 79_228_162_514_264_337_593_543_950_336; // 2^96, price 1

    int24 private constant TICK_LOWER = -887_220;
    int24 private constant TICK_UPPER = 887_220;

    address private poolOwner;
    address private pool;

    bool private ethWethPoolInitialized;
    bool private wethUsdcPoolInitialized;

    function setUp() public {
        vm.createSelectFork("arbitrum", Constants.ARB_BLOCK);

        poolOwner = makeAddr("poolOwner");

        // AUniswapRouter is pinned to solc 0.8.37 while fork tests stay on 0.8.28; forge
        // compiles it in its own job and we deploy the artifact (deployCode), keeping the
        // test's compilation job free of the router source. Same pattern as AUniswapRouterFork.
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
        bytes32 salt = keccak256(abi.encodePacked("AUNISWAP_ROUTER_MODIFY_LIQUIDITIES_FORK_TEST", block.chainid));
        address extensionsMapAddr = mapDeployer.deployExtensionsMap(params, salt);

        SmartPool impl = new SmartPool(AUTHORITY, extensionsMapAddr, TOKEN_JAR);

        address registry = IRigoblockPoolProxyFactory(FACTORY).getRegistry();
        address rigoblockDao = IPoolRegistry(registry).rigoblockDao();
        vm.prank(rigoblockDao);
        IRigoblockPoolProxyFactory(FACTORY).setImplementation(address(impl));

        vm.prank(poolOwner);
        (pool, ) = IRigoblockPoolProxyFactory(FACTORY).createPool("UniRouterModifyPool", "URMP", WETH);

        address authorityOwner = IOwnedUninitialized(AUTHORITY).owner();
        vm.startPrank(authorityOwner);
        IAuthority(AUTHORITY).setAdapter(aUniswapRouter, true);
        if (!IAuthority(AUTHORITY).isWhitelister(authorityOwner)) {
            IAuthority(AUTHORITY).setWhitelister(authorityOwner, true);
        }
        // The production Authority maps these selectors to the previously deployed adapter;
        // repoint them at the adapter under test, otherwise pool calls would delegatecall
        // stale production code. `execute` is overloaded on IAUniswapRouter, so its selectors
        // are encoded manually (expected values per AUniswapRouter.spec.ts) — same pattern
        // as the overloaded unwrapWETH9 selectors in AUniswapFork.t.sol.
        _repointMethod(IAUniswapRouter.modifyLiquidities.selector, aUniswapRouter);
        _repointMethod(bytes4(keccak256("execute(bytes,bytes[],uint256)")), aUniswapRouter); // 0x3593564c
        _repointMethod(bytes4(keccak256("execute(bytes,bytes[])")), aUniswapRouter); // 0x24856bc3
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

    /// @notice Ports "should route to uniV4Posm": minting an ETH/WETH position activates WETH as
    ///         an active token, tracks the position, and repeated mints do not duplicate the token.
    function test_ModifyLiquidities_RoutesToUniV4Posm() public {
        address ethPool = _createEthPool();
        PoolKey memory poolKey = _ethWethPoolKey();
        _ensureEthWethPool();

        uint256 tokenId = IPositionManager(POSM).nextTokenId();
        bytes memory unlockData = _encodeMintAndSettlePair(poolKey, TICK_LOWER, TICK_UPPER, 1e13, 0.01 ether, ethPool);

        // pool has no native balance: the derived value exceeds the balance
        vm.prank(poolOwner);
        vm.expectRevert(IAUniswapRouter.InsufficientNativeBalance.selector);
        IAUniswapRouter(ethPool).modifyLiquidities(unlockData, block.timestamp + 1 hours);

        deal(ethPool, 2 ether);
        deal(WETH, ethPool, 1 ether);

        vm.expectEmit(ethPool);
        emit IAUniswapRouter.UniV4PositionAdded(tokenId);
        vm.prank(poolOwner);
        IAUniswapRouter(ethPool).modifyLiquidities(unlockData, block.timestamp + 1 hours);

        assertEq(
            ISmartPoolState(ethPool).getActiveTokens().activeTokens.length,
            1,
            "WETH must be the only active token"
        );

        // second mint does not add the token again
        bytes memory secondMint = _encodeMintAndSettlePair(poolKey, TICK_LOWER, TICK_UPPER, 1e13, 0.01 ether, ethPool);
        vm.prank(poolOwner);
        IAUniswapRouter(ethPool).modifyLiquidities(secondMint, block.timestamp + 1 hours);

        assertEq(ISmartPoolState(ethPool).getActiveTokens().activeTokens.length, 1, "active tokens must not grow");
        assertEq(IPosmErc721(POSM).balanceOf(ethPool), 2, "pool must own two positions");
        uint256[] memory tokenIds = IEApps(ethPool).getUniV4TokenIds();
        assertEq(tokenIds.length, 2, "pool must track two positions");

        // WETH is part of a live LP position, so purge must not remove it
        vm.prank(poolOwner);
        ISmartPoolOwnerActions(ethPool).purgeInactiveTokensAndApps();
        assertEq(ISmartPoolState(ethPool).getActiveTokens().activeTokens.length, 1, "WETH must survive purge");
    }

    /// @notice Ports "should mint 2 positions in the same call".
    function test_ModifyLiquidities_MintTwoPositionsInSameCall() public {
        address ethPool = _createEthPool();
        PoolKey memory poolKey = _ethWethPoolKey();
        _ensureEthWethPool();

        deal(ethPool, 2 ether);
        deal(WETH, ethPool, 1 ether);

        uint256 nextTokenId = IPositionManager(POSM).nextTokenId();

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            poolKey,
            TICK_LOWER,
            TICK_UPPER,
            1e13,
            uint128(0.01 ether),
            type(uint128).max,
            ethPool,
            ""
        );
        params[1] = abi.encode(
            poolKey,
            TICK_LOWER,
            TICK_UPPER - 60,
            1e13,
            uint128(0.01 ether),
            type(uint128).max,
            ethPool,
            ""
        );
        params[2] = abi.encode(poolKey.currency0, poolKey.currency1);

        vm.expectEmit(ethPool);
        emit IAUniswapRouter.UniV4PositionAdded(nextTokenId);
        vm.expectEmit(ethPool);
        emit IAUniswapRouter.UniV4PositionAdded(nextTokenId + 1);
        vm.prank(poolOwner);
        IAUniswapRouter(ethPool).modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);

        assertEq(IPosmErc721(POSM).balanceOf(ethPool), 2, "pool must own two positions");
        assertEq(IEApps(ethPool).getUniV4TokenIds().length, 2, "pool must track two positions");
    }

    /// @notice Ports "should revert if position recipient is not pool": decode-time recipient check.
    function test_ModifyLiquidities_RevertIfRecipientNotPool() public {
        PoolKey memory poolKey = _wethUsdcPoolKey();
        address recipient = makeAddr("recipient");
        bytes memory unlockData = _encodeMintAndSettlePair(
            poolKey,
            TICK_LOWER,
            TICK_UPPER,
            1e13,
            type(uint128).max,
            recipient
        );

        vm.prank(poolOwner);
        vm.expectRevert(IAUniswapRouter.RecipientNotSmartPoolOrRouter.selector);
        IAUniswapRouter(pool).modifyLiquidities(unlockData, block.timestamp + 1 hours);
    }

    /// @notice Ports "should revert mint if a token does not have a price feed". The second half of
    ///         the TS test (initializeObservations on the mock oracle, then mint succeeds) is
    ///         mock-only: the real BackGeoOracle cannot mint new feeds; positive mints are covered
    ///         by the other tests in this file.
    function test_ModifyLiquidities_RevertMintTokenWithoutPriceFeed() public {
        address noFeedToken = makeAddr("noFeedToken");
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(noFeedToken),
            currency1: Currency.wrap(WETH),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        bytes memory unlockData = _encodeMintAndSettlePair(
            poolKey,
            TICK_LOWER,
            TICK_UPPER,
            1e13,
            type(uint128).max,
            pool
        );

        vm.prank(poolOwner);
        vm.expectRevert(abi.encodeWithSelector(EnumerableSet.TokenPriceFeedDoesNotExist.selector, noFeedToken));
        IAUniswapRouter(pool).modifyLiquidities(unlockData, block.timestamp + 1 hours);
    }

    /// @notice Ports "should not be able to increase liquidity of non-owned position". The real
    ///         PositionManager enforces ERC-721 ownership before the adapter's PositionOwner check
    ///         can run, so the observed revert is the posm's NotApproved(pool) rather than the
    ///         adapter error (the adapter-level check is covered by
    ///         test_ModifyLiquidities_IncreaseUntrackedOwnedPosition_Reverts below).
    function test_ModifyLiquidities_IncreaseNonOwnedPosition_Reverts() public {
        PoolKey memory poolKey = _wethUsdcPoolKey();
        _ensureWethUsdcPool();

        address user = makeAddr("user");
        uint256 foreignTokenId = IPositionManager(POSM).nextTokenId();

        // user mints a position directly on the posm, so the pool is not the owner
        address permit2 = IPosmPermit2(POSM).permit2();
        deal(WETH, user, 2 ether);
        deal(USDC, user, 20_000e6);
        vm.startPrank(user);
        IERC20(WETH).approve(permit2, type(uint256).max);
        IERC20(USDC).approve(permit2, type(uint256).max);
        IAllowanceTransfer(permit2).approve(WETH, POSM, type(uint160).max, 0);
        IAllowanceTransfer(permit2).approve(USDC, POSM, type(uint160).max, 0);
        bytes memory userActions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory userParams = new bytes[](2);
        userParams[0] = abi.encode(
            poolKey,
            TICK_LOWER,
            TICK_UPPER,
            1e13,
            type(uint128).max,
            type(uint128).max,
            user,
            ""
        );
        userParams[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        IPositionManager(POSM).modifyLiquidities(abi.encode(userActions, userParams), block.timestamp + 1 hours);
        vm.stopPrank();

        assertEq(IPosmErc721(POSM).ownerOf(foreignTokenId), user, "user must own the position");

        // the pool attempts to increase liquidity on the foreign position
        bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY));
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(foreignTokenId, uint256(1e12), type(uint128).max, type(uint128).max, "");

        vm.prank(poolOwner);
        vm.expectRevert(abi.encodeWithSelector(IPositionManager.NotApproved.selector, pool));
        IAUniswapRouter(pool).modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);
    }

    /// @notice Ports "should revert if hook can access liquidity deltas". A DeltaHook is mined via
    ///         CREATE2 so its address carries the AFTER_ADD/REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG bits
    ///         (with the companion flags PoolManager's hook validation requires), a real WETH/USDC
    ///         hook pool is initialized on the fork, and the mint through the adapter succeeds on
    ///         the real posm (the hook settles zero deltas) before the adapter's post-call check
    ///         fires LiquidityMintHookError.
    function test_ModifyLiquidities_HookWithLiquidityDeltaAccess_Reverts() public {
        address hook = _mineDeltaHook();

        // the hook pool is a distinct pool id from the plain WETH/USDC pool initialized elsewhere
        PoolKey memory hookPoolKey = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        IPositionManager(POSM).initializePool(hookPoolKey, SQRT_PRICE_WETH_USDC);

        bytes memory unlockData = _encodeMintAndSettlePair(
            hookPoolKey,
            TICK_LOWER,
            TICK_UPPER,
            1e13,
            type(uint128).max,
            pool
        );

        vm.prank(poolOwner);
        vm.expectRevert(abi.encodeWithSelector(IAUniswapRouter.LiquidityMintHookError.selector, hook));
        IAUniswapRouter(pool).modifyLiquidities(unlockData, block.timestamp + 1 hours);
    }

    /// @notice Ports the adapter-level PositionOwner check of "should not be able to increase
    ///         liquidity of non-owned position": a position minted through the adapter is tracked,
    ///         then ONLY its tracking entry is erased. The real posm increase succeeds (the pool
    ///         owns the ERC-721), so the adapter's defense-in-depth storage check fires.
    function test_ModifyLiquidities_IncreaseUntrackedOwnedPosition_Reverts() public {
        PoolKey memory poolKey = _wethUsdcPoolKey();
        _ensureWethUsdcPool();

        uint256 tokenId = _mintWethUsdcPosition(TICK_LOWER, TICK_UPPER, 1e13);

        // the `positions` mapping lives at base slot + 1 in the TokenIdsSlot struct
        bytes32 positionsEntrySlot = keccak256(
            abi.encode(tokenId, bytes32(uint256(StorageLib.UNIV4_TOKEN_IDS_SLOT) + 1))
        );
        assertGt(uint256(vm.load(pool, positionsEntrySlot)), 0, "tracking entry must exist before erasing");
        vm.store(pool, positionsEntrySlot, bytes32(0));

        bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(1e12), type(uint128).max, type(uint128).max, "");
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

        vm.prank(poolOwner);
        vm.expectRevert(IAUniswapRouter.PositionOwner.selector);
        IAUniswapRouter(pool).modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);
    }

    /// @notice Ports "should propagate string error from posm": the posm call is intercepted with
    ///         a revert payload encoding Error(string), and the adapter's catch path reverts with
    ///         the reason string.
    function test_ModifyLiquidities_PropagateStringError_FromPosm() public {
        vm.mockCallRevert(
            POSM,
            abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector),
            abi.encodeWithSignature("Error(string)", "posm string failure")
        );

        bytes memory unlockData = _encodeCloseCurrency(WETH);

        vm.prank(poolOwner);
        vm.expectRevert("posm string failure");
        IAUniswapRouter(pool).modifyLiquidities(unlockData, block.timestamp + 1 hours);
    }

    /// @notice Ports "should propagate custom error from posm": the posm call is intercepted with
    ///         raw custom-error bytes, and the adapter's catch path re-raises them unchanged.
    function test_ModifyLiquidities_PropagateCustomError_FromPosm() public {
        vm.mockCallRevert(
            POSM,
            abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector),
            abi.encodeWithSelector(IPosmCustomError.PosmCustomError.selector, uint256(42))
        );

        bytes memory unlockData = _encodeCloseCurrency(WETH);

        vm.prank(poolOwner);
        vm.expectRevert(abi.encodeWithSelector(IPosmCustomError.PosmCustomError.selector, uint256(42)));
        IAUniswapRouter(pool).modifyLiquidities(unlockData, block.timestamp + 1 hours);
    }

    /// @notice Ports "should not allow mint and increase liquidity in same call": the increase is
    ///         decoded before the mint executes, so the position info lookup marks the tokenId as
    ///         non-existent and the adapter reverts with PositionDoesNotExist after the posm call.
    function test_ModifyLiquidities_MintAndIncreaseInSameCall_Reverts() public {
        address ethPool = _createEthPool();
        PoolKey memory poolKey = _ethWethPoolKey();
        _ensureEthWethPool();

        deal(ethPool, 1 ether);
        deal(WETH, ethPool, 1 ether);

        uint256 expectedTokenId = IPositionManager(POSM).nextTokenId();

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.INCREASE_LIQUIDITY),
            uint8(Actions.SETTLE_PAIR)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            poolKey,
            TICK_LOWER,
            TICK_UPPER,
            1e13,
            uint128(0.01 ether),
            type(uint128).max,
            ethPool,
            ""
        );
        params[1] = abi.encode(expectedTokenId, uint256(6e12), uint128(0.01 ether), type(uint128).max, "");
        params[2] = abi.encode(poolKey.currency0, poolKey.currency1);

        vm.prank(poolOwner);
        vm.expectRevert(IAUniswapRouter.PositionDoesNotExist.selector);
        IAUniswapRouter(ethPool).modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);
    }

    /// @notice Ports "should increase liquidity".
    function test_ModifyLiquidities_IncreaseLiquidity() public {
        address ethPool = _createEthPool();
        PoolKey memory poolKey = _ethWethPoolKey();
        _ensureEthWethPool();

        deal(ethPool, 1 ether);
        deal(WETH, ethPool, 1 ether);

        uint256 tokenId = _mintEthWethPosition(ethPool, TICK_LOWER, TICK_UPPER, 1e13, 0.01 ether);

        bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(6e12), uint128(0.01 ether), type(uint128).max, "");
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

        vm.prank(poolOwner);
        IAUniswapRouter(ethPool).modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);

        assertEq(IPositionManager(POSM).getPositionLiquidity(tokenId), 1e13 + 6e12, "liquidity must increase");
        assertEq(IPosmErc721(POSM).ownerOf(tokenId), ethPool, "pool must own the position");
        assertEq(IPosmErc721(POSM).balanceOf(ethPool), 1, "pool must own a single position");
    }

    /// @notice Ports "should remove liquidity".
    function test_ModifyLiquidities_RemoveLiquidity() public {
        address ethPool = _createEthPool();
        PoolKey memory poolKey = _ethWethPoolKey();
        _ensureEthWethPool();

        deal(ethPool, 1 ether);
        deal(WETH, ethPool, 1 ether);

        uint256 tokenId = _mintEthWethPosition(ethPool, TICK_LOWER, TICK_UPPER, 1e13, 0.01 ether);
        _increaseLiquidity(ethPool, poolKey, tokenId, 6e12, 0.01 ether);

        uint256 wethBalanceBefore = IERC20(WETH).balanceOf(ethPool);

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(1.2e12), uint128(0), uint128(0), "");
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, ethPool);

        vm.prank(poolOwner);
        IAUniswapRouter(ethPool).modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);

        assertEq(IPositionManager(POSM).getPositionLiquidity(tokenId), 1e13 + 6e12 - 1.2e12, "liquidity must decrease");
        assertGt(IERC20(WETH).balanceOf(ethPool), wethBalanceBefore, "pool must collect the WETH proceeds");
    }

    /// @notice Ports "should burn owned position".
    function test_ModifyLiquidities_BurnOwnedPosition() public {
        address ethPool = _createEthPool();
        PoolKey memory poolKey = _ethWethPoolKey();
        _ensureEthWethPool();

        deal(ethPool, 1 ether);
        deal(WETH, ethPool, 1 ether);

        uint256 tokenId = _mintEthWethPosition(ethPool, TICK_LOWER, TICK_UPPER, 1e13, 0.01 ether);
        _increaseLiquidity(ethPool, poolKey, tokenId, 6e12, 0.01 ether);
        assertEq(IEApps(ethPool).getUniV4TokenIds().length, 1, "pool must track one position");

        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), "");
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, ethPool);

        vm.expectEmit(ethPool);
        emit IAUniswapRouter.UniV4PositionRemoved(tokenId);
        vm.prank(poolOwner);
        IAUniswapRouter(ethPool).modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);

        assertEq(IPositionManager(POSM).getPositionLiquidity(tokenId), 0, "position liquidity must be zero");
        assertEq(IEApps(ethPool).getUniV4TokenIds().length, 0, "pool must track no positions");
    }

    /// @notice Ports "should burn tokenId at a specific position": burning the first of three
    ///         tracked positions swap-and-pops the last tokenId into its slot.
    function test_ModifyLiquidities_BurnTokenIdAtSpecificPosition() public {
        address ethPool = _createEthPool();
        PoolKey memory poolKey = _ethWethPoolKey();
        _ensureEthWethPool();

        deal(ethPool, 1 ether);
        deal(WETH, ethPool, 1 ether);

        uint256 firstTokenId = _mintEthWethPosition(
            ethPool,
            abi.encodePacked(
                uint8(Actions.MINT_POSITION),
                uint8(Actions.MINT_POSITION),
                uint8(Actions.MINT_POSITION),
                uint8(Actions.SETTLE_PAIR)
            ),
            _threeMintParams(poolKey, ethPool, 0.01 ether)
        );

        uint256[] memory tokenIds = IEApps(ethPool).getUniV4TokenIds();
        assertEq(tokenIds.length, 3, "pool must track three positions");

        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(firstTokenId, uint128(0), uint128(0), "");
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, ethPool);

        vm.expectEmit(ethPool);
        emit IAUniswapRouter.UniV4PositionRemoved(firstTokenId);
        vm.prank(poolOwner);
        IAUniswapRouter(ethPool).modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);

        assertEq(IPositionManager(POSM).getPositionLiquidity(firstTokenId), 0, "burned liquidity must be zero");

        uint256[] memory remainingIds = IEApps(ethPool).getUniV4TokenIds();
        assertEq(remainingIds.length, 2, "two positions must remain");
        // swap-and-pop must move the last tokenId into the burned slot, preserving real tokenIds
        assertEq(remainingIds[0], firstTokenId + 2, "first remaining id must be the last minted");
        assertEq(remainingIds[1], firstTokenId + 1, "second remaining id must be the middle one");
    }

    /// @notice Ports "position should be included in nav calculations". The TS test asserted a
    ///         specific NAV-inflated unitary value produced by a mock posm that credited the
    ///         position without pulling tokens; here the fork-native equivalent is asserted: the
    ///         mint is NAV-neutral (tokens move from wallet into the position at the same oracle
    ///         valuation), and simulating the mock's "funds returned without burn" — tokens back
    ///         in the wallet while the position is still held — inflates NAV per share by
    ///         approximately the position value share, proving positions are counted in NAV.
    function test_ModifyLiquidities_PositionIncludedInNavCalculations() public {
        _ensureWethUsdcPool();

        // Rigoblock values only active tokens, so the free-dealt USDC wallet balance counts in
        // NAV only after a mint activates USDC; the baseline is taken after this first mint,
        // exactly like the post-mint value of the measured mint below
        _mintWethUsdcPosition(TICK_LOWER, TICK_UPPER, 1e12);

        uint256 unitaryValueBefore = _navNeutralBaseline();
        uint256 totalSupply = ISmartPoolState(pool).totalSupply();

        uint256 wethBalanceBefore = IERC20(WETH).balanceOf(pool);
        uint256 usdcBalanceBefore = IERC20(USDC).balanceOf(pool);

        uint256 tokenId = _mintWethUsdcPosition(TICK_LOWER, TICK_UPPER, 1e13);
        assertEq(IEApps(pool).getUniV4TokenIds().length, 2, "pool must track both positions");

        uint256 pulledWeth = wethBalanceBefore - IERC20(WETH).balanceOf(pool);
        uint256 pulledUsdc = usdcBalanceBefore - IERC20(USDC).balanceOf(pool);
        assertGt(pulledWeth, 0, "mint must pull WETH from the pool");
        assertGt(pulledUsdc, 0, "mint must pull USDC from the pool");

        address[] memory activeTokens = ISmartPoolState(pool).getActiveTokens().activeTokens;
        // WETH is the pool's base token (always active, never stored), so the position activates USDC only
        assertEq(activeTokens.length, 1, "USDC must be activated by the position");
        assertEq(activeTokens[0], USDC, "the activated token must be USDC");

        // the mint moves tokens from the wallet into the position at the same oracle valuation,
        // so NAV per share is unchanged up to fixed-point rounding between the wallet and
        // position valuation paths (observed deviation ~0.015%)
        uint256 unitaryValueAfterMint = _navNeutralBaseline();
        assertApproxEqAbs(
            unitaryValueAfterMint,
            unitaryValueBefore,
            unitaryValueBefore / 2000,
            "NAV per share must be neutral across the mint"
        );

        // simulate the mock's funds-returned-without-burn: the wallet regains the pulled tokens
        // while the position is still held
        deal(WETH, pool, wethBalanceBefore);
        deal(USDC, pool, usdcBalanceBefore);

        ISmartPoolActions(pool).updateUnitaryValue();
        uint256 unitaryValueAfterDuplication = ISmartPoolState(pool).getPoolTokens().unitaryValue;

        // expected inflation: the measured position's underlying amounts valued at the same
        // oracle cross price EApps uses, converted to base token
        int24 twapWeth = IEOracle(pool).getTwap(WETH);
        int24 twapUsdc = IEOracle(pool).getTwap(USDC);
        uint160 crossPrice = TickMath.getSqrtPriceAtTick(twapUsdc - twapWeth);
        (uint256 positionWeth, uint256 positionUsdc) = LiquidityAmounts.getAmountsForLiquidity(
            crossPrice,
            TickMath.getSqrtPriceAtTick(TICK_LOWER),
            TickMath.getSqrtPriceAtTick(TICK_UPPER),
            1e13
        );
        uint256 positionValue = positionWeth +
            uint256(IEOracle(pool).convertTokenAmount(USDC, int256(positionUsdc), WETH));
        uint256 expectedIncrease = (positionValue * 1e18) / totalSupply;

        assertGt(
            unitaryValueAfterDuplication,
            unitaryValueAfterMint,
            "double-counted position must inflate NAV per share"
        );
        assertApproxEqRel(
            unitaryValueAfterDuplication,
            unitaryValueAfterMint + expectedIncrease,
            0.02e18,
            "NAV must increase by approximately the position value share"
        );

        assertEq(IEApps(pool).getUniV4TokenIds()[1], tokenId, "tracked tokenId must match");
    }

    /// @notice Ports "should decode payment methods": exercises every payment-action decode branch
    ///         against the real posm. The TS sequence relied on the mock not moving funds; here the
    ///         settle/take amounts are made consistent (settled balances are taken back, wrap is
    ///         unwrapped and taken) so the real posm's zero-delta invariant holds.
    function test_ModifyLiquidities_DecodePaymentMethods() public {
        address ethPool = _createEthPool();
        _ensureEthWethPool();

        bytes memory unlockData = _paymentMethodsPlan(ethPool);

        // pool has no native balance: the derived value (WRAP amount) exceeds the balance
        vm.prank(poolOwner);
        vm.expectRevert(IAUniswapRouter.InsufficientNativeBalance.selector);
        IAUniswapRouter(ethPool).modifyLiquidities(unlockData, block.timestamp + 1 hours);

        deal(ethPool, 1 ether);
        vm.prank(poolOwner);
        IAUniswapRouter(ethPool).modifyLiquidities(unlockData, block.timestamp + 1 hours);

        assertEq(address(ethPool).balance, 1 ether, "wrap/unwrap roundtrip must preserve the pool's balance");
        assertEq(IERC20(WETH).balanceOf(POSM), 0, "posm must hold no leftover WETH");
    }

    /// @notice Ports "should decode WRAP with CONTRACT_BALANCE flag without overflow": the sentinel
    ///         amount must not be added to the forwarded native value.
    function test_ModifyLiquidities_WrapContractBalanceFlag() public {
        uint256 contractBalance = uint256(0x8000000000000000000000000000000000000000000000000000000000000000);
        bytes memory actions = abi.encodePacked(uint8(Actions.WRAP));
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(contractBalance);

        vm.prank(poolOwner);
        IAUniswapRouter(pool).modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);

        assertEq(IERC20(WETH).balanceOf(POSM), 0, "posm must hold no WETH");
    }

    /// @notice Ports "should revert when calling unsupported methods".
    function test_ModifyLiquidities_UnsupportedMethodsRevert() public {
        bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY_FROM_DELTAS));
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(uint256(0), uint128(0), uint128(0), "");

        vm.prank(poolOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAUniswapRouter.UnsupportedAction.selector,
                uint256(Actions.INCREASE_LIQUIDITY_FROM_DELTAS)
            )
        );
        IAUniswapRouter(pool).modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);

        actions = abi.encodePacked(uint8(Actions.MINT_POSITION_FROM_DELTAS));
        params = new bytes[](1);
        PoolKey memory poolKey = _wethUsdcPoolKey();
        params[0] = abi.encode(poolKey, int24(0), int24(0), uint128(0), uint128(0), pool, "");

        vm.prank(poolOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAUniswapRouter.UnsupportedAction.selector,
                uint256(Actions.MINT_POSITION_FROM_DELTAS)
            )
        );
        IAUniswapRouter(pool).modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);

        // DONATE (0x0a) is below SETTLE but is not a position action: unsupported in modifyLiquidities.
        actions = abi.encodePacked(uint8(Actions.DONATE));
        params = new bytes[](1);
        params[0] = hex"";

        vm.prank(poolOwner);
        vm.expectRevert(abi.encodeWithSelector(IAUniswapRouter.UnsupportedAction.selector, uint256(Actions.DONATE)));
        IAUniswapRouter(pool).modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);

        // SETTLE_ALL (0x0c) is a settle-category action that is only supported inside V4_SWAP.
        actions = abi.encodePacked(uint8(Actions.SETTLE_ALL));
        params = new bytes[](1);
        params[0] = hex"";

        vm.prank(poolOwner);
        vm.expectRevert(
            abi.encodeWithSelector(IAUniswapRouter.UnsupportedAction.selector, uint256(Actions.SETTLE_ALL))
        );
        IAUniswapRouter(pool).modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);
    }

    /// @notice Ports "should decode CLOSE_CURRENCY action": supported currencies pass, tokens
    ///         without a price feed revert.
    function test_ModifyLiquidities_DecodeCloseCurrency() public {
        bytes memory actions = abi.encodePacked(uint8(Actions.CLOSE_CURRENCY));
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(WETH);

        vm.prank(poolOwner);
        IAUniswapRouter(pool).modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);

        // native ETH always has a price feed as base token
        params[0] = abi.encode(address(0));
        vm.prank(poolOwner);
        IAUniswapRouter(pool).modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);

        address noFeedToken = makeAddr("noFeedToken");
        params[0] = abi.encode(noFeedToken);
        vm.prank(poolOwner);
        vm.expectRevert(abi.encodeWithSelector(EnumerableSet.TokenPriceFeedDoesNotExist.selector, noFeedToken));
        IAUniswapRouter(pool).modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);
    }

    /// @notice Ports "returns gas cost for eth pool mint with 1 uni v4 liquidity position": executes
    ///         the same flow and logs the gas used by share mints/burns as the position count grows.
    function test_ModifyLiquidities_GasCosts() public {
        address ethPool = _createEthPool();
        PoolKey memory poolKey = _ethWethPoolKey();
        _ensureEthWethPool();

        deal(ethPool, 2 ether);
        deal(poolOwner, 20 ether);

        uint256 gasUsed = _logMintGas(ethPool, "first mint gas cost, with no position");

        deal(WETH, ethPool, 1 ether);
        uint256 firstTokenId = _mintEthWethPosition(ethPool, TICK_LOWER, TICK_UPPER, 1e13, 0.01 ether);

        gasUsed = _logMintGas(ethPool, "second mint gas cost, with 1 position");
        assertGt(gasUsed, 0);

        _mintEthWethPosition(ethPool, TICK_LOWER, TICK_UPPER - 60, 1e13, 0.01 ether);
        gasUsed = _logMintGas(ethPool, "third mint gas cost, with 2 positions");
        assertGt(gasUsed, 0);

        _increaseLiquidity(ethPool, poolKey, firstTokenId, 1e12, 0.01 ether);

        vm.warp(block.timestamp + 30 days);
        uint256 burnGas = _logBurnGas(ethPool, "burn gas cost, with 2 positions");
        assertGt(burnGas, 0);
    }

    // --- helpers ---

    function _wethUsdcPoolKey() private pure returns (PoolKey memory) {
        return
            PoolKey({
                currency0: Currency.wrap(WETH),
                currency1: Currency.wrap(USDC),
                fee: 0,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            });
    }

    function _ethWethPoolKey() private pure returns (PoolKey memory) {
        return
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(WETH),
                fee: 0,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            });
    }

    function _createEthPool() private returns (address ethPool) {
        vm.prank(poolOwner);
        (ethPool, ) = IRigoblockPoolProxyFactory(FACTORY).createPool("EthBasePool", "ETHB", address(0));
    }

    function _ensureWethUsdcPool() private {
        if (!wethUsdcPoolInitialized) {
            IPositionManager(POSM).initializePool(_wethUsdcPoolKey(), SQRT_PRICE_WETH_USDC);
            wethUsdcPoolInitialized = true;
        }
    }

    function _ensureEthWethPool() private {
        if (!ethWethPoolInitialized) {
            IPositionManager(POSM).initializePool(_ethWethPoolKey(), SQRT_PRICE_ETH_WETH);
            ethWethPoolInitialized = true;
        }
    }

    function _encodeMintAndSettlePair(
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity,
        uint128 amount0Max,
        address owner
    ) private pure returns (bytes memory) {
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(poolKey, tickLower, tickUpper, liquidity, amount0Max, type(uint128).max, owner, "");
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        return abi.encode(actions, params);
    }

    function _mintEthWethPosition(
        address ethPool,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity,
        uint128 amount0Max
    ) private returns (uint256 tokenId) {
        tokenId = IPositionManager(POSM).nextTokenId();
        bytes memory unlockData = _encodeMintAndSettlePair(
            _ethWethPoolKey(),
            tickLower,
            tickUpper,
            liquidity,
            amount0Max,
            ethPool
        );
        vm.prank(poolOwner);
        IAUniswapRouter(ethPool).modifyLiquidities(unlockData, block.timestamp + 1 hours);
    }

    function _mintEthWethPosition(
        address ethPool,
        bytes memory actions,
        bytes[] memory params
    ) private returns (uint256 tokenId) {
        tokenId = IPositionManager(POSM).nextTokenId();
        vm.prank(poolOwner);
        IAUniswapRouter(ethPool).modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);
    }

    function _mintWethUsdcPosition(
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity
    ) private returns (uint256 tokenId) {
        tokenId = IPositionManager(POSM).nextTokenId();
        bytes memory unlockData = _encodeMintAndSettlePair(
            _wethUsdcPoolKey(),
            tickLower,
            tickUpper,
            liquidity,
            type(uint128).max,
            pool
        );
        vm.prank(poolOwner);
        IAUniswapRouter(pool).modifyLiquidities(unlockData, block.timestamp + 1 hours);
    }

    function _threeMintParams(
        PoolKey memory poolKey,
        address owner,
        uint128 amount0Max
    ) private pure returns (bytes[] memory params) {
        params = new bytes[](4);
        params[0] = abi.encode(poolKey, TICK_LOWER, TICK_UPPER, 1e13, amount0Max, type(uint128).max, owner, "");
        params[1] = abi.encode(poolKey, TICK_LOWER, TICK_UPPER - 60, 1e13, amount0Max, type(uint128).max, owner, "");
        params[2] = abi.encode(poolKey, TICK_LOWER, TICK_UPPER - 120, 1e13, amount0Max, type(uint128).max, owner, "");
        params[3] = abi.encode(poolKey.currency0, poolKey.currency1);
    }

    function _increaseLiquidity(
        address ethPool,
        PoolKey memory poolKey,
        uint256 tokenId,
        uint256 liquidity,
        uint128 amount0Max
    ) private {
        bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidity, amount0Max, type(uint128).max, "");
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        vm.prank(poolOwner);
        IAUniswapRouter(ethPool).modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);
    }

    function _paymentMethodsPlan(address ethPool) private view returns (bytes memory) {
        // Wrap converts the forwarded native value into posm-owned WETH; settling it as WETH
        // credits the pool manager, which is then taken back by the pool. Every manager delta is
        // zero at the end of the unlock, as the real PoolManager requires.
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SETTLE_PAIR),
            uint8(Actions.TAKE_PAIR),
            uint8(Actions.SETTLE),
            uint8(Actions.SETTLE),
            uint8(Actions.CLEAR_OR_TAKE),
            uint8(Actions.SWEEP),
            uint8(Actions.WRAP),
            uint8(Actions.UNWRAP),
            uint8(Actions.SETTLE),
            uint8(Actions.TAKE)
        );
        bytes[] memory params = new bytes[](10);
        params[0] = abi.encode(USDC, WETH);
        params[1] = abi.encode(USDC, WETH, ethPool);
        params[2] = abi.encode(USDC, uint256(0), true);
        params[3] = abi.encode(address(0), uint256(0), false);
        params[4] = abi.encode(USDC, uint256(0));
        params[5] = abi.encode(WETH, ethPool);
        params[6] = abi.encode(uint256(0.5 ether));
        params[7] = abi.encode(uint256(0.5 ether));
        params[8] = abi.encode(address(0), uint256(0.5 ether), false);
        params[9] = abi.encode(address(0), ethPool, uint256(0.5 ether));
        return abi.encode(actions, params);
    }

    /// @dev Mines a CREATE2 salt so the deployed hook address carries both liquidity-delta
    ///      permission bits plus the companion after-add/remove flags required by PoolManager's
    ///      hook address validation (a delta flag without its action flag is rejected). The swap
    ///      delta bits are excluded outright (a stricter subset of the same rule). Any other
    ///      randomly set bits are fine: every IHooks function is implemented and returns its
    ///      selector, so the PoolManager calls succeed.
    function _mineDeltaHook() private returns (address hook) {
        uint160 requiredFlags = Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG |
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
        uint160 excludedFlags = Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        bytes32 initCodeHash = keccak256(type(DeltaHook).creationCode);
        uint256 salt;
        while (true) {
            hook = vm.computeCreate2Address(bytes32(salt), initCodeHash, address(this));
            uint160 flags = uint160(hook);
            if (flags & requiredFlags == requiredFlags && flags & excludedFlags == 0) {
                break;
            }
            salt++;
        }
        hook = address(new DeltaHook{salt: bytes32(salt)}());
    }

    function _encodeCloseCurrency(address currency) private pure returns (bytes memory) {
        bytes memory actions = abi.encodePacked(uint8(Actions.CLOSE_CURRENCY));
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(currency);
        return abi.encode(actions, params);
    }

    /// @dev Recomputes and returns the stored unitary value, so the baseline includes the LP
    ///      position and the free-dealt USDC exactly like the post-mint value does.
    function _navNeutralBaseline() private returns (uint256 unitaryValue) {
        ISmartPoolActions(pool).updateUnitaryValue();
        unitaryValue = ISmartPoolState(pool).getPoolTokens().unitaryValue;
    }

    function _logMintGas(address ethPool, string memory label) private returns (uint256 gasUsed) {
        vm.prank(poolOwner);
        uint256 gasBefore = gasleft();
        ISmartPoolActions(ethPool).mint{value: 1 ether}(poolOwner, 1 ether, 0);
        gasUsed = gasBefore - gasleft();
        console2.log(label, gasUsed);
    }

    function _logBurnGas(address ethPool, string memory label) private returns (uint256 gasUsed) {
        vm.prank(poolOwner);
        uint256 gasBefore = gasleft();
        ISmartPoolActions(ethPool).burn(0.5 ether, 0);
        gasUsed = gasBefore - gasleft();
        console2.log(label, gasUsed);
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
