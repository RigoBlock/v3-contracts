// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {Constants} from "../../contracts/test/Constants.sol";

import {AGmxV2} from "../../contracts/protocol/extensions/adapters/AGmxV2.sol";
import {EApps} from "../../contracts/protocol/extensions/EApps.sol";
import {ECrosschain} from "../../contracts/protocol/extensions/ECrosschain.sol";
import {EERC20} from "../../contracts/protocol/extensions/EERC20.sol";
import {EGmxCallback} from "../../contracts/protocol/extensions/EGmxCallback.sol";
import {ENavView} from "../../contracts/protocol/extensions/ENavView.sol";
import {EOracle} from "../../contracts/protocol/extensions/EOracle.sol";
import {EUpgrade} from "../../contracts/protocol/extensions/EUpgrade.sol";
import {SmartPool} from "../../contracts/protocol/SmartPool.sol";
import {ExtensionsMapDeployer} from "../../contracts/protocol/deps/ExtensionsMapDeployer.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {IAuthority} from "../../contracts/protocol/interfaces/IAuthority.sol";
import {IOwnedUninitialized} from "../../contracts/utils/owned/IOwnedUninitialized.sol";
import {IPoolRegistry} from "../../contracts/protocol/interfaces/IPoolRegistry.sol";
import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {IAGmxV2} from "../../contracts/protocol/extensions/adapters/interfaces/IAGmxV2.sol";
import {DeploymentParams, Extensions, EAppsParams} from "../../contracts/protocol/types/DeploymentParams.sol";
import {Reader} from "gmx-synthetics/reader/Reader.sol";
import {RoleStore} from "gmx-synthetics/role/RoleStore.sol";
import {OrderHandler} from "gmx-synthetics/exchange/OrderHandler.sol";
import {OracleUtils} from "gmx-synthetics/oracle/OracleUtils.sol";
import {ChainlinkPriceFeedProvider} from "gmx-synthetics/oracle/ChainlinkPriceFeedProvider.sol";
import {DataStore} from "gmx-synthetics/data/DataStore.sol";
import {GMX_ROUTER, _GMX_CONTROLLER_ROLE} from "../../contracts/protocol/types/GmxConstants.sol";
import {Price} from "gmx-synthetics/price/Price.sol";
import {Market} from "gmx-synthetics/market/Market.sol";
import {AppTokenBalance} from "../../contracts/protocol/types/ExternalApp.sol";
import {GmxAdapterLib} from "../../contracts/protocol/libraries/GmxAdapterLib.sol";
import {GmxLib} from "../../contracts/protocol/libraries/GmxLib.sol";
import {Order} from "gmx-synthetics/order/Order.sol";
import {IBaseOrderUtils} from "gmx-synthetics/order/IBaseOrderUtils.sol";

contract GmxLitPoolForkHarness {
    function isIndexTokenPriced(address token) external view returns (bool) {
        return GmxAdapterLib.isIndexTokenPriced(token);
    }

    function safeGetGmxPrice(address token) external view returns (Price.Props memory) {
        return GmxLib.getGmxPrice(token);
    }

    function getGmxPositionBalances(address account) external view returns (AppTokenBalance[] memory) {
        return GmxLib.getGmxPositionBalances(account);
    }

    function getGmxPositionCount(address account) external view returns (uint256) {
        return
            Reader(Constants.ARB_GMX_READER)
                .getAccountPositions(DataStore(Constants.ARB_GMX_DATA_STORE), account, 0, type(uint256).max)
                .length;
    }
}

