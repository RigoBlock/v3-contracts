// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {ALighter} from "../../contracts/protocol/extensions/adapters/ALighter.sol";
import {IALighter} from "../../contracts/protocol/extensions/adapters/interfaces/IALighter.sol";
import {IMinimumVersion} from "../../contracts/protocol/extensions/adapters/interfaces/IMinimumVersion.sol";
import {LighterRouteType} from "../../contracts/protocol/extensions/adapters/interfaces/lighter/ILighterInteropManager.sol";
import {LighterTypes} from "../../contracts/protocol/extensions/adapters/interfaces/lighter/LighterTypes.sol";
import {LighterLib} from "../../contracts/protocol/libraries/LighterLib.sol";
import {StorageLib} from "../../contracts/protocol/libraries/StorageLib.sol";
import {Applications, LighterData, LighterSlot, LighterViewData, TrackedMarket} from "../../contracts/protocol/types/Applications.sol";
import {LighterConstants} from "../../contracts/protocol/types/LighterConstants.sol";
import {AppTokenBalance} from "../../contracts/protocol/types/ExternalApp.sol";
import {Constants} from "../../contracts/test/Constants.sol";

/// @notice Simple ERC20 used as the LighterEVM USDC stand-in.
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public decimals = 6;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "insufficient");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Records EvmInteropManager transfer args and returns increasing request ids.
/// @dev Does not pull tokens: the deposit allowance reset-to-1 can then be asserted, mirroring
///  the Hyperliquid MockCoreDepositWallet behavior.
contract MockInteropManager {
    uint64 public reqIdCounter;

    uint32 public lastCoreAssetIndex;
    address public lastCoreTo;
    bool public lastCoreIsL1Account;
    uint256 public lastCoreAmount;
    LighterRouteType public lastCoreRouteType;

    uint48 public lastEvmAccountIndex;
    uint32 public lastEvmAssetIndex;
    address public lastEvmRecipient;
    LighterRouteType public lastEvmRouteType;
    uint64 public lastEvmBaseAmount;

    function sendToCore(
        uint32 assetIndex,
        address to,
        bool isL1Account,
        uint256 amount,
        LighterRouteType routeType
    ) external payable returns (uint64 reqId) {
        lastCoreAssetIndex = assetIndex;
        lastCoreTo = to;
        lastCoreIsL1Account = isL1Account;
        lastCoreAmount = amount;
        lastCoreRouteType = routeType;
        reqId = ++reqIdCounter;
    }

    function sendToEvm(
        uint48 accountIndex,
        uint32 assetIndex,
        address evmRecipient,
        LighterRouteType routeType,
        uint64 baseAmount
    ) external returns (uint64 reqId) {
        lastEvmAccountIndex = accountIndex;
        lastEvmAssetIndex = assetIndex;
        lastEvmRecipient = evmRecipient;
        lastEvmRouteType = routeType;
        lastEvmBaseAmount = baseAmount;
        reqId = ++reqIdCounter;
    }
}

/// @notice Records EvmToCoreEntrypoint order-write args and returns increasing request ids.
contract MockCoreEntrypoint {
    uint64 public reqIdCounter;

    uint48 public lastAccountIndex;
    uint16 public lastMarketIndex;
    uint48 public lastClientOrderIndex;
    uint8 public lastOrderType;
    uint8 public lastTimeInForce;
    uint64 public lastOrderExpiry;
    uint48 public lastAmount;
    uint32 public lastPrice;
    bool public lastIsAsk;
    bool public lastReduceOnly;
    uint32 public lastTriggerPrice;
    uint64 public lastCancelOrderIndex;

    function createOrder(
        uint48 accountIndex,
        uint16 marketIndex,
        uint48 clientOrderIndex,
        uint8 orderType,
        uint8 timeInForce,
        uint64 orderExpiry,
        uint48 amount,
        uint32 price,
        bool isAsk,
        bool reduceOnly,
        uint32 triggerPrice
    ) external returns (uint64 reqId) {
        lastAccountIndex = accountIndex;
        lastMarketIndex = marketIndex;
        lastClientOrderIndex = clientOrderIndex;
        lastOrderType = orderType;
        lastTimeInForce = timeInForce;
        lastOrderExpiry = orderExpiry;
        lastAmount = amount;
        lastPrice = price;
        lastIsAsk = isAsk;
        lastReduceOnly = reduceOnly;
        lastTriggerPrice = triggerPrice;
        reqId = ++reqIdCounter;
    }

    function cancelOrder(uint48 accountIndex, uint64 orderIndex) external returns (uint64 reqId) {
        lastAccountIndex = accountIndex;
        lastCancelOrderIndex = orderIndex;
        reqId = ++reqIdCounter;
    }

    function cancelAllOrders(uint48 accountIndex) external returns (uint64 reqId) {
        lastAccountIndex = accountIndex;
        reqId = ++reqIdCounter;
    }
}

