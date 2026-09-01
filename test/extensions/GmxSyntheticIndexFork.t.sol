// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {Constants} from "../../contracts/test/Constants.sol";

import {AGmxV2} from "../../contracts/protocol/extensions/adapters/AGmxV2.sol";
import {EApps} from "../../contracts/protocol/extensions/EApps.sol";
import {ECrosschain} from "../../contracts/protocol/extensions/ECrosschain.sol";
import {EGmxCallback} from "../../contracts/protocol/extensions/EGmxCallback.sol";
import {ENavView} from "../../contracts/protocol/extensions/ENavView.sol";
import {EOracle} from "../../contracts/protocol/extensions/EOracle.sol";
import {EUpgrade} from "../../contracts/protocol/extensions/EUpgrade.sol";
import {SmartPool} from "../../contracts/protocol/SmartPool.sol";
import {ExtensionsMapDeployer} from "../../contracts/protocol/deps/ExtensionsMapDeployer.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {IPoolRegistry} from "../../contracts/protocol/interfaces/IPoolRegistry.sol";
import {IAuthority} from "../../contracts/protocol/interfaces/IAuthority.sol";
import {IOwnedUninitialized} from "../../contracts/utils/owned/IOwnedUninitialized.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {IAGmxV2} from "../../contracts/protocol/extensions/adapters/interfaces/IAGmxV2.sol";
import {IEApps} from "../../contracts/protocol/extensions/adapters/interfaces/IEApps.sol";
import {IMinimumVersion} from "../../contracts/protocol/extensions/adapters/interfaces/IMinimumVersion.sol";
import {Applications} from "../../contracts/protocol/types/Applications.sol";
import {ExternalApp, AppTokenBalance} from "../../contracts/protocol/types/ExternalApp.sol";
import {DeploymentParams, Extensions, EAppsParams} from "../../contracts/protocol/types/DeploymentParams.sol";
import {IGmxReader, IGmxDataStore, IGmxRoleStore, IGmxOrderHandler, IGmxExchangeRouter, IGmxChainlinkPriceFeedProvider, GmxValidatedPrice, GmxMarketPrices, GmxPositionInfo} from "../../contracts/utils/exchanges/gmx/IGmxSynthetics.sol";
import {IPriceFeed} from "gmx-synthetics/oracle/IPriceFeed.sol";
import {GmxLib} from "../../contracts/protocol/libraries/GmxLib.sol";
import {Order} from "gmx-synthetics/order/Order.sol";
import {IBaseOrderUtils} from "gmx-synthetics/order/IBaseOrderUtils.sol";
import {Market} from "gmx-synthetics/market/Market.sol";
import {Position} from "gmx-synthetics/position/Position.sol";
import {Price} from "gmx-synthetics/price/Price.sol";

