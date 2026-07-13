// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { Constants } from "../../contracts/test/Constants.sol";

import { AGmxV2 } from "../../contracts/protocol/extensions/adapters/AGmxV2.sol";
import { AUniswapRouter } from "../../contracts/protocol/extensions/adapters/AUniswapRouter.sol";
import { EApps } from "../../contracts/protocol/extensions/EApps.sol";
import { ECrosschain } from "../../contracts/protocol/extensions/ECrosschain.sol";
import { EGmxCallback } from "../../contracts/protocol/extensions/EGmxCallback.sol";
import { ENavView } from "../../contracts/protocol/extensions/ENavView.sol";
import { EOracle } from "../../contracts/protocol/extensions/EOracle.sol";
import { EUpgrade } from "../../contracts/protocol/extensions/EUpgrade.sol";
import { SmartPool } from "../../contracts/protocol/SmartPool.sol";
import { ExtensionsMapDeployer } from "../../contracts/protocol/deps/ExtensionsMapDeployer.sol";
import { IRigoblockPoolProxyFactory } from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import { IAuthority } from "../../contracts/protocol/interfaces/IAuthority.sol";
import { IOwnedUninitialized } from "../../contracts/utils/owned/IOwnedUninitialized.sol";
import { IPoolRegistry } from "../../contracts/protocol/interfaces/IPoolRegistry.sol";

import { ISmartPoolActions } from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import { ISmartPoolState } from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import { IERC20 } from "../../contracts/protocol/interfaces/IERC20.sol";
import { IAGmxV2 } from "../../contracts/protocol/extensions/adapters/interfaces/IAGmxV2.sol";
import { IAStaking } from "../../contracts/protocol/extensions/adapters/interfaces/IAStaking.sol";
import { IAUniswapRouter } from "../../contracts/protocol/extensions/adapters/interfaces/IAUniswapRouter.sol";
import { IEApps } from "../../contracts/protocol/extensions/adapters/interfaces/IEApps.sol";
import { IENavView } from "../../contracts/protocol/extensions/adapters/interfaces/IENavView.sol";

import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import { NavView } from "../../contracts/protocol/libraries/NavView.sol";
import { GmxLib } from "../../contracts/protocol/libraries/GmxLib.sol";
import { IStaking } from "../../contracts/staking/interfaces/IStaking.sol";

import { DeploymentParams, Extensions, EAppsParams } from "../../contracts/protocol/types/DeploymentParams.sol";
import { NetAssetsValue } from "../../contracts/protocol/types/NavComponents.sol";
import {
    IGmxReader,
    IGmxDataStore,
    IGmxRoleStore,
    IGmxOrderHandler,
    IGmxChainlinkPriceFeedProvider,
    GmxValidatedPrice
} from "../../contracts/utils/exchanges/gmx/IGmxSynthetics.sol";
import { Market } from "gmx-synthetics/market/Market.sol";
import { Order } from "gmx-synthetics/order/Order.sol";
import { IBaseOrderUtils } from "gmx-synthetics/order/IBaseOrderUtils.sol";

/// @dev Minimal GrgVault interface to read the GRG transfer proxy address.
interface IGrgVaultWithAssetProxy {
    function grgAssetProxy() external view returns (address);
}