/// @title GmxLitPoolFork
/// @notice Fixture-based replica of the live-pool LIT/USD scenario the previous version of
///  this test asserted against (live pool 0xEfa4bDf566aE50537a507863612638680420645C).
/// @dev A fresh smart pool is created on the fork and opens a LIT/USD long with WETH
///  collateral — the same market and direction the live pool held — then the same valuation
///  assertions run against it. Because the position is created by the test itself, this suite
///  works at any recent ARB_BLOCK and no longer pins the last block where the live pool's
///  position happened to be open. Lesson baked in from the GMX v2.2c rotation: never assert
///  on live third-party state that the test does not control.
contract GmxLitPoolFork is Test {
    address private constant AUTHORITY = Constants.AUTHORITY;
    address private constant FACTORY = Constants.FACTORY;
    address private constant TOKEN_JAR = Constants.TOKEN_JAR;

    address private constant GMX_DATA_STORE = Constants.ARB_GMX_DATA_STORE;
    address private constant GMX_READER = Constants.ARB_GMX_READER;
    address private constant GMX_ROLE_STORE = Constants.ARB_GMX_ROLE_STORE;
    address private constant GMX_CHAINLINK_PRICE_FEED = Constants.ARB_GMX_CHAINLINK_PRICE_FEED;

    address private constant LIT_USD_MARKET = Constants.ARB_GMX_LIT_USD_MARKET;
    address private constant LIT_INDEX_TOKEN = Constants.ARB_LIT_TOKEN;

    address private constant ARB_WETH = Constants.ARB_WETH;
    address private constant ARB_GRG_STAKING = Constants.ARB_GRG_STAKING;
    address private constant ARB_UNISWAP_V4_POSM = Constants.ARB_UNISWAP_V4_POSM;
    address private constant ARB_ORACLE = Constants.ARB_ORACLE;

    /// @dev GMX USD precision — 30 decimal places.
    uint256 private constant GMX_USD = 1e30;

    /// @dev Collateral and size mirror the position shape the live pool held on this market:
    ///  ~1 WETH collateral, ~2× leverage (~$8,000 notional at WETH ≈ $4,000).
    uint256 private constant LIT_COLLATERAL_AMOUNT = 1 ether;
    uint256 private constant LIT_SIZE_DELTA_USD = 8_000 * GMX_USD;

    GmxLitPoolForkHarness internal harness;
    AGmxV2 internal agmxV2;
    address internal poolOwner;
    address internal pool;

    function setUp() public {
        vm.createSelectFork("arbitrum", Constants.ARB_BLOCK);

        // Guard: if the RPC does not serve state at ARB_BLOCK, contracts have no code.
        require(
            address(GMX_READER).code.length > 0,
            "Fork guard: GMX Reader has no code at ARB_BLOCK - check ARBITRUM_MAINNET_RPC_URL"
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
                eGmxCallback: address(eGmxCallback),
                eErc20: address(new EERC20())
            }),
            wrappedNative: ARB_WETH
        });
        bytes32 salt = keccak256(abi.encodePacked("GMX_LIT_POOL_FORK_TEST", block.chainid));
        address extensionsMap = mapDeployer.deployExtensionsMap(params, salt);

        SmartPool impl = new SmartPool(AUTHORITY, extensionsMap, TOKEN_JAR);

        address registry = IRigoblockPoolProxyFactory(FACTORY).getRegistry();
        address rigoblockDao = IPoolRegistry(registry).rigoblockDao();
        vm.prank(rigoblockDao);
        IRigoblockPoolProxyFactory(FACTORY).setImplementation(address(impl));

        vm.prank(poolOwner);
        (pool, ) = IRigoblockPoolProxyFactory(FACTORY).createPool("LitForkPool", "LITFP", ARB_WETH);

        address authorityOwner = IOwnedUninitialized(AUTHORITY).owner();
        vm.startPrank(authorityOwner);
        IAuthority(AUTHORITY).setAdapter(address(agmxV2), true);
        if (!IAuthority(AUTHORITY).isWhitelister(authorityOwner)) {
            IAuthority(AUTHORITY).setWhitelister(authorityOwner, true);
        }
        _addMethodForceUpdate(IAGmxV2.createIncreaseOrder.selector);
        _addMethodForceUpdate(IAGmxV2.createDecreaseOrder.selector);
        _addMethodForceUpdate(IAGmxV2.updateOrder.selector);
        _addMethodForceUpdate(IAGmxV2.cancelOrder.selector);
        _addMethodForceUpdate(IAGmxV2.claimFundingFees.selector);
        _addMethodForceUpdate(IAGmxV2.claimCollateral.selector);
        vm.stopPrank();

        harness = new GmxLitPoolForkHarness();
    }

    /// @notice The LIT index token must be recognized as priced (via the hardcoded fallback feed).
    function test_LitIndexToken_IsPriced() public view {
        assertTrue(harness.isIndexTokenPriced(LIT_INDEX_TOKEN), "LIT index token must be priced");
    }

    /// @notice The hardcoded LIT fallback feed must return a non-zero, recently-updated price.
    function test_LitFallbackPrice_Reasonable() public view {
        Price.Props memory price = harness.safeGetGmxPrice(LIT_INDEX_TOKEN);
        console2.log("LIT fallback price min:", price.min);
        console2.log("LIT fallback price max:", price.max);
        assertGt(price.min, 0, "LIT fallback price must be > 0");
        assertGt(price.max, 0, "LIT fallback price must be > 0");
        // LIT/USD has been > 0.001 USD. GMX stores price per token atom, so 0.001 USD/LIT
        // equals 1e9 in 1e30 units. This sanity-checks a non-zero, non-buggy multiplier.
        assertGt(price.min, 1e9, "LIT fallback price must be > 0.001 USD (1e9 in 1e30 per-atom units)");
    }

    /// @notice A fixture pool holding a LIT/USD position must report GMX position balances
    ///  and the lookup must not revert.
    function test_FixturePool_LitPosition_BalancesVisible() public {
        _openLitPosition();

        uint256 posCount = harness.getGmxPositionCount(pool);
        console2.log("GMX positions count:", posCount);
        assertGt(posCount, 0, "Fixture pool must have GMX positions");

        AppTokenBalance[] memory balances = harness.getGmxPositionBalances(pool);
        console2.log("Fixture pool GMX balance count:", balances.length);
        for (uint256 i; i < balances.length; ++i) {
            console2.log("  token:", balances[i].token);
            console2.log("  amount:", balances[i].amount);
        }
        assertGt(balances.length, 0, "Fixture pool must have GMX position balances");
    }

    /// @notice The aggregate GMX position balance of the fixture pool, expressed in USD.
    /// @dev GMX prices are stored per token atom in 1e30 units, so
    ///  `usdValue = amount * price / 1e30`.
    function test_FixturePool_LitPosition_BalanceInUsd() public {
        _openLitPosition();

        AppTokenBalance[] memory balances = harness.getGmxPositionBalances(pool);
        assertGt(balances.length, 0, "Fixture pool must have GMX position balances");

        uint256 totalUsd;
        for (uint256 i; i < balances.length; ++i) {
            address token = balances[i].token;
            int256 amount = balances[i].amount;
            require(amount >= 0, "Unexpected negative GMX balance");

            Price.Props memory price = harness.safeGetGmxPrice(token);
            assertGt(price.min, 0, "GMX balance token must be priced");

            uint256 usd = (uint256(amount) * price.min) / 1e30;
            totalUsd += usd;
            console2.log("  token:", token);
            console2.log("  raw amount:", uint256(amount));
            console2.log("  price per atom (1e30):", price.min);
            console2.log("  USD value:", usd);
        }
        console2.log("Total GMX position USD value:", totalUsd);
        assertGt(totalUsd, 1_000, "Fixture pool GMX position must be worth > $1,000");
    }

    // =========================================================================
    // Fixture helpers
    // =========================================================================

    /// @dev Mints WETH pool shares to the owner, opens the LIT/USD long and executes it.
    function _openLitPosition() internal returns (bytes32 orderKey) {
        deal(ARB_WETH, poolOwner, 5 ether);
        vm.startPrank(poolOwner);
        IERC20(ARB_WETH).approve(pool, 5 ether);
        ISmartPoolActions(pool).mint(poolOwner, 5 ether, 0);
        orderKey = IAGmxV2(pool).createIncreaseOrder(_litIncreaseParams());
        vm.stopPrank();

        _executeOrder(orderKey);
    }

    function _litIncreaseParams() private pure returns (IBaseOrderUtils.CreateOrderParams memory) {
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
                    sizeDeltaUsd: LIT_SIZE_DELTA_USD,
                    initialCollateralDeltaAmount: LIT_COLLATERAL_AMOUNT,
                    triggerPrice: 0,
                    acceptablePrice: type(uint256).max, // Long: accept any price
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

    // =========================================================================
    // Keeper execution helpers (mirrors AGmxV2ForkTest)
    // =========================================================================

    /// @dev Returns the Oracle module of the current GMX OrderHandler, resolved dynamically
    ///  because oracle provider registrations are keyed by the oracle address and GMX
    ///  rotations (e.g. v2.2c, ~Sep 2026) deploy a new Oracle alongside new handlers.
    function _gmxOracle() private view returns (address) {
        return address(OrderHandler(payable(address(GMX_ROUTER.orderHandler()))).oracle());
    }

    /// @dev Returns a GMX CONTROLLER address from the RoleStore. GMX uses
    ///  `keccak256(abi.encode("KEY"))` for role keys, not bare `keccak256("KEY")`.
    function _getController() private view returns (address) {
        return RoleStore(GMX_ROLE_STORE).getRoleMembers(_GMX_CONTROLLER_ROLE, 0, 1)[0];
    }

    /// @dev Returns a registered ORDER_KEEPER address from the RoleStore.
    function _getOrderKeeper() private view returns (address) {
        return RoleStore(GMX_ROLE_STORE).getRoleMembers(keccak256(abi.encode("ORDER_KEEPER")), 0, 1)[0];
    }

    struct OracleProviderEntry {
        address token;
        bytes32 key;
        address originalProvider;
    }

    /// @dev DataStore key for the oracle provider of a (oracleContract, token) pair.
    ///  Mirrors GMX's Keys.oracleProviderForTokenKey — prefix is keccak256(abi.encode("KEY")).
    function _oracleProviderKey(address oracleContract, address token) private pure returns (bytes32) {
        bytes32 prefix = keccak256(abi.encode("ORACLE_PROVIDER_FOR_TOKEN"));
        return keccak256(abi.encode(prefix, oracleContract, token));
    }

    /// @dev Redirects each unique market token's oracle provider to the Chainlink provider
    ///  (as CONTROLLER) so keeper execution can price them; returns entries for restore.
    function _prepareOracleProviders(address market) private returns (OracleProviderEntry[] memory entries) {
        Market.Props memory mkt = Reader(GMX_READER).getMarket(DataStore(GMX_DATA_STORE), market);
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

            bytes32 key = _oracleProviderKey(_gmxOracle(), rawTokens[i]);
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

    /// @dev Restores the original oracle providers saved in `entries`.
    function _restoreOracleProviders(OracleProviderEntry[] memory entries) private {
        address controller = _getController();
        for (uint256 i; i < entries.length; ++i) {
            vm.prank(controller);
            IDataStore(GMX_DATA_STORE).setAddress(entries[i].key, entries[i].originalProvider);
        }
    }

    /// @dev Executes an order as the GMX keeper, pricing market tokens via the Chainlink
    ///  provider, then restores the original providers. LIT has no Chainlink feed, so its
    ///  execution price is mocked (any revert-free value works — the long accepts any price);
    ///  post-execution valuation falls back to the real hardcoded fallback feed, since LIT's
    ///  registered data-stream provider only accepts calls from the GMX Oracle module.
    function _executeOrder(bytes32 orderKey) internal {
        OracleProviderEntry[] memory entries = _prepareOracleProviders(LIT_USD_MARKET);

        // ~$3.496 / LIT atom in 1e30 units (matches the fallback feed order of magnitude).
        uint256 litPrice = 3_496_579_750_000;
        vm.mockCall(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeCall(ChainlinkPriceFeedProvider.getOraclePrice, (LIT_INDEX_TOKEN, bytes(""))),
            abi.encode(
                OracleUtils.ValidatedPrice({
                    token: LIT_INDEX_TOKEN,
                    min: litPrice,
                    max: litPrice,
                    rawMin: litPrice,
                    rawMax: litPrice,
                    timestamp: block.timestamp,
                    provider: GMX_CHAINLINK_PRICE_FEED
                })
            )
        );

        address[] memory tokens = new address[](entries.length);
        address[] memory providers = new address[](entries.length);
        bytes[] memory data = new bytes[](entries.length);
        for (uint256 i; i < entries.length; ++i) {
            tokens[i] = entries[i].token;
            providers[i] = GMX_CHAINLINK_PRICE_FEED;
            data[i] = "";
        }

        OrderHandler handler = OrderHandler(payable(address(GMX_ROUTER.orderHandler())));
        vm.prank(_getOrderKeeper());
        handler.executeOrder(orderKey, OracleUtils.SetPricesParams({tokens: tokens, providers: providers, data: data}));

        _restoreOracleProviders(entries);
        vm.clearMockedCalls();
    }

    function _addMethodForceUpdate(bytes4 selector) private {
        address existing = IAuthority(AUTHORITY).getApplicationAdapter(selector);
        if (existing != address(0)) {
            IAuthority(AUTHORITY).removeMethod(selector, existing);
        }
        IAuthority(AUTHORITY).addMethod(selector, address(agmxV2));
    }
}

/// @dev Minimal DataStore interface for oracle provider key reads/writes in tests.
interface IDataStore {
    function getAddress(bytes32 key) external view returns (address);
    function setAddress(bytes32 key, address value) external returns (address);
}