/// @notice Exposes LighterLib internal functions for unit testing.
/// @dev getLighterBalances mirrors EApps.getLighterTrackedMarkets: the lib's NAV function takes
///  the pool's Lighter storage as calldata (in production because ALighter runs under staticcall).
contract LighterLibHarness {
    function getLighterBalances(address account) external view returns (AppTokenBalance[] memory) {
        return LighterLib.getLighterBalances(account, _viewData());
    }

    /// @notice Builds the LighterViewData exactly like EApps.getLighterTrackedMarkets does.
    function _viewData() internal view returns (LighterViewData memory viewData) {
        LighterSlot storage slot = StorageLib.lighterSlot();
        uint16[] storage markets = slot.trackedMarkets;
        uint256 length = markets.length;
        viewData.marketIds = new uint16[](length);
        viewData.sizeDecimals = new uint8[](length);
        viewData.priceDecimals = new uint8[](length);
        for (uint256 i; i < length; ++i) {
            uint16 marketId = markets[i];
            viewData.marketIds[i] = marketId;
            TrackedMarket memory market = slot.markets[marketId];
            viewData.sizeDecimals[i] = market.sizeDecimals;
            viewData.priceDecimals[i] = market.priceDecimals;
        }
        viewData.inFlightAmount = slot.data.inFlightAmount;
        viewData.lastActionTimestamp = slot.data.lastActionTimestamp;
        viewData.lastReqId = slot.data.lastReqId;
    }

    function assertNavUnlocked() external view {
        LighterLib.assertNavUnlocked();
    }

    function recordAction(int256 amount, uint64 reqId) external {
        LighterLib.recordAction(amount, reqId);
    }

    function trackMarket(uint16 marketId, uint8 sizeDecimals, uint8 priceDecimals) external {
        LighterLib.trackMarket(marketId, sizeDecimals, priceDecimals);
    }

    function isTrackedMarket(uint16 marketId) external view returns (bool) {
        return LighterLib.isTrackedMarket(marketId);
    }

    /// @notice Returns the raw LighterData fields (in-flight accounting) from pool storage.
    function lighterData() external view returns (LighterData memory) {
        return StorageLib.lighterSlot().data;
    }

    function trackedMarkets() external view returns (uint16[] memory) {
        return StorageLib.lighterSlot().trackedMarkets;
    }
}

/// @notice A minimal pool that delegatecalls the Lighter adapter (or the lib harness).
/// @dev The implementation is switchable so adapter writes and lib reads share one storage context.
contract PoolHarness {
    address public implementation;

    constructor(address impl) {
        implementation = impl;
    }

    function setImplementation(address impl) external {
        implementation = impl;
    }

    fallback() external payable {
        (bool success, bytes memory result) = implementation.delegatecall(msg.data);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
        assembly {
            return(add(result, 32), mload(result))
        }
    }

    receive() external payable {}
}