/// @title NavViewStressedParityForkTest
/// @notice Verifies that ENavView.getNavDataView() matches updateUnitaryValue() under
///   stressed conditions on Arbitrum: an open GMX v2 position, GRG staking, and extreme
///   price movements including the totalValue <= 0 sentinel edge case.
contract NavViewStressedParityForkTest is Test {
    // =========================================================================
    // Constants
    // =========================================================================

    address private constant AUTHORITY = Constants.AUTHORITY;
    address private constant FACTORY = Constants.FACTORY;
    address private constant TOKEN_JAR = Constants.TOKEN_JAR;

    // GMX Arbitrum addresses
    address private constant GMX_EXCHANGE_ROUTER = Constants.ARB_GMX_EXCHANGE_ROUTER;
    address private constant GMX_DATA_STORE = Constants.ARB_GMX_DATA_STORE;
    address private constant GMX_READER = Constants.ARB_GMX_READER;
    address private constant GMX_CHAINLINK_PRICE_FEED = Constants.ARB_GMX_CHAINLINK_PRICE_FEED;
    address private constant GMX_REFERRAL_STORAGE = Constants.ARB_GMX_REFERRAL_STORAGE;
    address private constant GMX_ETH_USD_MARKET = Constants.ARB_GMX_ETH_USD_MARKET;
    address private constant GMX_ROLE_STORE = Constants.ARB_GMX_ROLE_STORE;
    address private constant GMX_ORACLE_ADDRESS = 0x7F01614cA5198Ec979B1aAd1DAF0DE7e0a215BDF;

    // Arbitrum chain-specific addresses
    address private constant ARB_WETH = Constants.ARB_WETH;
    address private constant ARB_USDC = Constants.ARB_USDC;
    address private constant ARB_ORACLE = Constants.ARB_ORACLE;
    address private constant ARB_GRG_STAKING = Constants.ARB_GRG_STAKING;
    address private constant ARB_UNISWAP_V4_POSM = Constants.ARB_UNISWAP_V4_POSM;
    address private constant ARB_UNIVERSAL_ROUTER = Constants.ARB_UNIVERSAL_ROUTER;

    /// @dev GMX USD precision — 30 decimal places.
    uint256 private constant GMX_USD = 1e30;

    /// @dev USDC collateral amount for the test GMX position.
    uint256 private constant COLLATERAL_AMOUNT_USDC = 1_000e6;

    /// @dev Position size: 2× leverage on 1 000 USDC collateral.
    uint256 private constant SIZE_DELTA_USD = 2_000 * GMX_USD;

    /// @dev Amount of GRG to stake into the Arbitrum staking system.
    uint256 private constant STAKE_AMOUNT = 50e18;

    // =========================================================================
    // State
    // =========================================================================

    address private poolOwner;
    address private pool;
    address private grgToken;
    address private grgTransferProxy;

    // =========================================================================
    // setUp
    // =========================================================================

    function setUp() public {
        // Create Arbitrum fork
        vm.createSelectFork("arbitrum", Constants.ARB_BLOCK);

        // Guard: if the RPC does not serve state at ARB_BLOCK, contracts have no code.
        require(
            address(GMX_READER).code.length > 0,
            "Fork guard: GMX Reader has no code at ARB_BLOCK - check ARBITRUM_MAINNET_RPC_URL"
        );

        // Set a realistic gas price so computeExecutionFee returns a non-zero value.
        vm.txGasPrice(1 gwei);

        poolOwner = makeAddr("poolOwner");

        // ------------------------------------------------------------------
        // 1. Deploy adapters
        // ------------------------------------------------------------------
        grgToken = address(IStaking(ARB_GRG_STAKING).getGrgContract());
        grgTransferProxy = IGrgVaultWithAssetProxy(address(IStaking(ARB_GRG_STAKING).getGrgVault())).grgAssetProxy();
        address eGmxCallback = address(new EGmxCallback());
        (address agmxV2, address aStaking, address aUniswapRouter) = _deployAdapters();

        // ------------------------------------------------------------------
        // 2. Deploy extensions and ExtensionsMap
        // ------------------------------------------------------------------
        DeploymentParams memory params = _deployExtensions(eGmxCallback);
        ExtensionsMapDeployer mapDeployer = new ExtensionsMapDeployer();
        bytes32 salt = keccak256(abi.encodePacked("NAV_VIEW_STRESSED_PARITY_FORK_V1", block.chainid));
        address extensionsMap = mapDeployer.deployExtensionsMap(params, salt);

        // ------------------------------------------------------------------
        // 3. Deploy and register new SmartPool implementation
        // ------------------------------------------------------------------
        SmartPool impl = new SmartPool(AUTHORITY, extensionsMap, TOKEN_JAR);

        address registry = IRigoblockPoolProxyFactory(FACTORY).getRegistry();
        address rigoblockDao = IPoolRegistry(registry).rigoblockDao();
        vm.prank(rigoblockDao);
        IRigoblockPoolProxyFactory(FACTORY).setImplementation(address(impl));

        // ------------------------------------------------------------------
        // 4. Create pool with WETH as base token
        // ------------------------------------------------------------------
        vm.prank(poolOwner);
        (pool,) = IRigoblockPoolProxyFactory(FACTORY).createPool("NavStressedPool", "NVSP", ARB_WETH);
        console2.log("Pool created:", pool);

        // ------------------------------------------------------------------
        // 5. Register adapters in Authority and whitelist selectors
        // ------------------------------------------------------------------
        _registerAdapters(agmxV2, aStaking, aUniswapRouter);

        // ------------------------------------------------------------------
        // 6. Fund pool with WETH (covers execution fees), USDC and GRG
        // ------------------------------------------------------------------
        deal(ARB_WETH, pool, 10 ether);
        deal(ARB_USDC, pool, 2_000e6);
        deal(grgToken, pool, STAKE_AMOUNT);
    }

    function _deployAdapters()
        private
        returns (address agmxV2, address aStaking, address aUniswapRouter)
    {
        agmxV2 = address(new AGmxV2());
        aStaking = deployCode("out/AStaking.sol/AStaking.json", abi.encode(ARB_GRG_STAKING, grgToken, grgTransferProxy));
        aUniswapRouter = address(new AUniswapRouter(ARB_UNIVERSAL_ROUTER, ARB_UNISWAP_V4_POSM, ARB_WETH));
    }

    function _deployExtensions(address eGmxCallback)
        private
        returns (DeploymentParams memory params)
    {
        EApps eApps = new EApps(EAppsParams({ grgStakingProxy: ARB_GRG_STAKING, univ4Posm: ARB_UNISWAP_V4_POSM }));
        EOracle eOracle = new EOracle(ARB_ORACLE, ARB_WETH);
        EUpgrade eUpgrade = new EUpgrade(FACTORY);
        ENavView eNavView =
            new ENavView(EAppsParams({ grgStakingProxy: ARB_GRG_STAKING, univ4Posm: ARB_UNISWAP_V4_POSM }));
        ECrosschain eCrosschain = new ECrosschain();

        params = DeploymentParams({
            extensions: Extensions({
                eApps: address(eApps),
                eOracle: address(eOracle),
                eUpgrade: address(eUpgrade),
                eNavView: address(eNavView),
                eCrosschain: address(eCrosschain),
                eGmxCallback: eGmxCallback
            }),
            wrappedNative: ARB_WETH
        });
    }

    function _registerAdapters(address agmxV2, address aStaking, address aUniswapRouter) private {
        address authorityOwner = IOwnedUninitialized(AUTHORITY).owner();
        vm.startPrank(authorityOwner);

        IAuthority authority = IAuthority(AUTHORITY);
        authority.setAdapter(agmxV2, true);
        if (!authority.isWhitelister(authorityOwner)) {
            authority.setWhitelister(authorityOwner, true);
        }

        _addOrReplaceMethod(authority, IAGmxV2.createIncreaseOrder.selector, agmxV2);
        _addOrReplaceMethod(authority, IAGmxV2.createDecreaseOrder.selector, agmxV2);
        _addOrReplaceMethod(authority, IAGmxV2.updateOrder.selector, agmxV2);
        _addOrReplaceMethod(authority, IAGmxV2.cancelOrder.selector, agmxV2);
        _addOrReplaceMethod(authority, IAGmxV2.claimFundingFees.selector, agmxV2);
        _addOrReplaceMethod(authority, IAGmxV2.claimCollateral.selector, agmxV2);

        authority.setAdapter(aStaking, true);
        _addOrReplaceMethod(authority, IAStaking.stake.selector, aStaking);
        _addOrReplaceMethod(authority, IAStaking.undelegateStake.selector, aStaking);
        _addOrReplaceMethod(authority, IAStaking.unstake.selector, aStaking);
        _addOrReplaceMethod(authority, IAStaking.withdrawDelegatorRewards.selector, aStaking);

        authority.setAdapter(aUniswapRouter, true);
        _addOrReplaceMethod(authority, IAUniswapRouter.modifyLiquidities.selector, aUniswapRouter);

        vm.stopPrank();
    }

    function _addOrReplaceMethod(IAuthority authority, bytes4 selector, address adapter) private {
        address current = authority.getApplicationAdapter(selector);
        if (current != address(0)) {
            authority.removeMethod(selector, current);
        }
        authority.addMethod(selector, adapter);
    }

    // =========================================================================
    // Test
    // =========================================================================

    /// @notice ENavView and updateUnitaryValue agree under a stressed portfolio:
    ///   minted WETH shares, a Uniswap V4 LP position, an open USDC-collateral
    ///   GMX long, and staked GRG. The test also covers the totalValue <= 0
    ///   sentinel edge case.
    function test_NavParity_StressedConditionsAndSentinel() public {
        // ── Mint WETH shares so totalSupply > 0 ──────────────────────────────
        uint256 mintWeth = 1 ether;
        deal(ARB_WETH, poolOwner, mintWeth);
        vm.startPrank(poolOwner);
        IERC20(ARB_WETH).approve(pool, mintWeth);
        ISmartPoolActions(pool).mint(poolOwner, mintWeth, 0);
        vm.stopPrank();

        // ── Open a small Uniswap V4 WETH/USDC LP position ────────────────────
        _mintUniV4Position();

        // ── Open a 2× leveraged USDC-collateral GMX long ─────────────────────
        vm.prank(poolOwner);
        bytes32 orderKey = IAGmxV2(pool).createIncreaseOrder(_usdcIncreaseParams());
        _executeOrder(orderKey, GMX_ETH_USD_MARKET);

        // ── Stake GRG through the pool ───────────────────────────────────────
        vm.prank(poolOwner);
        IAStaking(pool).stake(STAKE_AMOUNT);

        // ── Positive PnL: mock GMX Chainlink oracle +10% on WETH ─────────────
        GmxValidatedPrice memory realPrice =
            IGmxChainlinkPriceFeedProvider(GMX_CHAINLINK_PRICE_FEED).getOraclePrice(ARB_WETH, "");

        vm.mockCall(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeCall(IGmxChainlinkPriceFeedProvider.getOraclePrice, (ARB_WETH, "")),
            abi.encode(
                GmxValidatedPrice({
                    token: ARB_WETH,
                    min: realPrice.min * 110 / 100,
                    max: realPrice.max * 110 / 100,
                    timestamp: realPrice.timestamp,
                    blockNumber: realPrice.blockNumber
                })
            )
        );

        NetAssetsValue memory writeNavHigh = ISmartPoolActions(pool).updateUnitaryValue();
        NavView.NavData memory viewNavHigh = IENavView(pool).getNavDataView();
        vm.clearMockedCalls();

        assertEq(
            viewNavHigh.unitaryValue, writeNavHigh.unitaryValue, "view-NAV and write-NAV must agree at +10% WETH price"
        );
        assertEq(viewNavHigh.totalValue, writeNavHigh.netTotalValue, "totalValue must agree at +10% WETH price");
        assertGt(writeNavHigh.unitaryValue, 1e18, "NAV must exceed par after positive PnL");

        // ── Sentinel case: close the GMX position, unwind staking, and drain all
        //   liquid assets so totalValue <= 0.
        vm.prank(poolOwner);
        bytes32 closeKey = IAGmxV2(pool).createDecreaseOrder(_usdcDecreaseParams());
        _executeOrder(closeKey, GMX_ETH_USD_MARKET);

        vm.startPrank(poolOwner);
        IAStaking(pool).undelegateStake(STAKE_AMOUNT);
        IAStaking(pool).unstake(STAKE_AMOUNT);
        vm.stopPrank();

        // ── Burn the Uni V4 LP so the drained pool has no remaining value ───
        _burnUniV4Position();

        deal(grgToken, pool, 0);
        deal(ARB_USDC, pool, 0);
        deal(ARB_WETH, pool, 0);

        NetAssetsValue memory writeNavSentinel = ISmartPoolActions(pool).updateUnitaryValue();
        NavView.NavData memory viewNavSentinel = IENavView(pool).getNavDataView();

        assertEq(
            viewNavSentinel.unitaryValue,
            writeNavSentinel.unitaryValue,
            "view-NAV and write-NAV must agree in sentinel case"
        );
        assertEq(viewNavSentinel.totalValue, writeNavSentinel.netTotalValue, "totalValue must agree in sentinel case");
        assertEq(writeNavSentinel.unitaryValue, 1, "NAV must be sentinel 1 when totalValue <= 0");
    }

    // =========================================================================
    // Private helpers
    // =========================================================================

    /// @dev Builds the WETH/USDC PoolKey used in the Uni V4 LP helpers.
    /// @notice WETH address is numerically smaller than USDC on Arbitrum, so WETH is currency0.
    function _uniV4PoolKey() private pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(ARB_WETH),
            currency1: Currency.wrap(ARB_USDC),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    /// @dev Initializes the WETH/USDC pool and mints a small full-range LP position through the pool.
    function _mintUniV4Position() private {
        PoolKey memory poolKey = _uniV4PoolKey();

        // Initialize the pool at ~3000 USDC/WETH if it does not already exist.
        IPositionManager(ARB_UNISWAP_V4_POSM).initializePool(
            poolKey, uint160(4_339_505_179_874_779_475_002_393)
        );

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

        vm.prank(poolOwner);
        IAUniswapRouter(pool).modifyLiquidities(unlockData, block.timestamp + 1 hours);
    }

    /// @dev Burns the pool's Uni V4 LP position and takes the proceeds back to the pool.
    function _burnUniV4Position() private {
        uint256[] memory tokenIds = IEApps(pool).getUniV4TokenIds();
        if (tokenIds.length == 0) return;

        PoolKey memory poolKey = _uniV4PoolKey();
        uint256 tokenId = tokenIds[0];

        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), "");
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, pool);
        bytes memory unlockData = abi.encode(actions, params);

        vm.prank(poolOwner);
        IAUniswapRouter(pool).modifyLiquidities(unlockData, block.timestamp + 1 hours);
    }

    /// @dev Returns CreateOrderParams for a 2× leveraged USDC-collateral ETH/USD long.
    function _usdcIncreaseParams() private pure returns (IBaseOrderUtils.CreateOrderParams memory) {
        return _usdcOrderParams(true);
    }

    /// @dev Returns CreateOrderParams for a full close of the USDC-collateral long.
    function _usdcDecreaseParams() private pure returns (IBaseOrderUtils.CreateOrderParams memory) {
        return _usdcOrderParams(false);
    }

    /// @dev Shared builder for the test USDC-collateral long position.
    function _usdcOrderParams(bool isIncrease) private pure returns (IBaseOrderUtils.CreateOrderParams memory) {
        return IBaseOrderUtils.CreateOrderParams({
            addresses: IBaseOrderUtils.CreateOrderParamsAddresses({
                receiver: address(0),
                cancellationReceiver: address(0),
                callbackContract: address(0),
                uiFeeReceiver: address(0),
                market: GMX_ETH_USD_MARKET,
                initialCollateralToken: ARB_USDC,
                swapPath: new address[](0)
            }),
            numbers: IBaseOrderUtils.CreateOrderParamsNumbers({
                sizeDeltaUsd: SIZE_DELTA_USD,
                initialCollateralDeltaAmount: isIncrease ? COLLATERAL_AMOUNT_USDC : 0,
                triggerPrice: 0,
                acceptablePrice: isIncrease ? type(uint256).max : 0, // Long: accept any price
                executionFee: 0,
                callbackGasLimit: 0,
                minOutputAmount: 0,
                validFromTime: 0
            }),
            orderType: isIncrease ? Order.OrderType.MarketIncrease : Order.OrderType.MarketDecrease,
            decreasePositionSwapType: Order.DecreasePositionSwapType.NoSwap,
            isLong: true,
            shouldUnwrapNativeToken: false,
            autoCancel: false,
            referralCode: bytes32(0),
            dataList: new bytes32[](0)
        });
    }

    // =========================================================================
    // Keeper execution helpers (mirrors AGmxV2Fork.t.sol)
    // =========================================================================

    struct OracleProviderEntry {
        address token;
        bytes32 key;
        address originalProvider;
    }

    function _getController() private view returns (address) {
        return IGmxRoleStore(GMX_ROLE_STORE).getRoleMembers(keccak256(abi.encode("CONTROLLER")), 0, 1)[0];
    }

    function _oracleProviderKey(address oracleContract, address token) private pure returns (bytes32) {
        bytes32 prefix = keccak256(abi.encode("ORACLE_PROVIDER_FOR_TOKEN"));
        return keccak256(abi.encode(prefix, oracleContract, token));
    }

    function _prepareOracleProviders(address market) private returns (OracleProviderEntry[] memory entries) {
        Market.Props memory mkt = IGmxReader(GMX_READER).getMarket(GMX_DATA_STORE, market);
        address controller = _getController();

        address[3] memory rawTokens = [mkt.indexToken, mkt.longToken, mkt.shortToken];

        uint256 n;
        for (uint256 i; i < 3; ++i) {
            if (rawTokens[i] == address(0)) continue;
            bool dup;
            for (uint256 j; j < i; ++j) {
                if (rawTokens[j] == rawTokens[i]) {
                    dup = true;
                    break;
                }
            }
            if (!dup) n++;
        }

        entries = new OracleProviderEntry[](n);

        uint256 k;
        for (uint256 i; i < 3; ++i) {
            if (rawTokens[i] == address(0)) continue;
            bool dup;
            for (uint256 j; j < i; ++j) {
                if (rawTokens[j] == rawTokens[i]) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;

            bytes32 key = _oracleProviderKey(GMX_ORACLE_ADDRESS, rawTokens[i]);
            entries[k] = OracleProviderEntry({
                token: rawTokens[i], key: key, originalProvider: IDataStore(GMX_DATA_STORE).getAddress(key)
            });
            vm.prank(controller);
            IDataStore(GMX_DATA_STORE).setAddress(key, GMX_CHAINLINK_PRICE_FEED);
            k++;
        }
    }

    function _callExecuteOrder(bytes32 orderKey, OracleProviderEntry[] memory entries) private {
        address[] memory tokens = new address[](entries.length);
        address[] memory providers = new address[](entries.length);
        bytes[] memory data = new bytes[](entries.length);
        for (uint256 i; i < entries.length; ++i) {
            tokens[i] = entries[i].token;
            providers[i] = GMX_CHAINLINK_PRICE_FEED;
            data[i] = "";
        }

        bytes32 keeperKey = keccak256(abi.encode("ORDER_KEEPER"));
        address[] memory members = IGmxRoleStore(GMX_ROLE_STORE).getRoleMembers(keeperKey, 0, 10);
        address keeper = members.length > 0 ? members[0] : _getController();

        if (members.length == 0) {
            vm.mockCall(
                GMX_ROLE_STORE,
                abi.encodeWithSelector(bytes4(keccak256("hasRole(address,bytes32)")), keeper, keeperKey),
                abi.encode(true)
            );
        }

        IGmxOrderHandler handler = GmxLib.GMX_ROUTER.orderHandler();
        vm.prank(keeper);
        handler.executeOrder(
            orderKey, IGmxOrderHandler.SetPricesParams({ tokens: tokens, providers: providers, data: data })
        );
    }

    function _executeOrder(bytes32 orderKey, address market) private {
        OracleProviderEntry[] memory entries = _prepareOracleProviders(market);

        _callExecuteOrder(orderKey, entries);

        address controller = _getController();
        for (uint256 i; i < entries.length; ++i) {
            vm.prank(controller);
            IDataStore(GMX_DATA_STORE).setAddress(entries[i].key, entries[i].originalProvider);
        }

        vm.clearMockedCalls();
    }
}

/// @dev Minimal DataStore interface for oracle provider key reads/writes in tests.
interface IDataStore {
    function getAddress(bytes32 key) external view returns (address);
    function setAddress(bytes32 key, address value) external returns (address);
}