/// @title GmxSyntheticIndexFork
/// @notice Verifies that long/short unrealised PnL on a GMX synthetic-index market
///  (one whose indexToken has no on-chain `priceFeed`, e.g. LIT/USD) is correctly
///  reflected in NAV via the hardcoded Chainlink fallback feed.
/// @dev The test opens real GMX positions on a fork and moves the fallback
///  aggregator price to observe profit/loss direction.
contract GmxSyntheticIndexFork is Test {
    // =========================================================================
    // Constants
    // =========================================================================

    address private constant AUTHORITY = Constants.AUTHORITY;
    address private constant FACTORY = Constants.FACTORY;
    address private constant TOKEN_JAR = Constants.TOKEN_JAR;

    address private constant GMX_DATA_STORE = Constants.ARB_GMX_DATA_STORE;
    address private constant GMX_READER = Constants.ARB_GMX_READER;
    address private constant GMX_EXCHANGE_ROUTER = Constants.ARB_GMX_EXCHANGE_ROUTER;
    address private constant GMX_CHAINLINK_PRICE_FEED = Constants.ARB_GMX_CHAINLINK_PRICE_FEED;
    address private constant GMX_ROLE_STORE = Constants.ARB_GMX_ROLE_STORE;
    address private constant GMX_REFERRAL_STORAGE = Constants.ARB_GMX_REFERRAL_STORAGE;
    address private constant GMX_ORACLE_ADDRESS = 0x7F01614cA5198Ec979B1aAd1DAF0DE7e0a215BDF;

    address private constant ARB_WETH = Constants.ARB_WETH;
    address private constant ARB_USDC = Constants.ARB_USDC;
    address private constant ARB_ORACLE = Constants.ARB_ORACLE;
    address private constant ARB_GRG_STAKING = Constants.ARB_GRG_STAKING;
    address private constant ARB_UNISWAP_V4_POSM = Constants.ARB_UNISWAP_V4_POSM;

    /// @dev LIT/USD market on Arbitrum.
    address private constant LIT_USD_MARKET = 0x044dFE01863CE85f9ECd5639eE5485c90AC320FC;
    address private constant LIT_INDEX_TOKEN = 0xE6172EecBB07F197F52bb73d74daa0e19C31c4Db;
    address private constant LIT_FALLBACK_FEED = 0x569dCA98c58d7A89cEE87801805A8EaAf2C72B5b;

    uint256 private constant GMX_USD = 1e30;

    /// @dev WETH collateral for long, USDC collateral for short.
    uint256 private constant COLLATERAL_AMOUNT_WETH = 1 ether;
    uint256 private constant COLLATERAL_AMOUNT_USDC = 4_000 * 1e6;
    /// @dev Position size: ~2x leverage.
    uint256 private constant SIZE_DELTA_USD = 8_000 * GMX_USD;

    // =========================================================================
    // State
    // =========================================================================

    address private poolOwner;
    address private pool;
    AGmxV2 private agmxV2;

    // =========================================================================
    // setUp
    // =========================================================================

    function setUp() public {
        vm.createSelectFork("arbitrum", Constants.ARB_BLOCK);

        // The hardcoded LIT fallback Chainlink aggregator was deployed after ARB_BLOCK,
        // so etch a non-empty bytecode so Foundry does not revert on "call to non-contract
        // address" before vm.mockCall intercepts latestRoundData().
        vm.etch(LIT_FALLBACK_FEED, hex"00");

        // `isIndexTokenPriced` and NAV valuation both read the fallback LIT feed.
        // Provide a stable baseline ($3.496 / LIT) for order creation and baseline valuation.
        _mockFallbackLitPrice(349_657_975);

        require(
            address(GMX_READER).code.length > 0,
            "Fork guard: GMX Reader has no code - check ARBITRUM_MAINNET_RPC_URL"
        );

        // Realistic gas price so computeExecutionFee returns a non-zero value.
        vm.txGasPrice(1 gwei);

        poolOwner = makeAddr("poolOwner");

        EGmxCallback eGmxCallback = new EGmxCallback();
        agmxV2 = new AGmxV2();

        EApps eApps = new EApps(EAppsParams({grgStakingProxy: ARB_GRG_STAKING, univ4Posm: ARB_UNISWAP_V4_POSM}));
        EOracle eOracle = new EOracle(ARB_ORACLE, ARB_WETH);
        EUpgrade eUpgrade = new EUpgrade(FACTORY);
        ENavView eNavView = new ENavView(
            EAppsParams({grgStakingProxy: ARB_GRG_STAKING, univ4Posm: ARB_UNISWAP_V4_POSM})
        );
        ECrosschain eCrosschain = new ECrosschain();

        ExtensionsMapDeployer mapDeployer = new ExtensionsMapDeployer();
        DeploymentParams memory params = DeploymentParams({
            extensions: Extensions({
                eApps: address(eApps),
                eOracle: address(eOracle),
                eUpgrade: address(eUpgrade),
                eNavView: address(eNavView),
                eCrosschain: address(eCrosschain),
                eGmxCallback: address(eGmxCallback)
            }),
            wrappedNative: ARB_WETH
        });
        bytes32 salt = keccak256(abi.encodePacked("GMX_SYNTHETIC_INDEX_FORK_V1", block.chainid));
        address extensionsMap = mapDeployer.deployExtensionsMap(params, salt);

        SmartPool impl = new SmartPool(AUTHORITY, extensionsMap, TOKEN_JAR);

        address registry = IRigoblockPoolProxyFactory(FACTORY).getRegistry();
        address rigoblockDao = IPoolRegistry(registry).rigoblockDao();
        vm.prank(rigoblockDao);
        IRigoblockPoolProxyFactory(FACTORY).setImplementation(address(impl));

        vm.prank(poolOwner);
        (pool, ) = IRigoblockPoolProxyFactory(FACTORY).createPool("LitIndexPool", "LITFP", ARB_WETH);

        address authorityOwner = IOwnedUninitialized(AUTHORITY).owner();
        vm.startPrank(authorityOwner);
        IAuthority(AUTHORITY).setAdapter(address(agmxV2), true);
        if (!IAuthority(AUTHORITY).isWhitelister(authorityOwner)) {
            IAuthority(AUTHORITY).setWhitelister(authorityOwner, true);
        }
        IAuthority(AUTHORITY).addMethod(IAGmxV2.createIncreaseOrder.selector, address(agmxV2));
        IAuthority(AUTHORITY).addMethod(IAGmxV2.createDecreaseOrder.selector, address(agmxV2));
        IAuthority(AUTHORITY).addMethod(IAGmxV2.updateOrder.selector, address(agmxV2));
        IAuthority(AUTHORITY).addMethod(IAGmxV2.cancelOrder.selector, address(agmxV2));
        IAuthority(AUTHORITY).addMethod(IAGmxV2.claimFundingFees.selector, address(agmxV2));
        IAuthority(AUTHORITY).addMethod(IAGmxV2.claimCollateral.selector, address(agmxV2));
        vm.stopPrank();

        // Fund pool with both WETH and USDC for long/short collateral.
        deal(ARB_WETH, pool, 10 ether);
        deal(ARB_USDC, pool, 20_000 * 1e6);
    }

    // =========================================================================
    // Tests: long LIT/USD with WETH collateral
    // =========================================================================

    /// @notice A long position profits when the synthetic index token price rises.
    function test_LongSyntheticIndex_PriceUp_Profit() public {
        _openLitLongPosition();

        int256 baselinePnl = _basePnlUsd();
        assertGt(_positionUsdValue(), 0, "baseline position value must be positive");

        // Higher LIT price → long profit → base PnL becomes positive.
        _mockFallbackLitPrice(500_000_000); // $5.00 in 8-decimal Chainlink answer
        int256 highPricePnl = _basePnlUsd();

        assertGt(highPricePnl, baselinePnl, "long base PnL must increase when index price rises");
        assertGt(highPricePnl, 0, "long must be in profit when index price rises");
    }

    /// @notice A long position loses when the synthetic index token price falls.
    function test_LongSyntheticIndex_PriceDown_Loss() public {
        _openLitLongPosition();

        int256 baselinePnl = _basePnlUsd();
        assertGt(_positionUsdValue(), 0, "baseline position value must be positive");

        // Lower LIT price → long loss → base PnL becomes negative.
        _mockFallbackLitPrice(200_000_000); // $2.00 in 8-decimal Chainlink answer
        int256 lowPricePnl = _basePnlUsd();

        assertLt(lowPricePnl, baselinePnl, "long base PnL must decrease when index price falls");
        assertLt(lowPricePnl, 0, "long must be at a loss when index price falls");
    }

    // =========================================================================
    // Tests: short LIT/USD with USDC collateral
    // =========================================================================

    /// @notice A short position loses when the synthetic index token price rises.
    function test_ShortSyntheticIndex_PriceUp_Loss() public {
        _openLitShortPosition();

        int256 baselinePnl = _basePnlUsd();
        assertGt(_positionUsdValue(), 0, "baseline position value must be positive");

        // Higher LIT price → short loss → base PnL becomes negative.
        _mockFallbackLitPrice(500_000_000);
        int256 highPricePnl = _basePnlUsd();

        assertLt(highPricePnl, baselinePnl, "short base PnL must decrease when index price rises");
        assertLt(highPricePnl, 0, "short must be at a loss when index price rises");
    }

    /// @notice A short position profits when the synthetic index token price falls.
    function test_ShortSyntheticIndex_PriceDown_Profit() public {
        _openLitShortPosition();

        int256 baselinePnl = _basePnlUsd();
        assertGt(_positionUsdValue(), 0, "baseline position value must be positive");

        // Lower LIT price → short profit → base PnL becomes positive.
        _mockFallbackLitPrice(200_000_000);
        int256 lowPricePnl = _basePnlUsd();

        assertGt(lowPricePnl, baselinePnl, "short base PnL must increase when index price falls");
        assertGt(lowPricePnl, 0, "short must be in profit when index price falls");
    }

    // =========================================================================
    // Helpers: position opening and keeper execution
    // =========================================================================

    function _openLitLongPosition() private returns (bytes32 orderKey) {
        IBaseOrderUtils.CreateOrderParams memory p = _litLongParams();
        vm.prank(poolOwner);
        orderKey = IAGmxV2(pool).createIncreaseOrder(p);
        _executeOrder(orderKey, LIT_USD_MARKET);
    }

    function _openLitShortPosition() private returns (bytes32 orderKey) {
        IBaseOrderUtils.CreateOrderParams memory p = _litShortParams();
        vm.prank(poolOwner);
        orderKey = IAGmxV2(pool).createIncreaseOrder(p);
        _executeOrder(orderKey, LIT_USD_MARKET);
    }

    function _litLongParams() private pure returns (IBaseOrderUtils.CreateOrderParams memory) {
        return
            IBaseOrderUtils.CreateOrderParams({
                addresses: IBaseOrderUtils.CreateOrderParamsAddresses({
                    receiver: address(0),
                    cancellationReceiver: address(0),
                    callbackContract: address(0),
                    uiFeeReceiver: address(0),
                    market: LIT_USD_MARKET,
                    initialCollateralToken: ARB_WETH,
                    swapPath: new address[](0)
                }),
                numbers: IBaseOrderUtils.CreateOrderParamsNumbers({
                    sizeDeltaUsd: SIZE_DELTA_USD,
                    initialCollateralDeltaAmount: COLLATERAL_AMOUNT_WETH,
                    triggerPrice: 0,
                    acceptablePrice: type(uint256).max,
                    executionFee: 0,
                    callbackGasLimit: 0,
                    minOutputAmount: 0,
                    validFromTime: 0
                }),
                orderType: Order.OrderType.MarketIncrease,
                decreasePositionSwapType: Order.DecreasePositionSwapType.NoSwap,
                isLong: true,
                shouldUnwrapNativeToken: false,
                autoCancel: false,
                referralCode: bytes32(0),
                dataList: new bytes32[](0)
            });
    }

    function _litShortParams() private pure returns (IBaseOrderUtils.CreateOrderParams memory) {
        return
            IBaseOrderUtils.CreateOrderParams({
                addresses: IBaseOrderUtils.CreateOrderParamsAddresses({
                    receiver: address(0),
                    cancellationReceiver: address(0),
                    callbackContract: address(0),
                    uiFeeReceiver: address(0),
                    market: LIT_USD_MARKET,
                    initialCollateralToken: ARB_USDC,
                    swapPath: new address[](0)
                }),
                numbers: IBaseOrderUtils.CreateOrderParamsNumbers({
                    sizeDeltaUsd: SIZE_DELTA_USD,
                    initialCollateralDeltaAmount: COLLATERAL_AMOUNT_USDC,
                    triggerPrice: 0,
                    acceptablePrice: 0, // Short: accept any price
                    executionFee: 0,
                    callbackGasLimit: 0,
                    minOutputAmount: 0,
                    validFromTime: 0
                }),
                orderType: Order.OrderType.MarketIncrease,
                decreasePositionSwapType: Order.DecreasePositionSwapType.NoSwap,
                isLong: false,
                shouldUnwrapNativeToken: false,
                autoCancel: false,
                referralCode: bytes32(0),
                dataList: new bytes32[](0)
            });
    }

    // =========================================================================
    // Helpers: GMX keeper execution (mirrors AGmxV2Fork pattern)
    // =========================================================================

    struct OracleProviderEntry {
        address token;
        bytes32 key;
        address originalProvider;
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

        // Re-establish the LIT fallback mock and force the GMX Chainlink provider to
        // revert for LIT, so `_positionUsdValue` exercises the fallback code path.
        // LIT's original provider is a Data Stream contract, so we redirect it back to
        // the Chainlink provider address that we mock-revert.
        bytes32 litProviderKey = _oracleProviderKey(GMX_ORACLE_ADDRESS, LIT_INDEX_TOKEN);
        vm.prank(controller);
        IDataStore(GMX_DATA_STORE).setAddress(litProviderKey, GMX_CHAINLINK_PRICE_FEED);

        _mockFallbackLitPrice(349_657_975);
        _mockGmxProviderRevert(LIT_INDEX_TOKEN);
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
                token: rawTokens[i],
                key: key,
                originalProvider: IDataStore(GMX_DATA_STORE).getAddress(key)
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

        // Mock prices for keeper execution. LIT has no GMX on-chain feed, so the
        // redirected provider must return a valid 1e30-per-atom price.
        GmxValidatedPrice[] memory prices = new GmxValidatedPrice[](entries.length);
        for (uint256 i; i < entries.length; ++i) {
            prices[i] = _executionPrice(entries[i].token);
        }
        _mockChainlinkPrices(entries, prices);

        IGmxOrderHandler handler = IGmxExchangeRouter(GMX_EXCHANGE_ROUTER).orderHandler();
        vm.prank(keeper);
        handler.executeOrder(
            orderKey,
            IGmxOrderHandler.SetPricesParams({tokens: tokens, providers: providers, data: data})
        );
    }

    function _executionPrice(address token) private view returns (GmxValidatedPrice memory) {
        if (token == LIT_INDEX_TOKEN) {
            return
                GmxValidatedPrice({
                    token: token,
                    min: 3_496_579_750_000, // ~$3.496 / LIT atom in 1e30 units
                    max: 3_496_579_750_000,
                    timestamp: block.timestamp,
                    blockNumber: block.number
                });
        }
        if (token == ARB_WETH) {
            return
                GmxValidatedPrice({
                    token: token,
                    min: 2_450_000_000_000_000, // ~$2,450 / WETH atom in 1e30 units
                    max: 2_450_000_000_000_000,
                    timestamp: block.timestamp,
                    blockNumber: block.number
                });
        }
        if (token == ARB_USDC) {
            return
                GmxValidatedPrice({
                    token: token,
                    min: 1_000_000_000_000_000_000_000_000_000, // ~$1.00 / USDC atom in 1e30 units
                    max: 1_000_000_000_000_000_000_000_000_000,
                    timestamp: block.timestamp,
                    blockNumber: block.number
                });
        }
        revert("unknown token for execution price");
    }

    function _mockChainlinkPrices(OracleProviderEntry[] memory entries, GmxValidatedPrice[] memory prices) private {
        for (uint256 i; i < entries.length; ++i) {
            vm.mockCall(
                GMX_CHAINLINK_PRICE_FEED,
                abi.encodeCall(IGmxChainlinkPriceFeedProvider.getOraclePrice, (entries[i].token, bytes(""))),
                abi.encode(prices[i])
            );
        }
    }

    function _mockFallbackLitPrice(int256 chainlinkAnswer) private {
        vm.mockCall(
            LIT_FALLBACK_FEED,
            abi.encodeWithSelector(IPriceFeed.latestRoundData.selector),
            abi.encode(uint80(1), chainlinkAnswer, uint256(0), block.timestamp, uint80(1))
        );
    }

    function _mockGmxProviderRevert(address token) private {
        vm.mockCallRevert(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeCall(IGmxChainlinkPriceFeedProvider.getOraclePrice, (token, bytes(""))),
            ""
        );
    }

    // =========================================================================
    // Helpers: valuation
    // =========================================================================

    /// @dev Returns the base unrealised PnL (in GMX 1e30 USD) of the pool's first
    ///  GMX position, using the fallback LIT feed for the synthetic index token.
    function _basePnlUsd() private view returns (int256) {
        Position.Props[] memory positions = IGmxReader(GMX_READER).getAccountPositions(
            GMX_DATA_STORE,
            pool,
            0,
            type(uint256).max
        );
        require(positions.length > 0, "no GMX position");

        uint256 n = positions.length;
        address[] memory markets = new address[](n);
        GmxMarketPrices[] memory marketPrices = new GmxMarketPrices[](n);
        for (uint256 i; i < n; ++i) {
            Market.Props memory mkt = IGmxReader(GMX_READER).getMarket(GMX_DATA_STORE, positions[i].addresses.market);
            markets[i] = positions[i].addresses.market;
            marketPrices[i] = GmxMarketPrices({
                indexTokenPrice: GmxLib.getGmxPrice(mkt.indexToken),
                longTokenPrice: GmxLib.getGmxPrice(mkt.longToken),
                shortTokenPrice: GmxLib.getGmxPrice(mkt.shortToken)
            });
        }

        GmxPositionInfo[] memory infos = IGmxReader(GMX_READER).getAccountPositionInfoList(
            GMX_DATA_STORE,
            GMX_REFERRAL_STORAGE,
            pool,
            markets,
            marketPrices,
            address(0),
            0,
            type(uint256).max
        );
        require(infos.length > 0, "no position info");
        return infos[0].basePnlUsd;
    }

    /// @dev Returns the total USD value of all GMX position balances, using the
    ///  fallback LIT feed for the synthetic index token.
    function _positionUsdValue() private view returns (uint256 totalUsd) {
        AppTokenBalance[] memory balances = GmxLib.getGmxPositionBalances(pool);
        for (uint256 i; i < balances.length; ++i) {
            address token = balances[i].token;
            int256 amount = balances[i].amount;
            if (amount <= 0) continue;

            Price.Props memory price = GmxLib.getGmxPrice(token);
            // Skip unpriced tokens (should not happen for WETH/USDC/LIT).
            if (price.min == 0) continue;

            totalUsd += (uint256(amount) * price.min) / GMX_USD;
        }
    }

    function _oracleProviderKey(address oracleContract, address token) private pure returns (bytes32) {
        bytes32 prefix = keccak256(abi.encode("ORACLE_PROVIDER_FOR_TOKEN"));
        return keccak256(abi.encode(prefix, oracleContract, token));
    }

    function _getController() private view returns (address) {
        return IGmxRoleStore(GMX_ROLE_STORE).getRoleMembers(keccak256(abi.encode("CONTROLLER")), 0, 1)[0];
    }
}

interface IDataStore {
    function getAddress(bytes32 key) external view returns (address);
    function setAddress(bytes32 key, address value) external returns (address);
}