contract ALighterUnit is Test {
    ALighter private adapter;
    PoolHarness private pool;
    LighterLibHarness private libHarness;

    address private immutable _usdc = Constants.LIGHTER_USDC;
    address private immutable _manager = LighterConstants.EVM_INTEROP_MANAGER;
    address private immutable _entrypoint = LighterConstants.CORE_ENTRYPOINT;
    address private immutable _readCore = LighterConstants.READ_CORE;

    /// @dev Switches the pool's delegatecall target; storage (ERC-7201 slots) is shared.
    function _useAdapter() private {
        pool.setImplementation(address(adapter));
    }

    function _useLibHarness() private {
        pool.setImplementation(address(libHarness));
    }

    function setUp() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);

        adapter = new ALighter();
        pool = new PoolHarness(address(adapter));
        libHarness = new LighterLibHarness();

        // Deploy mocks and etch their code at the Lighter predeploy addresses.
        MockInteropManager manager = new MockInteropManager();
        MockCoreEntrypoint entrypoint = new MockCoreEntrypoint();
        MockERC20 usdc = new MockERC20();

        vm.etch(_manager, address(manager).code);
        vm.etch(_entrypoint, address(entrypoint).code);
        vm.etch(_usdc, address(usdc).code);

        // Fund the pool harness with USDC.
        MockERC20(_usdc).mint(address(pool), 1_000_000e6);

        // By default the pool's Core account exists with zero collateral.
        _mockAccountInfo(address(pool), _accountInfo(0));
        _mockEvmAccountIndex(address(pool), 7);
    }

    // =========================================================================
    // READ_CORE mock helpers
    // =========================================================================

    function _mockAccountInfo(address account, LighterTypes.AccountInfo memory info) private {
        // Every read except 0x0000 returns abi.encode(bool found, bytes data) per the Lighter docs.
        vm.mockCall(
            _readCore,
            abi.encodePacked(LighterLib._SELECTOR_ACCOUNT_INFO, account, false),
            abi.encode(true, abi.encode(info))
        );
    }

    function _mockMarketInfo(uint16 marketId, LighterTypes.MarketInfo memory info) private {
        vm.mockCall(
            _readCore,
            abi.encodePacked(LighterLib._SELECTOR_MARKET_INFO, marketId),
            abi.encode(true, abi.encode(info))
        );
    }

    function _mockPosition(address account, uint16 marketId, LighterTypes.Position memory position) private {
        vm.mockCall(
            _readCore,
            abi.encodePacked(LighterLib._SELECTOR_POSITION, account, false, marketId),
            abi.encode(true, abi.encode(position))
        );
    }

    /// @notice Mocks the transaction-status read (0x0000): 0 pending, 1 successful, 2 failed.
    /// @dev 0x0000 is the only read without the (bool found, bytes) envelope.
    function _mockTxStatus(uint64 reqId, uint8 status) private {
        vm.mockCall(_readCore, abi.encodePacked(LighterLib._SELECTOR_TX_STATUS, reqId), abi.encode(status, bytes("")));
    }

    function _mockEvmAccountIndex(address account, uint48 accountIndex) private {
        vm.mockCall(
            _readCore,
            abi.encodePacked(LighterLib._SELECTOR_EVM_ACCOUNT_INDEX, account),
            abi.encode(true, abi.encode(accountIndex))
        );
    }

    /// @notice Nonexistent account: per the Lighter docs the read succeeds with found = false
    ///  (older devnet builds reverted the call instead; coreAccountExists tolerates both).
    function _mockNoAccount(address account) private {
        vm.mockCall(
            _readCore,
            abi.encodePacked(LighterLib._SELECTOR_ACCOUNT_INFO, account, false),
            abi.encode(false, bytes(""))
        );
    }

    // =========================================================================
    // Struct builders
    // =========================================================================

    function _accountInfo(int128 collateral) private pure returns (LighterTypes.AccountInfo memory) {
        return
            LighterTypes.AccountInfo({
                accountType: 0,
                accountIndex: 0,
                masterAccountIndex: 0,
                l1Address: address(0),
                evmAddress: address(0),
                collateralBaseAmount: collateral
            });
    }

    function _marketInfo(
        uint8 marketType,
        uint32 quoteAssetId,
        uint64 markPrice
    ) private pure returns (LighterTypes.MarketInfo memory) {
        return
            LighterTypes.MarketInfo({
                marketType: marketType,
                baseAssetId: 2,
                quoteAssetId: quoteAssetId,
                takerFee: 0,
                makerFee: 0,
                minBaseAmount: 0,
                minQuoteAmount: 0,
                liquidationFee: 0,
                indexPrice: markPrice,
                markPrice: markPrice
            });
    }

    function _position(
        int64 positionSize,
        uint56 entryQuote,
        uint8 marginMode,
        int128 allocatedMargin
    ) private pure returns (LighterTypes.Position memory) {
        return
            LighterTypes.Position({
                lastFundingRatePrefixSum: 0,
                position: positionSize,
                entryQuote: entryQuote,
                initialMarginFraction: 0,
                totalOrderCount: 0,
                totalPositionTiedOrderCount: 0,
                marginMode: marginMode,
                allocatedMargin: allocatedMargin
            });
    }

    /// @notice Tracks a market on the pool via the adapter with a valid mocked Core market info.
    /// @dev Perps carry quoteAssetId == 0 on Core (docs + live devnet verification).
    function _trackMarket(uint16 marketId) private {
        _mockMarketInfo(marketId, _marketInfo(0, 0, 500_0000));
        IALighter(address(pool)).trackMarket(marketId, 2, 4);
    }

    // =========================================================================
    // sendToCore (deposit)
    // =========================================================================

    function testSendToCoreSuccessDepositsAndRecordsInFlight() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);

        vm.expectEmit(true, false, false, true, address(pool));
        emit IALighter.Deposited(100e6);

        uint64 reqId = IALighter(address(pool)).sendToCore(3, address(pool), false, 100e6, LighterRouteType.Perps);
        assertEq(reqId, 1);

        MockInteropManager manager = MockInteropManager(_manager);
        assertEq(manager.lastCoreAssetIndex(), LighterConstants.USDC_ASSET_INDEX);
        assertEq(manager.lastCoreTo(), address(pool));
        assertFalse(manager.lastCoreIsL1Account());
        assertEq(manager.lastCoreAmount(), 100e6);
        assertEq(uint8(manager.lastCoreRouteType()), uint8(LighterRouteType.Perps));

        // Approval is reset to 1 after the call.
        assertEq(MockERC20(_usdc).allowance(address(pool), _manager), 1);

        // The LIGHTER_PERPS application bit is activated.
        uint256 packed = uint256(vm.load(address(pool), StorageLib.APPLICATIONS_SLOT));
        assertTrue(packed & (1 << uint256(Applications.LIGHTER_PERPS)) != 0, "LIGHTER_PERPS app bit must be set");

        // In-flight recorded on the pool's storage: while the deposit is pending on Core the
        // balance includes it (tokens left the wallet, Core still reports zero collateral).
        _useLibHarness();
        LighterData memory data = LighterLibHarness(address(pool)).lighterData();
        assertEq(data.lastActionBlock, block.number);
        assertEq(data.lastActionTimestamp, block.timestamp);
        assertEq(data.inFlightAmount, int128(100e6));
        assertEq(data.lastReqId, 1);

        // Pending status (0): the in-flight deposit applies.
        _mockTxStatus(1, 0);
        AppTokenBalance[] memory balances = LighterLibHarness(address(pool)).getLighterBalances(address(pool));
        assertEq(balances.length, 1);
        assertEq(balances[0].token, LighterConstants.USDC);
        assertEq(balances[0].amount, 100e6);
    }

    function testSendToCoreRevertsForWrongAsset() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);
        vm.expectRevert(IALighter.InvalidAsset.selector);
        IALighter(address(pool)).sendToCore(1, address(pool), false, 100e6, LighterRouteType.Perps);
    }

    function testSendToCoreRevertsForWrongRecipient() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);
        vm.expectRevert(IALighter.InvalidRecipient.selector);
        IALighter(address(pool)).sendToCore(3, address(0xdead), false, 100e6, LighterRouteType.Perps);
    }

    function testSendToCoreRevertsForL1Recipient() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);
        vm.expectRevert(IALighter.InvalidRecipient.selector);
        IALighter(address(pool)).sendToCore(3, address(pool), true, 100e6, LighterRouteType.Perps);
    }

    function testSendToCoreRevertsForSpotRoute() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);
        vm.expectRevert(IALighter.InvalidRoute.selector);
        IALighter(address(pool)).sendToCore(3, address(pool), false, 100e6, LighterRouteType.Spot);
    }

    function testSendToCoreRevertsForZeroAmount() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);
        vm.expectRevert(IALighter.InvalidAmount.selector);
        IALighter(address(pool)).sendToCore(3, address(pool), false, 0, LighterRouteType.Perps);
    }

    // =========================================================================
    // sendToEvm (withdrawal)
    // =========================================================================

    function testSendToEvmSuccessWithdrawsAndRecordsNegativeInFlight() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);

        // Core holds 1000 USDC of collateral for the pool.
        _mockAccountInfo(address(pool), _accountInfo(1000e6));

        vm.expectEmit(true, false, false, true, address(pool));
        emit IALighter.Withdrawn(400e6);

        uint64 reqId = IALighter(address(pool)).sendToEvm(0, 3, address(pool), LighterRouteType.Perps, 400e6);
        assertEq(reqId, 1);

        // The mocked Core account index is resolved and forwarded, not the caller-supplied one.
        MockInteropManager manager = MockInteropManager(_manager);
        assertEq(manager.lastEvmAccountIndex(), 7);
        assertEq(manager.lastEvmAssetIndex(), LighterConstants.USDC_ASSET_INDEX);
        assertEq(manager.lastEvmRecipient(), address(pool));
        assertEq(uint8(manager.lastEvmRouteType()), uint8(LighterRouteType.Perps));
        assertEq(manager.lastEvmBaseAmount(), 400e6);

        // While the withdrawal is pending (status 0), neither the Core collateral nor the pool
        // wallet has moved: no adjustment, the balance is the raw collateral.
        _useLibHarness();
        _mockTxStatus(1, 0);
        AppTokenBalance[] memory balances = LighterLibHarness(address(pool)).getLighterBalances(address(pool));
        assertEq(balances.length, 1);
        assertEq(balances[0].amount, 1000e6);

        // Once Core processes the debit (status 1) but before EVM delivery lands, the withdrawn
        // amount is subtracted as in-flight.
        _mockTxStatus(1, 1);
        balances = LighterLibHarness(address(pool)).getLighterBalances(address(pool));
        assertEq(balances[0].amount, 600e6);
    }

    function testSendToEvmRevertsForWrongAsset() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);
        vm.expectRevert(IALighter.InvalidAsset.selector);
        IALighter(address(pool)).sendToEvm(0, 1, address(pool), LighterRouteType.Perps, 400e6);
    }

    function testSendToEvmRevertsForWrongRecipient() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);
        vm.expectRevert(IALighter.InvalidRecipient.selector);
        IALighter(address(pool)).sendToEvm(0, 3, address(0xdead), LighterRouteType.Perps, 400e6);
    }

    function testSendToEvmRevertsForSpotRoute() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);
        vm.expectRevert(IALighter.InvalidRoute.selector);
        IALighter(address(pool)).sendToEvm(0, 3, address(pool), LighterRouteType.Spot, 400e6);
    }

    function testSendToEvmRevertsForZeroAmount() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);
        vm.expectRevert(IALighter.InvalidAmount.selector);
        IALighter(address(pool)).sendToEvm(0, 3, address(pool), LighterRouteType.Perps, 0);
    }

    function testSendToEvmRevertsWhenAccountNotActivated() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);
        _mockNoAccount(address(pool));
        vm.expectRevert(IALighter.AccountNotActivated.selector);
        IALighter(address(pool)).sendToEvm(0, 3, address(pool), LighterRouteType.Perps, 400e6);
    }

    // =========================================================================
    // Order writes
    // =========================================================================

    function testCreateOrderRevertsForSpotMarket() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);
        vm.expectRevert(IALighter.InvalidMarket.selector);
        IALighter(address(pool)).createOrder(0, 2048, 0, 0, 0, 0, 100, 500_0000, true, false, 0);
    }

    function testCreateOrderRevertsForUntrackedMarket() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);
        vm.expectRevert(LighterLib.MarketNotTracked.selector);
        IALighter(address(pool)).createOrder(0, 5, 0, 0, 0, 0, 100, 500_0000, true, false, 0);
    }

    function testCreateOrderForwardsToEntrypoint() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);
        _trackMarket(5);

        vm.expectEmit(true, false, false, true, address(pool));
        emit IALighter.OrderSent(1);

        uint64 reqId = IALighter(address(pool)).createOrder(0, 5, 42, 1, 2, 0, 100, 500_0000, true, false, 0);
        assertEq(reqId, 1);

        MockCoreEntrypoint entrypoint = MockCoreEntrypoint(_entrypoint);
        assertEq(entrypoint.lastAccountIndex(), 7);
        assertEq(entrypoint.lastMarketIndex(), 5);
        assertEq(entrypoint.lastClientOrderIndex(), 42);
        assertEq(entrypoint.lastOrderType(), 1);
        assertEq(entrypoint.lastTimeInForce(), 2);
        assertEq(entrypoint.lastOrderExpiry(), 0);
        assertEq(entrypoint.lastAmount(), 100);
        assertEq(entrypoint.lastPrice(), 500_0000);
        assertTrue(entrypoint.lastIsAsk());
        assertFalse(entrypoint.lastReduceOnly());
        assertEq(entrypoint.lastTriggerPrice(), 0);
    }

    function testCancelOrderForwardsToEntrypoint() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);

        vm.expectEmit(true, false, false, true, address(pool));
        emit IALighter.OrderSent(1);

        uint64 reqId = IALighter(address(pool)).cancelOrder(0, 123);
        assertEq(reqId, 1);

        MockCoreEntrypoint entrypoint = MockCoreEntrypoint(_entrypoint);
        assertEq(entrypoint.lastAccountIndex(), 7);
        assertEq(entrypoint.lastCancelOrderIndex(), 123);
    }

    function testCancelAllOrdersForwardsToEntrypoint() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);

        vm.expectEmit(true, false, false, true, address(pool));
        emit IALighter.OrderSent(1);

        uint64 reqId = IALighter(address(pool)).cancelAllOrders(0);
        assertEq(reqId, 1);

        MockCoreEntrypoint entrypoint = MockCoreEntrypoint(_entrypoint);
        assertEq(entrypoint.lastAccountIndex(), 7);
    }

    // =========================================================================
    // Market tracking via the adapter
    // =========================================================================

    function testTrackMarketStoresMarket() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);

        vm.expectEmit(true, false, false, true, address(pool));
        emit IALighter.MarketTracked(5);

        _trackMarket(5);

        _useLibHarness();
        assertTrue(LighterLibHarness(address(pool)).isTrackedMarket(5));
    }

    function testTrackMarketRevertsOnDuplicate() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);
        _trackMarket(5);

        _mockMarketInfo(5, _marketInfo(0, 0, 500_0000));
        vm.expectRevert(LighterLib.MarketAlreadyTracked.selector);
        IALighter(address(pool)).trackMarket(5, 2, 4);
    }

    function testTrackMarketRevertsForInvalidDecimals() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);
        _mockMarketInfo(5, _marketInfo(0, 0, 500_0000));

        vm.expectRevert(LighterLib.InvalidMarketDecimals.selector);
        IALighter(address(pool)).trackMarket(5, 19, 4);

        vm.expectRevert(LighterLib.InvalidMarketDecimals.selector);
        IALighter(address(pool)).trackMarket(5, 2, 17);
    }

    function testTrackMarketRevertsForNonPerpMarket() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);
        _mockMarketInfo(5, _marketInfo(1, LighterConstants.USDC_ASSET_INDEX, 500_0000));

        vm.expectRevert(IALighter.InvalidMarket.selector);
        IALighter(address(pool)).trackMarket(5, 2, 4);
    }

    /// @notice Perps are USDC-settled by protocol design; Core reports quoteAssetId == 0 for
    ///  perpetuals (docs + live devnet verification), and that layout must track successfully.
    function testTrackMarketAcceptsZeroQuoteAssetId() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);
        _trackMarket(5);

        _useLibHarness();
        assertTrue(LighterLibHarness(address(pool)).isTrackedMarket(5));
    }

    function testTrackMarketRevertsAboveCap() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);

        for (uint256 i; i < LighterConstants.MAX_TRACKED_MARKETS; ++i) {
            _trackMarket(uint16(100 + i));
        }
        _useLibHarness();
        assertEq(LighterLibHarness(address(pool)).trackedMarkets().length, LighterConstants.MAX_TRACKED_MARKETS);

        _useAdapter();
        _mockMarketInfo(200, _marketInfo(0, 0, 500_0000));
        vm.expectRevert(LighterLib.MaxTrackedMarketsReached.selector);
        IALighter(address(pool)).trackMarket(200, 2, 4);
    }

    function testUntrackMarketRevertsWithOpenPosition() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);
        _trackMarket(5);

        _mockPosition(address(pool), 5, _position(100_00, 50_0000, 0, 0));
        vm.expectRevert(IALighter.PositionNotClosed.selector);
        IALighter(address(pool)).untrackMarket(5);
    }

    function testUntrackMarketSwapRemoveKeepsRemainingTracked() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);
        _trackMarket(5);
        _trackMarket(6);
        _trackMarket(7);

        // Untracking the first of three tracked markets exercises the swap-remove path.
        _mockPosition(address(pool), 5, _position(0, 0, 0, 0));
        vm.expectEmit(true, false, false, true, address(pool));
        emit IALighter.MarketUntracked(5);
        IALighter(address(pool)).untrackMarket(5);

        _useLibHarness();
        LighterLibHarness harness = LighterLibHarness(address(pool));
        uint16[] memory markets = harness.trackedMarkets();
        assertEq(markets.length, 2);
        assertEq(markets[0], 7);
        assertEq(markets[1], 6);
        assertTrue(harness.isTrackedMarket(6));
        assertTrue(harness.isTrackedMarket(7));
        assertFalse(harness.isTrackedMarket(5));
    }

    function testUntrackMarketRevertsForUnknownMarket() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);
        // The adapter checks the position size before the tracked check, so the position read
        // must succeed (zero size) for the MarketNotTracked revert to be reached.
        _mockPosition(address(pool), 9, _position(0, 0, 0, 0));
        vm.expectRevert(LighterLib.MarketNotTracked.selector);
        IALighter(address(pool)).untrackMarket(9);
    }

    // =========================================================================
    // NAV valuation via the lib harness
    // =========================================================================

    function testGetLighterBalancesCollateralOnly() public {
        _mockAccountInfo(address(libHarness), _accountInfo(750e6));

        AppTokenBalance[] memory balances = libHarness.getLighterBalances(address(libHarness));
        assertEq(balances.length, 1);
        assertEq(balances[0].token, LighterConstants.USDC);
        assertEq(balances[0].amount, 750e6);
    }

    function testGetLighterBalancesLongProfit() public {
        _mockMarketInfo(5, _marketInfo(0, 0, 51_0000));
        libHarness.trackMarket(5, 2, 4);
        _mockAccountInfo(address(libHarness), _accountInfo(1_000_000e6));
        // 100 base units long; entry notional 100 * 50.0 = 5000 USDC = 5e9 (Core USDC base units).
        _mockPosition(address(libHarness), 5, _position(100_00, 5_000_000_000, 0, 0));

        AppTokenBalance[] memory balances = libHarness.getLighterBalances(address(libHarness));
        // markValue = 100_00 * 51_0000 * 1e6 / 10^(2+4) = 5100e6; pnl = 5100e6 - 5000e6 = 100e6.
        assertEq(balances.length, 1);
        assertEq(balances[0].amount, int256(1_000_000e6) + 100e6);
    }

    function testGetLighterBalancesShortLoss() public {
        _mockMarketInfo(5, _marketInfo(0, 0, 51_0000));
        libHarness.trackMarket(5, 2, 4);
        _mockAccountInfo(address(libHarness), _accountInfo(1_000_000e6));
        // A short (negative position) loses when the mark price rises above the entry notional.
        _mockPosition(address(libHarness), 5, _position(-100_00, 5_000_000_000, 0, 0));

        AppTokenBalance[] memory balances = libHarness.getLighterBalances(address(libHarness));
        assertEq(balances.length, 1);
        assertEq(balances[0].amount, int256(1_000_000e6) - 100e6);
    }

    function testGetLighterBalancesIsolatedMargin() public {
        // Mark equals entry: zero unrealized PnL; only the isolated margin is added.
        _mockMarketInfo(5, _marketInfo(0, 0, 50_0000));
        libHarness.trackMarket(5, 2, 4);
        _mockAccountInfo(address(libHarness), _accountInfo(100e6));
        _mockPosition(address(libHarness), 5, _position(100_00, 5_000_000_000, 1, 500e12));

        AppTokenBalance[] memory balances = libHarness.getLighterBalances(address(libHarness));
        // allocatedMargin is 12-decimal USDC: 500e12 / 1e6 = 500e6.
        assertEq(balances.length, 1);
        assertEq(balances[0].amount, 600e6);
    }

    function testGetLighterBalancesZeroDustWhenAccountExists() public {
        _mockAccountInfo(address(libHarness), _accountInfo(0));

        // Zero total with an existing Core account keeps the app active with a dust balance.
        AppTokenBalance[] memory balances = libHarness.getLighterBalances(address(libHarness));
        assertEq(balances.length, 1);
        assertEq(balances[0].token, LighterConstants.USDC);
        assertEq(balances[0].amount, 1);
    }

    function testGetLighterBalancesEmptyWithoutCoreAccount() public {
        _mockNoAccount(address(libHarness));
        // No Core account: nothing to value, so the library reports an empty balance list.
        AppTokenBalance[] memory balances = libHarness.getLighterBalances(address(libHarness));
        assertEq(balances.length, 0);
    }

    /// @notice In-flight tracking is driven by the transaction-status read, not block numbers:
    ///  a deposit applies while its reqId is pending and drops the moment Core processes it,
    ///  even within the same EVM block.
    function testInFlightDrivenByTxStatus() public {
        _mockAccountInfo(address(libHarness), _accountInfo(0));

        libHarness.recordAction(100e6, 1);
        _mockTxStatus(1, 0);

        // Pending: in-flight applies.
        AppTokenBalance[] memory balances = libHarness.getLighterBalances(address(libHarness));
        assertEq(balances[0].amount, 100e6, "Pending deposit must apply as in-flight");

        // Processed (status 1): collateral is authoritative, in-flight drops — same block or not.
        _mockTxStatus(1, 1);
        balances = libHarness.getLighterBalances(address(libHarness));
        assertEq(balances[0].amount, 1, "Processed deposit must drop in-flight");

        // Failed (status 2): same as processed for the in-flight purpose.
        _mockTxStatus(1, 2);
        libHarness.recordAction(50e6, 2);
        _mockTxStatus(2, 2);
        balances = libHarness.getLighterBalances(address(libHarness));
        assertEq(balances[0].amount, 1, "Failed write must not keep in-flight");
    }

    function testInFlightExpiresWithSettlementWindow() public {
        _mockAccountInfo(address(libHarness), _accountInfo(0));

        libHarness.recordAction(100e6, 1);
        _mockTxStatus(1, 0);

        // Beyond the settlement window the pending amount is dropped regardless of status.
        vm.warp(block.timestamp + 17 seconds);
        AppTokenBalance[] memory balances = libHarness.getLighterBalances(address(libHarness));
        assertEq(balances[0].amount, 1, "In-flight must expire with the settlement window");
    }

    function testInFlightReadFailureRevertsNav() public {
        _mockAccountInfo(address(libHarness), _accountInfo(0));

        libHarness.recordAction(100e6, 1);
        // No status mock: the READ_CORE wildcard misses and the raw precompile address has no
        // code in unit tests, so the read returns empty data and the lib reverts (fail-closed).
        vm.expectRevert(LighterLib.LighterReadFailed.selector);
        libHarness.getLighterBalances(address(libHarness));
    }

    function testAssertNavUnlockedSettlementWindow() public {
        // No action recorded yet: unlocked.
        libHarness.assertNavUnlocked();

        libHarness.recordAction(0, 0);
        libHarness.assertNavUnlocked();

        // From the next EVM block on, within the 16-second window, NAV reads must revert.
        vm.roll(block.number + 1);
        vm.expectRevert(LighterLib.NavLocked.selector);
        libHarness.assertNavUnlocked();

        // Exactly at the window boundary the lock expires.
        vm.warp(block.timestamp + 16 seconds);
        libHarness.assertNavUnlocked();
    }

    // =========================================================================
    // Adapter metadata and access control
    // =========================================================================

    function testRequiredVersion() public {
        assertEq(IMinimumVersion(address(adapter)).requiredVersion(), "4.5.0");
    }

    function testDirectCallToAdapterReverts() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);
        vm.expectRevert(IALighter.DirectCallNotAllowed.selector);
        adapter.trackMarket(5, 2, 4);
    }
}

/// @notice The adapter constructor must revert off LighterEVM.
contract ALighterConstructorTest is Test {
    function testDeployRevertsOnNonLighterEVM() public {
        vm.chainId(1);
        vm.expectRevert(IALighter.NotLighterEVM.selector);
        new ALighter();
    }
}
