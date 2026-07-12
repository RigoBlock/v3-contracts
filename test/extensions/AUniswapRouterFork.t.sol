// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Constants} from "../../contracts/test/Constants.sol";

import {AUniswapRouter} from "../../contracts/protocol/extensions/adapters/AUniswapRouter.sol";
import {EApps} from "../../contracts/protocol/extensions/EApps.sol";
import {ECrosschain} from "../../contracts/protocol/extensions/ECrosschain.sol";
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
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {DeploymentParams, Extensions, EAppsParams} from "../../contracts/protocol/types/DeploymentParams.sol";

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

        address aUniswapRouter = address(new AUniswapRouter(UNIVERSAL_ROUTER, POSM, WETH));

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
                eGmxCallback: address(0)
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
        _addOrReplaceMethod(IAUniswapRouter.modifyLiquidities.selector, aUniswapRouter);
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

    function _addOrReplaceMethod(bytes4 selector, address adapter) private {
        IAuthority authority = IAuthority(AUTHORITY);
        address current = authority.getApplicationAdapter(selector);
        if (current != address(0)) {
            authority.removeMethod(selector, current);
        }
        authority.addMethod(selector, adapter);
    }
}
