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
import {Applications, LighterData, LighterSlot, TrackedMarket} from "../../contracts/protocol/types/Applications.sol";
import {LighterConstants} from "../../contracts/protocol/types/LighterConstants.sol";
import {UnknownMarket} from "../../contracts/protocol/types/LighterConstants.sol";
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
/// @dev getLighterBalances reads the Lighter slot from the executing contract's own storage:
///  called directly on the harness it values the harness's storage; delegatecalled through the
///  PoolHarness (after _useLibHarness) it values the pool's storage.
contract LighterLibHarness {
    function getLighterBalances(address account) external returns (AppTokenBalance[] memory) {
        return LighterLib.getLighterBalances(account);
    }

    function assertNavUnlocked() external view {
        LighterLib.assertNavUnlocked();
    }

    function recordAction(int256 amount, uint64 reqId) external {
        LighterLib.recordAction(amount, reqId);
    }

    function trackMarket(uint16 marketId) external {
        LighterLib.trackMarket(marketId);
    }

    /// @notice Seeds a tracked-market entry directly into the pool's Lighter slot, bypassing
    ///  the Core validation and the release-time decimals table, so the at-cap sweep can be
    ///  exercised with more markets than the table whitelists.
    function seedTrackedMarket(uint16 marketId, uint8 sizeDecimals, uint8 priceDecimals) external {
        LighterSlot storage slot = StorageLib.lighterSlot();
        slot.marketIndex[marketId] = slot.trackedMarkets.length + 1;
        slot.markets[marketId] = TrackedMarket({sizeDecimals: sizeDecimals, priceDecimals: priceDecimals});
        slot.trackedMarkets.push(marketId);
    }

    function marketIndex(uint16 marketId) external view returns (uint256) {
        return StorageLib.lighterSlot().marketIndex[marketId];
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

    function _wrap(bytes memory data) private pure returns (bytes memory) {
        return abi.encode(true, data);
    }

    function _notFound() private pure returns (bytes memory) {
        return abi.encode(false, bytes(""));
    }

    function _mockAccountInfo(address account, LighterTypes.AccountInfo memory info) private {
        vm.mockCall(
            _readCore,
            abi.encodePacked(LighterLib._SELECTOR_ACCOUNT_INFO, account, false),
            _wrap(abi.encode(info))
        );
    }

    function _mockMarketInfo(uint16 marketId, LighterTypes.MarketInfo memory info) private {
        vm.mockCall(_readCore, abi.encodePacked(LighterLib._SELECTOR_MARKET_INFO, marketId), _wrap(abi.encode(info)));
    }

    function _mockPosition(address account, uint16 marketId, LighterTypes.Position memory position) private {
        vm.mockCall(
            _readCore,
            abi.encodePacked(LighterLib._SELECTOR_POSITION, account, false, marketId),
            _wrap(abi.encode(position))
        );
    }

    function _mockTxStatus(uint64 reqId, uint8 status) private {
        // Tx status is the one read without the (bool found, bytes) envelope.
        vm.mockCall(_readCore, abi.encodePacked(LighterLib._SELECTOR_TX_STATUS, reqId), abi.encode(status, bytes("")));
    }

    function _mockEvmAccountIndex(address account, uint48 accountIndex) private {
        vm.mockCall(
            _readCore,
            abi.encodePacked(LighterLib._SELECTOR_EVM_ACCOUNT_INDEX, account),
            _wrap(abi.encode(accountIndex))
        );
    }

    /// @notice Nonexistent account: the account-info read reports found=false, which
    ///  coreAccountExists reports as "no account".
    function _mockNoAccount(address account) private {
        vm.mockCall(_readCore, abi.encodePacked(LighterLib._SELECTOR_ACCOUNT_INFO, account, false), _notFound());
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
                size: positionSize,
                entryQuote: entryQuote,
                initialMarginFraction: 0,
                totalOrderCount: 0,
                totalPositionTiedOrderCount: 0,
                marginMode: marginMode,
                allocatedMargin: allocatedMargin
            });
    }

    /// @notice Tracks a market in the pool's storage via the lib harness with a valid mocked
    ///  Core market info.
    /// @dev Perps carry quoteAssetId == 0 on Core (docs + live devnet verification). The decimal
    ///  scales come from the LighterConstants table, never from calldata.
    function _trackMarket(uint16 marketId) private {
        _mockMarketInfo(marketId, _marketInfo(0, 0, 500_0000));
        _useLibHarness();
        LighterLibHarness(address(pool)).trackMarket(marketId);
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

    /// @notice Markets absent from the LighterConstants release-time decimals table revert
    ///  UnknownMarket before any Core read.
    function testCreateOrderRevertsForUnknownMarket() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);
        vm.expectRevert(abi.encodeWithSelector(UnknownMarket.selector, uint16(5)));
        IALighter(address(pool)).createOrder(0, 5, 0, 0, 0, 0, 100, 500_0000, true, false, 0);
    }

    /// @notice A market that does not exist on Core reports found=false on the auto-track
    ///  validation read and reverts LighterReadFailed.
    function testCreateOrderRevertsForNonexistentCoreMarket() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);
        vm.mockCall(_readCore, abi.encodePacked(LighterLib._SELECTOR_MARKET_INFO, uint16(0)), _notFound());
        vm.expectRevert(LighterLib.LighterReadFailed.selector);
        IALighter(address(pool)).createOrder(0, 0, 0, 0, 0, 0, 100, 500_0000, true, false, 0);
    }

    /// @notice createOrder auto-tracks an untracked market so it is NAV-valued (silently; no
    ///  tracking event is emitted).
    function testCreateOrderAutoTracksUntrackedMarket() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);
        _mockMarketInfo(0, _marketInfo(0, 0, 500_0000));

        vm.expectEmit(true, false, false, true, address(pool));
        emit IALighter.OrderSent(1);

        uint64 reqId = IALighter(address(pool)).createOrder(0, 0, 42, 1, 2, 0, 100, 500_0000, true, false, 0);
        assertEq(reqId, 1);

        _useLibHarness();
        assertGt(LighterLibHarness(address(pool)).marketIndex(0), 0);
        uint16[] memory markets = LighterLibHarness(address(pool)).trackedMarkets();
        assertEq(markets.length, 1);
        assertEq(markets[0], 0);
    }

    /// @notice The NAV path values a position on the auto-tracked market.
    function testCreateOrderAutoTrackedMarketValuedInNav() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);
        _mockMarketInfo(0, _marketInfo(0, 0, 51_00));
        _mockAccountInfo(address(pool), _accountInfo(1_000_000e6));

        // The order's market is tracked and an open position appears on it.
        IALighter(address(pool)).createOrder(0, 0, 1, 0, 0, 0, 100, 500_0000, true, false, 0);
        // 100 base units long; entry notional 100 * 50.0 = 5000 USDC = 5e9 (Core USDC base units).
        _mockPosition(address(pool), 0, _position(100_0000, 5_000_000_000, 0, 0));

        _useLibHarness();
        AppTokenBalance[] memory balances = LighterLibHarness(address(pool)).getLighterBalances(address(pool));
        // markValue = 100_0000 * 51_00 * 1e6 / 10^(4+2) = 5100e6; pnl = 5100e6 - 5000e6 = 100e6.
        assertEq(balances.length, 1);
        assertEq(balances[0].amount, int256(1_000_000e6) + 100e6);
    }

    function testCreateOrderForwardsToEntrypoint() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);
        _mockMarketInfo(0, _marketInfo(0, 0, 500_0000));

        // Trading an already-tracked market is a no-op track: the order goes through unchanged.
        _trackMarket(0);
        _useAdapter();

        vm.expectEmit(true, false, false, true, address(pool));
        emit IALighter.OrderSent(1);

        uint64 reqId = IALighter(address(pool)).createOrder(0, 0, 42, 1, 2, 0, 100, 500_0000, true, false, 0);
        assertEq(reqId, 1);

        MockCoreEntrypoint entrypoint = MockCoreEntrypoint(_entrypoint);
        assertEq(entrypoint.lastAccountIndex(), 7);
        assertEq(entrypoint.lastMarketIndex(), 0);
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
    // At-cap behavior via createOrder (no sweep; the NAV loop prunes instead)
    // =========================================================================

    /// @dev Fills the pool's tracked-market registry to MAX_TRACKED_MARKETS via the lib harness
    ///  (bypassing the decimals table) and fails every position read: a failed read is a zeroed
    ///  position, i.e. an empty (stale) market.
    function _seedPoolRegistryToCap() internal {
        _useLibHarness();
        LighterLibHarness harness = LighterLibHarness(address(pool));
        for (uint256 i; i < LighterConstants.MAX_TRACKED_MARKETS; ++i) {
            uint16 marketId = 100 + uint16(i);
            harness.seedTrackedMarket(marketId, 4, 2);
            _mockPositionNotFound(marketId);
        }
        assertEq(harness.trackedMarkets().length, LighterConstants.MAX_TRACKED_MARKETS);
    }

    function _mockPositionNotFound(uint16 marketId) private {
        vm.mockCall(
            _readCore,
            abi.encodePacked(LighterLib._SELECTOR_POSITION, address(pool), false, marketId),
            _notFound()
        );
    }

    /// @notice createOrder no longer sweeps at the cap: with the registry full of stale entries
    ///  it reverts MaxTrackedMarketsReached, leaving the registry untouched, until a
    ///  NAV-evaluating call prunes the stale entries.
    function testCreateOrderAtCapRevertsWithoutSweeping() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);
        _seedPoolRegistryToCap();

        _useAdapter();
        _mockMarketInfo(0, _marketInfo(0, 0, 500_0000));
        vm.expectRevert(LighterLib.MaxTrackedMarketsReached.selector);
        IALighter(address(pool)).createOrder(0, 0, 42, 1, 2, 0, 100, 500_0000, true, false, 0);

        _useLibHarness();
        LighterLibHarness harness = LighterLibHarness(address(pool));
        assertEq(harness.trackedMarkets().length, LighterConstants.MAX_TRACKED_MARKETS);
        assertEq(harness.marketIndex(0), 0, "Traded market must not be tracked while the cap holds");
    }

    /// @notice A NAV-evaluating call prunes the stale registry (the lib function is
    ///  state-changing, like the getAppTokenBalances path it serves), after which createOrder
    ///  tracks the traded market normally.
    function testCreateOrderSucceedsAtCapAfterNavLoopPruned() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);
        _seedPoolRegistryToCap();

        _useLibHarness();
        LighterLibHarness harness = LighterLibHarness(address(pool));
        AppTokenBalance[] memory balances = harness.getLighterBalances(address(pool));
        assertEq(balances.length, 0, "Pruned registry with zero collateral: purgeable empty list");
        assertEq(harness.trackedMarkets().length, 0, "NAV loop must prune the stale registry");

        _useAdapter();
        _mockMarketInfo(0, _marketInfo(0, 0, 500_0000));
        uint64 reqId = IALighter(address(pool)).createOrder(0, 0, 42, 1, 2, 0, 100, 500_0000, true, false, 0);
        assertEq(reqId, 1);

        _useLibHarness();
        uint16[] memory markets = harness.trackedMarkets();
        assertEq(markets.length, 1);
        assertEq(markets[0], 0);
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
        // Market 0 (ETH-PERP): size_decimals 4, price_decimals 2 (LighterConstants table).
        _mockMarketInfo(0, _marketInfo(0, 0, 51_00));
        libHarness.trackMarket(0);
        _mockAccountInfo(address(libHarness), _accountInfo(1_000_000e6));
        // 100 base units long; entry notional 100 * 50.0 = 5000 USDC = 5e9 (Core USDC base units).
        _mockPosition(address(libHarness), 0, _position(100_0000, 5_000_000_000, 0, 0));

        AppTokenBalance[] memory balances = libHarness.getLighterBalances(address(libHarness));
        // markValue = 100_0000 * 51_00 * 1e6 / 10^(4+2) = 5100e6; pnl = 5100e6 - 5000e6 = 100e6.
        assertEq(balances.length, 1);
        assertEq(balances[0].amount, int256(1_000_000e6) + 100e6);
    }

    function testGetLighterBalancesShortLoss() public {
        _mockMarketInfo(0, _marketInfo(0, 0, 51_00));
        libHarness.trackMarket(0);
        _mockAccountInfo(address(libHarness), _accountInfo(1_000_000e6));
        // A short (negative position) loses when the mark price rises above the entry notional.
        _mockPosition(address(libHarness), 0, _position(-100_0000, 5_000_000_000, 0, 0));

        AppTokenBalance[] memory balances = libHarness.getLighterBalances(address(libHarness));
        assertEq(balances.length, 1);
        assertEq(balances[0].amount, int256(1_000_000e6) - 100e6);
    }

    function testGetLighterBalancesIsolatedMargin() public {
        // Mark equals entry: zero unrealized PnL; only the isolated margin is added.
        _mockMarketInfo(0, _marketInfo(0, 0, 50_00));
        libHarness.trackMarket(0);
        _mockAccountInfo(address(libHarness), _accountInfo(100e6));
        _mockPosition(address(libHarness), 0, _position(100_0000, 5_000_000_000, 1, 500e6));

        AppTokenBalance[] memory balances = libHarness.getLighterBalances(address(libHarness));
        // Devnet 1.1.0: allocatedMargin is already USDC base units (1e6 per USDC).
        assertEq(balances.length, 1);
        assertEq(balances[0].amount, 600e6);
    }

    /// @notice With no tracked state a zero total reports the purgeable empty list; the account
    ///  existing alone no longer pins the app bit.
    function testGetLighterBalancesZeroWithoutCorePosition() public {
        _mockAccountInfo(address(libHarness), _accountInfo(0));

        AppTokenBalance[] memory balances = libHarness.getLighterBalances(address(libHarness));
        assertEq(balances.length, 0);
    }

    /// @notice A zero-PnL open position keeps a dust value so the position stays valued and the
    ///  app bit cannot be purged while a position is open.
    function testGetLighterBalancesDustWithZeroPnlOpenPosition() public {
        _mockMarketInfo(0, _marketInfo(0, 0, 51_00));
        libHarness.trackMarket(0);
        _mockAccountInfo(address(libHarness), _accountInfo(0));
        // Mark 51.0, entry notional equal: markValue = 100_0000 * 51_00 * 1e6 / 10^(4+2) = 5100e6.
        _mockPosition(address(libHarness), 0, _position(100_0000, 5_100_000_000, 0, 0));

        AppTokenBalance[] memory balances = libHarness.getLighterBalances(address(libHarness));
        assertEq(balances.length, 1);
        assertEq(balances[0].amount, 1, "Zero-PnL open position keeps the dust value");
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
        _mockAccountInfo(address(libHarness), _accountInfo(10e6));

        libHarness.recordAction(100e6, 1);
        _mockTxStatus(1, 0);

        // Pending: in-flight applies on top of the Core collateral.
        AppTokenBalance[] memory balances = libHarness.getLighterBalances(address(libHarness));
        assertEq(balances[0].amount, 110e6, "Pending deposit must apply as in-flight");

        // Processed (status 1): collateral is authoritative, in-flight drops — same block or not.
        _mockTxStatus(1, 1);
        balances = libHarness.getLighterBalances(address(libHarness));
        assertEq(balances[0].amount, 10e6, "Processed deposit must drop in-flight");

        // Failed (status 2): same as processed for the in-flight purpose.
        _mockTxStatus(1, 2);
        libHarness.recordAction(50e6, 2);
        _mockTxStatus(2, 2);
        balances = libHarness.getLighterBalances(address(libHarness));
        assertEq(balances[0].amount, 10e6, "Failed write must not keep in-flight");
    }

    function testInFlightExpiresWithSettlementWindow() public {
        _mockAccountInfo(address(libHarness), _accountInfo(10e6));

        libHarness.recordAction(100e6, 1);
        _mockTxStatus(1, 0);

        // Beyond the settlement window the pending amount is dropped regardless of status.
        vm.warp(block.timestamp + 17 seconds);
        AppTokenBalance[] memory balances = libHarness.getLighterBalances(address(libHarness));
        assertEq(balances[0].amount, 10e6, "In-flight must expire with the settlement window");
    }

    /// @notice A failed tx-status read propagates as LighterReadFailed: within the settlement
    ///  window the status is authoritative and must not be silently dropped.
    function testInFlightReadFailureReverts() public {
        _mockAccountInfo(address(libHarness), _accountInfo(0));

        libHarness.recordAction(100e6, 1);
        // Per the Lighter docs the read fails (reverts) for an unknown request.
        vm.mockCallRevert(_readCore, abi.encodePacked(LighterLib._SELECTOR_TX_STATUS, uint64(1)), "");
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
        adapter.createOrder(0, 0, 0, 0, 0, 0, 100, 500_0000, true, false, 0);
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
