// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {LighterLib} from "../../contracts/protocol/libraries/LighterLib.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {LighterTypes} from "../../contracts/protocol/types/LighterTypes.sol";
import {StorageLib} from "../../contracts/protocol/libraries/StorageLib.sol";
import {LighterConstants} from "../../contracts/protocol/types/LighterConstants.sol";
import {LighterSlot, LighterData} from "../../contracts/protocol/types/Applications.sol";
import {AppTokenBalance} from "../../contracts/protocol/types/ExternalApp.sol";

/// @notice Simple ERC20 used as the LighterEVM USDC stand-in (etched at the USDC predeploy address).
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

/// @notice Exposes LighterLib internals for unit testing.
/// @dev The lib reads the Lighter slot from the executing contract's own storage: tracked
///  markets and in-flight accounting all run against the harness's storage. The async-leg
///  detection reads the executing contract's USDC balance, so the harness is the token account.
contract LighterLibHarness {
    address internal constant USDC = LighterConstants.USDC;

    function getLighterBalances(address account, bool canPrune) external returns (AppTokenBalance[] memory) {
        return LighterLib.getLighterBalances(account, canPrune);
    }

    function trackMarket(uint16 marketId) external {
        LighterLib.trackMarket(marketId);
    }

    function readPosition(address account, uint16 marketId) external view returns (LighterTypes.Position memory) {
        return LighterLib.readPosition(account, marketId);
    }

    /// @notice Seeds a tracked-market entry directly into storage, bypassing the Core validation,
    ///  so the 32-entry cap can be exercised with any market ids.
    function seedTrackedMarket(uint16 marketId) external {
        LighterSlot storage slot = StorageLib.lighterSlot();
        slot.marketIndex[marketId] = slot.trackedMarkets.length + 1;
        slot.trackedMarkets.push(marketId);
    }

    function coreAccountExists(address account) external view returns (bool) {
        return LighterLib.coreAccountExists(account);
    }

    function recordAction(int256 amount, uint64 reqId) external {
        LighterLib.recordAction(amount, reqId);
    }

    function assertNavUnlocked() external view {
        require(StorageLib.lighterSlot().data.lastReqId == 0, LighterLib.NavLocked());
    }

    function lighterData() external view returns (LighterData memory) {
        return StorageLib.lighterSlot().data;
    }

    /// @notice Moves USDC out of the harness, simulating the interop manager pulling a deposit.
    function transferUsdc(address to, uint256 amount) external {
        IERC20(USDC).transfer(to, amount);
    }

    function marketIndex(uint16 marketId) external view returns (uint256) {
        return StorageLib.lighterSlot().marketIndex[marketId];
    }

    function trackedMarkets() external view returns (uint16[] memory) {
        return StorageLib.lighterSlot().trackedMarkets;
    }
}

/// @title LighterLibTest
/// @notice Non-fork unit tests for LighterLib's deterministic READ_CORE reads, tracked-market
///  registry validation, the NAV-loop pruning of stale tracked markets, the quoteMultiplier/funding
///  NAV formula and the status-driven in-flight accounting.
/// @dev Per the Lighter docs every read except tx status returns the
///  abi.encode(bool found, bytes data) envelope: found=false (with empty data, read still
///  succeeding) means the queried account/asset/market does not exist, while a failed
///  staticcall means a malformed query. Mocks below reproduce the envelope.
contract LighterLibTest is Test {
    LighterLibHarness internal harness;

    address internal constant READ_CORE = LighterConstants.READ_CORE;
    address internal constant USDC = LighterConstants.USDC;
    address internal constant ACCOUNT = address(0xabc);

    function setUp() public {
        harness = new LighterLibHarness();
        MockERC20 usdc = new MockERC20();
        vm.etch(USDC, address(usdc).code);
        _mockAccountInfo(ACCOUNT, _accountInfo(0));
    }

    // =========================================================================
    // READ_CORE mock helpers (found/data envelope, per the Lighter docs)
    // =========================================================================

    function _wrap(bytes memory data) internal pure returns (bytes memory) {
        return abi.encode(true, data);
    }

    function _notFound() internal pure returns (bytes memory) {
        return abi.encode(false, bytes(""));
    }

    function _mockAccountInfo(address account, LighterTypes.AccountInfo memory info) private {
        vm.mockCall(
            READ_CORE,
            abi.encodePacked(LighterLib._SELECTOR_ACCOUNT_INFO, account, false),
            _wrap(abi.encode(info))
        );
    }

    function _mockMarketInfo(uint16 marketId, uint8 marketType, uint32 quoteAssetId, uint32 quoteMultiplier) private {
        vm.mockCall(
            READ_CORE,
            abi.encodePacked(LighterLib._SELECTOR_MARKET_INFO, marketId),
            _wrap(abi.encode(_marketInfo(marketType, quoteAssetId, quoteMultiplier, 500_0000)))
        );
    }

    /// @notice Perp market-info mock (marketType 0) with a specific mark price and quoteMultiplier.
    function _mockMarketInfoWithPrice(uint16 marketId, uint64 markPrice, uint32 quoteMultiplier) private {
        vm.mockCall(
            READ_CORE,
            abi.encodePacked(LighterLib._SELECTOR_MARKET_INFO, marketId),
            _wrap(abi.encode(_marketInfo(0, 0, quoteMultiplier, markPrice)))
        );
    }

    /// @notice Perp market-info mock with explicit funding prefix sums.
    function _mockMarketInfoFull(
        uint16 marketId,
        uint64 markPrice,
        uint32 quoteMultiplier,
        int64 fundingRatePrefixSum
    ) private {
        LighterTypes.MarketInfo memory info = _marketInfo(0, 0, quoteMultiplier, markPrice);
        info.fundingRatePrefixSum = fundingRatePrefixSum;
        vm.mockCall(READ_CORE, abi.encodePacked(LighterLib._SELECTOR_MARKET_INFO, marketId), _wrap(abi.encode(info)));
    }

    function _marketInfo(
        uint8 marketType,
        uint32 quoteAssetId,
        uint32 quoteMultiplier,
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
                markPrice: markPrice,
                quoteMultiplier: quoteMultiplier,
                fundingRatePrefixSum: 0,
                lastFundingRoundTimestamp: 0
            });
    }

    function _mockPosition(address account, uint16 marketId, LighterTypes.Position memory position) private {
        vm.mockCall(
            READ_CORE,
            abi.encodePacked(LighterLib._SELECTOR_POSITION, account, false, marketId),
            _wrap(abi.encode(position))
        );
    }

    /// @notice found=false envelope: the position read succeeds and reports "no position".
    function _mockPositionNotFound(address account, uint16 marketId) internal {
        vm.mockCall(READ_CORE, abi.encodePacked(LighterLib._SELECTOR_POSITION, account, false, marketId), _notFound());
    }

    /// @notice Tx status is the one read without the (bool found, bytes) envelope.
    function _mockTxStatus(uint64 reqId, uint8 status, bytes memory payload) internal {
        vm.mockCall(READ_CORE, abi.encodePacked(LighterLib._SELECTOR_TX_STATUS, reqId), abi.encode(status, payload));
    }

    /// @notice found=false means "no account": coreAccountExists reports false.
    function testCoreAccountExistsFalseWhenNotFound() public {
        vm.mockCall(READ_CORE, abi.encodePacked(LighterLib._SELECTOR_ACCOUNT_INFO, ACCOUNT, false), _notFound());
        assertFalse(harness.coreAccountExists(ACCOUNT));
    }

    /// @notice A failed staticcall is a malformed-query error, not "not found": it reverts.
    function testCoreAccountExistsRevertsOnFailedRead() public {
        vm.mockCallRevert(READ_CORE, abi.encodePacked(LighterLib._SELECTOR_ACCOUNT_INFO, ACCOUNT, false), "");
        vm.expectRevert(LighterLib.LighterReadFailed.selector);
        harness.coreAccountExists(ACCOUNT);
    }

    function testCoreAccountExistsTrueOnSixWords() public {
        assertTrue(harness.coreAccountExists(ACCOUNT));
    }

    /// @notice An envelope claiming found=true with a malformed inner payload reverts at the
    ///  tuple decode instead of being silently treated as "no position".
    function testReadPositionRevertsOnMalformedSuccessfulData() public {
        // found=true wrapping fewer words than the 8-field Position tuple.
        vm.mockCall(
            READ_CORE,
            abi.encodePacked(LighterLib._SELECTOR_POSITION, ACCOUNT, false, uint16(1)),
            abi.encode(true, new bytes(6 * 32))
        );
        vm.expectRevert();
        harness.readPosition(ACCOUNT, 1);
    }

    /// @notice Regression (audit: same-block prune of a freshly tracked market). Pruning is
    ///  operator-gated: a permissionless evaluation reading the stale parent-Core snapshot (no
    ///  position yet) keeps the market tracked, so the live position is valued once Core
    ///  reflects it; only an operator evaluation prunes, which is self-harm and out of scope.
    function testFreshMarketSurvivesStaleEmptyReadWhenEvalIsPermissionless() public {
        _track(1);
        _mockPositionNotFound(ACCOUNT, 1);
        _mockAccountInfo(ACCOUNT, _accountInfo(0));

        // Permissionless evaluations (canPrune = false), same block and later: never pruned.
        AppTokenBalance[] memory balances = harness.getLighterBalances(ACCOUNT, false);
        assertEq(harness.trackedMarkets().length, 1, "Permissionless eval must not prune");
        vm.roll(block.number + 1);
        balances = harness.getLighterBalances(ACCOUNT, false);
        assertEq(harness.trackedMarkets().length, 1, "Still not pruned by a later permissionless eval");

        // Core reflects the position: valued, still tracked.
        _mockPosition(ACCOUNT, 1, _position(100, 1, 0));
        balances = harness.getLighterBalances(ACCOUNT, false);
        assertEq(harness.trackedMarkets().length, 1);

        // An operator evaluation on a stale empty snapshot prunes (documented self-harm).
        _mockPositionNotFound(ACCOUNT, 1);
        balances = harness.getLighterBalances(ACCOUNT, true);
        assertEq(harness.trackedMarkets().length, 0, "Operator-gated eval prunes the empty market");
        assertEq(harness.marketIndex(1), 0);
    }

    /// @notice A zero-PnL open position keeps a dust value so the position stays valued and the
    ///  app bit cannot be purged while a position is open.
    function testGetLighterBalancesDustWithZeroPnlOpenPosition() public {
        _track(1);
        // quoteMultiplier 1: markValue = 100 * 5_000_000 = 500_000_000; entry notional set equal.
        _mockMarketInfoWithPrice(1, 5_000_000, 1);
        LighterTypes.Position memory position = _position(100, 0, 0);
        position.entryQuote = 500_000_000;
        _mockPosition(ACCOUNT, 1, position);

        AppTokenBalance[] memory balances = harness.getLighterBalances(ACCOUNT, true);
        assertEq(balances.length, 1);
        assertEq(balances[0].amount, 1, "Zero-PnL open position keeps the dust value");
    }

    /// @notice A negative total is returned as-is: the liability stays in NAV, the list stays
    ///  non-empty and the app cannot be purged while the pool owes money (mirrors
    ///  HyperliquidLib's sign handling).
    function testGetLighterBalancesNegativeTotalReturnedAsIs() public {
        _track(1);
        _mockMarketInfoWithPrice(1, 5_100_000, 1);
        // Entry notional 500_000_000, mark value 100 * 5_100_000 = 510_000_000 → PnL -10_000_000
        //  on a short; zero collateral.
        LighterTypes.Position memory position = _position(-100, 0, 0);
        position.entryQuote = 500_000_000;
        _mockPosition(ACCOUNT, 1, position);

        AppTokenBalance[] memory balances = harness.getLighterBalances(ACCOUNT, true);
        assertEq(balances.length, 1, "A negative liability keeps the list non-empty");
        assertEq(balances[0].amount, -10_000_000, "Negative total must be returned as-is");
    }

    // =========================================================================
    // Struct builders and tracking helpers
    // =========================================================================

    function _accountInfo(int128 collateral) internal pure returns (LighterTypes.AccountInfo memory) {
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

    function _position(
        int64 positionSize,
        uint64 totalOrderCount,
        uint64 totalPositionTiedOrderCount
    ) internal pure returns (LighterTypes.Position memory) {
        return
            LighterTypes.Position({
                size: positionSize,
                entryQuote: 0,
                initialMarginFraction: 0,
                totalOrderCount: totalOrderCount,
                totalPositionTiedOrderCount: totalPositionTiedOrderCount,
                marginMode: 0,
                allocatedMargin: 0,
                lastFundingRatePrefixSum: 0
            });
    }

    function _track(uint16 marketId) internal {
        // Perps carry quoteAssetId == 0 on Core (docs + live devnet verification): marketType == 0
        // is the USDC-settlement guarantee. Since devnet 1.2.0 any perp market with a nonzero
        // quoteMultiplier can be tracked — no release-time decimals table.
        _mockMarketInfo(marketId, 0, 0, 1);
        harness.trackMarket(marketId);
    }

    // =========================================================================
    // trackMarket validation
    // =========================================================================

    function testTrackDuplicateIsSilentNoOp() public {
        _track(1);
        _mockMarketInfo(1, 0, 0, 1);
        harness.trackMarket(1);
        assertEq(harness.trackedMarkets().length, 1);
        assertGt(harness.marketIndex(1), 0);
    }

    /// @notice Since devnet 1.2.0 any Core perp market can be tracked: the on-chain
    ///  quoteMultiplier replaced the release-time decimals table.
    function testTrackAnyPerpMarketWithQuoteMultiplier() public {
        _mockMarketInfo(9, 0, 0, 1);
        harness.trackMarket(9);
        assertGt(harness.marketIndex(9), 0);
    }

    function testNonPerpMarketReverts() public {
        _mockMarketInfo(1, 1, LighterConstants.USDC_ASSET_INDEX, 0);
        vm.expectRevert(LighterLib.InvalidMarket.selector);
        harness.trackMarket(1);
    }

    /// @notice A zero quoteMultiplier (e.g. a spot market posing as a perp) would silently zero
    ///  every position value: tracking reverts.
    function testZeroQuoteMultiplierReverts() public {
        _mockMarketInfo(1, 0, 0, 0);
        vm.expectRevert(LighterLib.InvalidMarket.selector);
        harness.trackMarket(1);
    }

    /// @notice A market absent from Core reports found=false and reverts LighterReadFailed.
    function testNonexistentMarketRevertsReadFailed() public {
        vm.mockCall(READ_CORE, abi.encodePacked(LighterLib._SELECTOR_MARKET_INFO, uint16(1)), _notFound());
        vm.expectRevert(LighterLib.LighterReadFailed.selector);
        harness.trackMarket(1);
    }

    /// @notice Perps are USDC-settled by protocol design; Core reports quoteAssetId == 0 for
    ///  perpetuals (docs + live devnet verification), and that layout must track successfully.
    function testPerpTracksWithZeroQuoteAssetId() public {
        _track(1);
        assertGt(harness.marketIndex(1), 0);
    }

    // =========================================================================
    // NAV valuation: quoteMultiplier and pending funding (devnet 1.2.0)
    // =========================================================================

    /// @notice The on-chain quoteMultiplier converts size * markPrice to USDC base units:
    ///  value = size * quoteMultiplier * markPrice - signedEntryQuote.
    function testQuoteMultiplierDrivesPositionValue() public {
        _track(1);
        _mockMarketInfoWithPrice(1, 5_000_000, 2);
        _mockAccountInfo(ACCOUNT, _accountInfo(0));
        // size 100, qm 2, mark 5_000_000 → markValue 1_000_000_000; entry 900_000_000 → +100_000_000.
        LighterTypes.Position memory position = _position(100, 0, 0);
        position.entryQuote = 900_000_000;
        _mockPosition(ACCOUNT, 1, position);

        AppTokenBalance[] memory balances = harness.getLighterBalances(ACCOUNT, true);
        assertEq(balances[0].amount, 100_000_000);
    }

    /// @notice Funding settles into Core collateral only when a transaction next touches the
    ///  position, so the collateral read lags: NAV adds pendingFunding =
    ///  size * qm * (lastFundingRatePrefixSum - fundingRatePrefixSum) / 1e6.
    function testPendingFundingAddedToNav() public {
        _track(1);
        // Funding moved 1_000_000 against the position since it was last settled.
        _mockMarketInfoFull(1, 5_000_000, 1, 1_100_000);
        _mockAccountInfo(ACCOUNT, _accountInfo(0));
        LighterTypes.Position memory position = _position(100_000, 0, 0);
        position.entryQuote = 500_000_000_000; // markValue = 100_000 * 5_000_000 = 500_000_000_000 → zero PnL
        position.lastFundingRatePrefixSum = 100_000;
        _mockPosition(ACCOUNT, 1, position);

        // numerator = 100_000 * 1 * (100_000 - 1_100_000) = -100_000_000_000 → /1e6 = -100_000.
        AppTokenBalance[] memory balances = harness.getLighterBalances(ACCOUNT, true);
        assertEq(balances[0].amount, -100_000, "Pending funding must be included in NAV");
    }

    /// @notice Negative pending funding with a nonzero remainder rounds toward negative
    ///  infinity, matching Core's rounding.
    function testPendingFundingRoundsTowardNegativeInfinity() public {
        _track(1);
        _mockMarketInfoFull(1, 5_000_000, 1, 1_999_999);
        _mockAccountInfo(ACCOUNT, _accountInfo(0));
        LighterTypes.Position memory position = _position(100_000, 0, 0);
        position.entryQuote = 500_000_000_000;
        position.lastFundingRatePrefixSum = 0;
        _mockPosition(ACCOUNT, 1, position);

        // numerator = 100_000 * (0 - 1_999_999) = -199_999_900_000: truncating division yields
        //  -199_999; Core rounds down to -200_000.
        AppTokenBalance[] memory balances = harness.getLighterBalances(ACCOUNT, true);
        assertEq(balances[0].amount, -200_000);
    }

    // =========================================================================
    // In-flight accounting: status-driven, one transfer at a time (devnet 1.2.0)
    // =========================================================================

    /// @notice A pending deposit (status 0) is added back to NAV — the wallet was debited while
    ///  Core shows nothing. No wall-clock window applies: the amount stays for as long as Core
    ///  takes (downtime included).
    function testInFlightPendingDepositApplies() public {
        _mockAccountInfo(ACCOUNT, _accountInfo(10e6));
        harness.recordAction(100e6, 1);
        _mockTxStatus(1, 0, bytes(""));

        vm.warp(block.timestamp + 1 days);
        AppTokenBalance[] memory balances = harness.getLighterBalances(ACCOUNT, true);
        assertEq(balances[0].amount, 110e6, "Pending deposit must apply as in-flight, indefinitely");
    }

    /// @notice A fully-accepted deposit settles: the collateral read is authoritative (no
    ///  adjustment) and the next NAV evaluation clears the record.
    function testInFlightSettledDepositClears() public {
        _mockAccountInfo(ACCOUNT, _accountInfo(10e6));
        harness.recordAction(100e6, 1);
        _mockTxStatus(1, 1, abi.encode(uint64(100e6)));

        AppTokenBalance[] memory balances = harness.getLighterBalances(ACCOUNT, true);
        assertEq(balances[0].amount, 10e6, "Settled deposit must drop the in-flight amount");
        assertEq(harness.lighterData().lastReqId, 0, "Nothing outstanding: record cleared");
    }

    /// @notice A partially-accepted deposit keeps the unaccepted remainder in NAV — the refund
    ///  is in transit and sits on neither side — until the refund lands in the wallet.
    function testInFlightPartialDepositUntilRefundLands() public {
        _mockAccountInfo(ACCOUNT, _accountInfo(10e6));
        MockERC20(USDC).mint(address(harness), 1_000e6);
        harness.recordAction(100e6, 1);

        _mockTxStatus(1, 1, abi.encode(uint64(40e6)));
        AppTokenBalance[] memory balances = harness.getLighterBalances(ACCOUNT, true);
        assertEq(balances[0].amount, 70e6, "Unaccepted remainder (60e6) stays in NAV while the refund is in transit");

        MockERC20(USDC).mint(address(harness), 60e6);
        balances = harness.getLighterBalances(ACCOUNT, true);
        assertEq(balances[0].amount, 10e6, "Refund landed: collateral read is authoritative again");
        assertEq(harness.lighterData().lastReqId, 0, "Landed leg: record cleared");
    }

    /// @notice A settled withdrawal is carried by the app (+amount): Core debited (the collateral
    ///  read excludes the amount) but the wallet not yet credited — exact while the delivery is in
    ///  transit. Once the delivery lands in the wallet the record clears and the collateral read
    ///  alone is authoritative.
    function testInFlightWithdrawalUntilDeliveryLands() public {
        MockERC20(USDC).mint(address(harness), 500e6);
        _mockAccountInfo(ACCOUNT, _accountInfo(1000e6));
        harness.recordAction(-400e6, 1);

        _mockTxStatus(1, 0, bytes(""));
        AppTokenBalance[] memory balances = harness.getLighterBalances(ACCOUNT, true);
        assertEq(balances[0].amount, 1000e6, "Pending withdrawal: no adjustment");
        assertEq(_nav(), 1500e6);

        // Core processed the debit: the collateral read drops to 600e6 and the app carries the
        //  undelivered 400e6, so wallet + app NAV is conserved while the delivery is in transit.
        _mockTxStatus(1, 1, bytes(""));
        _mockAccountInfo(ACCOUNT, _accountInfo(600e6));
        balances = harness.getLighterBalances(ACCOUNT, true);
        assertEq(balances[0].amount, 1000e6, "Core debited, delivery pending: the app carries the amount");
        assertEq(_nav(), 1500e6, "Exact while the delivery is in transit");
        vm.expectRevert(LighterLib.NavLocked.selector);
        harness.assertNavUnlocked();

        // The delivery lands in the wallet: record clears, NAV exact, lock lifts.
        MockERC20(USDC).mint(address(harness), 400e6);
        balances = harness.getLighterBalances(ACCOUNT, true);
        assertEq(balances[0].amount, 600e6, "Delivered: collateral read alone is authoritative");
        assertEq(_nav(), 1500e6);
        assertEq(harness.lighterData().lastReqId, 0, "Landed leg: record cleared");
        harness.assertNavUnlocked();
    }

    /// @notice NAV across the full transfer lifecycle: exact while pending (status 0), while a
    ///  settled leg is in transit (carried), and after the leg lands (record cleared). The settled
    ///  state locks mint/burn until the leg lands.
    function testNavAcrossTransferLifecycle() public {
        MockERC20(USDC).mint(address(harness), 500e6);
        _mockAccountInfo(ACCOUNT, _accountInfo(1000e6));

        // Initial: wallet 500e6, collateral 1000e6 → NAV 1500e6.
        assertEq(_nav(), 1500e6);

        // Full deposit of 300e6: wallet debited, request pending — added back, locked.
        harness.transferUsdc(address(0xdead), 300e6);
        harness.recordAction(300e6, 1);
        _mockTxStatus(1, 0, bytes(""));
        assertEq(_nav(), 1500e6, "Pending deposit: the amount is added back");
        vm.expectRevert(LighterLib.NavLocked.selector);
        harness.assertNavUnlocked();

        // Settled, fully accepted: collateral read shows the credit; the evaluation clears the
        //  record, so the lock lifts in the same pass.
        _mockTxStatus(1, 1, abi.encode(uint64(300e6)));
        _mockAccountInfo(ACCOUNT, _accountInfo(1300e6));
        assertEq(_nav(), 1500e6, "Settled deposit: collateral read is authoritative");
        assertEq(harness.lighterData().lastReqId, 0, "Nothing outstanding: record cleared");
        harness.assertNavUnlocked();

        // Withdrawal of 400e6: pending, neither side moved.
        harness.recordAction(-400e6, 2);
        _mockTxStatus(2, 0, bytes(""));
        assertEq(_nav(), 1500e6, "Pending withdrawal: no adjustment");
        vm.expectRevert(LighterLib.NavLocked.selector);
        harness.assertNavUnlocked();

        // Settled: Core debited (collateral 900e6); the app carries the undelivered 400e6 — exact
        //  while the delivery is in transit, locked for mint/burn.
        _mockTxStatus(2, 1, bytes(""));
        _mockAccountInfo(ACCOUNT, _accountInfo(900e6));
        assertEq(_nav(), 1500e6, "Settled withdrawal: the app carries the amount until delivery");
        vm.expectRevert(LighterLib.NavLocked.selector);
        harness.assertNavUnlocked();

        // Delivery lands in the wallet: record clears and the lock lifts in the same evaluation.
        MockERC20(USDC).mint(address(harness), 400e6);
        assertEq(_nav(), 1500e6, "Delivered: exact without adjustment");
        assertEq(harness.lighterData().lastReqId, 0);
        harness.assertNavUnlocked();
    }

    /// @notice In-flight tracking is independent of position revaluation: while a transfer is
    ///  pending (and later settled-in-transit), mark prices and funding keep moving, and the
    ///  computed NAV still equals the independent recomputation at every evaluation.
    function testNavExactWhilePositionsMoveDuringTransfer() public {
        MockERC20(USDC).mint(address(harness), 500e6);
        _mockAccountInfo(ACCOUNT, _accountInfo(1000e6));
        _track(1);
        _mockMarketInfoWithPrice(1, 5_000_000, 1);

        // Withdrawal of 400e6 pending; a 100-size long on market 1 (quoteMultiplier 1000) marks
        //  at 5_000_000: markValue = 100 * 5_000_000 * 1000 = 500_000_000_000, entry 4e11.
        harness.recordAction(-400e6, 1);
        _mockTxStatus(1, 0, bytes(""));
        _mockMarketInfoWithPrice(1, 5_000_000, 1000);
        LighterTypes.Position memory position = _position(100, 0, 0);
        position.entryQuote = 400_000_000_000;
        _mockPosition(ACCOUNT, 1, position);
        assertEq(_nav(), 1500e6 + 100_000_000_000, "Pending: transfer and mark-to-market compose");

        // Mark moves while Core has not processed anything: the pending withdrawal still needs
        //  no adjustment and NAV revalues with it.
        _mockMarketInfoWithPrice(1, 6_000_000, 1000);
        assertEq(_nav(), 1500e6 + 200_000_000_000, "Pending: only the mark moved");

        // Core debited: collateral drops to 600e6 and the app carries the undelivered 400e6;
        //  the mark moves again in the same window.
        _mockTxStatus(1, 1, bytes(""));
        _mockAccountInfo(ACCOUNT, _accountInfo(600e6));
        _mockMarketInfoWithPrice(1, 7_000_000, 1000);
        assertEq(_nav(), 1500e6 + 300_000_000_000, "Settled-in-transit: carry and revaluation compose");

        // The delivery lands: the record clears and the collateral read alone is authoritative.
        MockERC20(USDC).mint(address(harness), 400e6);
        assertEq(_nav(), 1500e6 + 300_000_000_000, "Delivered: exact without the carry");
        assertEq(harness.lighterData().lastReqId, 0);
    }

    /// @notice A confirmed deposit whose status payload is shorter than a word decodes to
    ///  accepted = 0: the full amount is treated as an outstanding refund (never-revert policy).
    function testDepositShortStatusPayloadCarriesFullAmount() public {
        _mockAccountInfo(ACCOUNT, _accountInfo(10e6));
        harness.recordAction(100e6, 1);
        _mockTxStatus(1, 1, new bytes(16));

        AppTokenBalance[] memory balances = harness.getLighterBalances(ACCOUNT, true);
        assertEq(balances[0].amount, 110e6, "Malformed accepted payload: full amount stays in NAV");
        assertEq(harness.lighterData().lastReqId, 1, "Record stays unresolved (locked)");
    }

    /// @notice A zero amount records nothing: with no record it is a pure no-op, and it never
    ///  disturbs an outstanding record.
    function testRecordActionZeroAmountIsNoOp() public {
        harness.recordAction(0, 1);
        assertEq(harness.lighterData().lastReqId, 0, "No record created");

        harness.recordAction(100e6, 1);
        harness.recordAction(0, 2);
        LighterData memory data = harness.lighterData();
        assertEq(data.lastReqId, 1, "Outstanding record untouched");
        assertEq(data.inFlightAmount, 100e6);
    }

    /// @notice Transfers are one at a time, full lifecycle: a settled-but-unlanded record (Core
    ///  confirmed, async leg still in transit) blocks a new transfer with PendingRequest instead
    ///  of being overwritten — overwriting would drop the outstanding leg's carry while the funds
    ///  are still owed to the wallet, understating NAV. Once the leg lands (the wallet has grown
    ///  by the outstanding amount), the same transfer proceeds: the record resolves and is
    ///  replaced with a fresh snapshot.
    function testRecordActionRevertsWhilePreviousLegInFlight() public {
        MockERC20(USDC).mint(address(harness), 500e6);
        _mockAccountInfo(ACCOUNT, _accountInfo(1000e6));
        harness.recordAction(-400e6, 1);
        _mockTxStatus(1, 1, bytes(""));
        _mockAccountInfo(ACCOUNT, _accountInfo(600e6));

        // Settled, delivery in transit: carried, locked.
        AppTokenBalance[] memory balances = harness.getLighterBalances(ACCOUNT, true);
        assertEq(balances[0].amount, 1000e6, "Settled withdrawal carried");
        vm.expectRevert(LighterLib.NavLocked.selector);
        harness.assertNavUnlocked();

        // A new request while the leg is in transit reverts: the previous record must resolve first.
        vm.expectRevert(LighterLib.PendingRequest.selector);
        harness.recordAction(100e6, 2);
        assertEq(harness.lighterData().lastReqId, 1, "Unresolved record must survive the revert");

        // Delivery lands (wallet grows by the outstanding amount): the record resolves and the new
        //  request replaces it with a fresh snapshot.
        MockERC20(USDC).mint(address(harness), 400e6);
        harness.recordAction(100e6, 2);
        LighterData memory data = harness.lighterData();
        assertEq(data.lastReqId, 2);
        assertEq(data.inFlightAmount, 100e6);
        assertEq(data.balanceSnapshot, 900e6, "Fresh snapshot at the new request");
        _mockTxStatus(2, 0, bytes(""));
        balances = harness.getLighterBalances(ACCOUNT, true);
        assertEq(balances[0].amount, 700e6, "New pending deposit added back; the landed leg is in the wallet");
    }

    /// @notice A plain ERC-20 transfer that covers the outstanding leg amount clears the record,
    ///  because that is the only wallet increase that can be the async leg landing.
    function testDirectTransferOfLegAmountClears() public {
        MockERC20(USDC).mint(address(harness), 500e6);
        _mockAccountInfo(ACCOUNT, _accountInfo(1000e6));
        harness.recordAction(-400e6, 1);
        _mockTxStatus(1, 1, bytes(""));
        harness.getLighterBalances(ACCOUNT, true);
        vm.expectRevert(LighterLib.NavLocked.selector);
        harness.assertNavUnlocked();

        // A direct transfer of the leg amount (no pool code involved) reads as the landing.
        MockERC20(USDC).mint(address(harness), 400e6);
        AppTokenBalance[] memory balances = harness.getLighterBalances(ACCOUNT, true);
        assertEq(balances[0].amount, 1000e6);
        assertEq(harness.lighterData().lastReqId, 0, "Record cleared by the wallet increase");
    }

    /// @notice A dust donation must NOT clear a settled withdrawal that has not yet landed.
    ///  The record and its lock survive until the full delivery amount arrives.
    function testDustDonationDoesNotClearSettledWithdrawal() public {
        MockERC20(USDC).mint(address(harness), 500e6);
        _mockAccountInfo(ACCOUNT, _accountInfo(1000e6));
        harness.recordAction(-400e6, 1);
        _mockTxStatus(1, 1, bytes(""));

        AppTokenBalance[] memory balances = harness.getLighterBalances(ACCOUNT, true);
        assertEq(balances[0].amount, 1400e6, "Carried withdrawal before donation");

        // 1 wei donation: wallet increases, but not by the leg amount.
        MockERC20(USDC).mint(address(harness), 1);
        balances = harness.getLighterBalances(ACCOUNT, true);
        assertEq(balances[0].amount, 1400e6, "App carry unchanged by dust donation");
        assertEq(harness.lighterData().lastReqId, 1, "Record must survive dust donation");
        vm.expectRevert(LighterLib.NavLocked.selector);
        harness.assertNavUnlocked();

        // Only the full delivery clears the record.
        MockERC20(USDC).mint(address(harness), 400e6 - 1);
        balances = harness.getLighterBalances(ACCOUNT, true);
        assertEq(balances[0].amount, 1000e6);
        assertEq(harness.lighterData().lastReqId, 0, "Record cleared by full delivery");
    }

    /// @notice A dust donation must NOT clear the unaccepted refund of a partially-accepted deposit.
    function testDustDonationDoesNotClearPartialDepositRefund() public {
        MockERC20(USDC).mint(address(harness), 1000e6);
        _mockAccountInfo(ACCOUNT, _accountInfo(10e6));
        harness.recordAction(100e6, 1);

        // 40 of 100 deposited accepted; 60 refund in transit.
        _mockTxStatus(1, 1, abi.encode(uint64(40e6)));
        AppTokenBalance[] memory balances = harness.getLighterBalances(ACCOUNT, true);
        assertEq(balances[0].amount, 70e6, "Unaccepted remainder carried while refund is in transit");

        // 1 wei donation is not the refund.
        MockERC20(USDC).mint(address(harness), 1);
        balances = harness.getLighterBalances(ACCOUNT, true);
        assertEq(balances[0].amount, 70e6, "App carry unchanged by dust donation");
        assertEq(harness.lighterData().lastReqId, 1, "Record must survive dust donation");
        vm.expectRevert(LighterLib.NavLocked.selector);
        harness.assertNavUnlocked();

        // The actual refund clears the record.
        MockERC20(USDC).mint(address(harness), 60e6 - 1);
        balances = harness.getLighterBalances(ACCOUNT, true);
        assertEq(balances[0].amount, 10e6, "Refund landed: collateral read is authoritative");
        assertEq(harness.lighterData().lastReqId, 0, "Record cleared by full refund");
    }

    /// @notice A donation larger than the outstanding leg also clears the record. The pool wallet
    ///  now covers the missing leg, so mint/burn can unlock and NAV is not understated.
    function testDonationLargerThanLegClearsAndUnlocks() public {
        MockERC20(USDC).mint(address(harness), 500e6);
        _mockAccountInfo(ACCOUNT, _accountInfo(1000e6));
        harness.recordAction(-400e6, 1);
        _mockTxStatus(1, 1, bytes(""));

        // Donation of 500 USDC exceeds the 400 USDC outstanding leg.
        MockERC20(USDC).mint(address(harness), 500e6);
        AppTokenBalance[] memory balances = harness.getLighterBalances(ACCOUNT, true);
        assertEq(balances[0].amount, 1000e6, "Carry dropped; collateral read alone is authoritative");
        assertEq(harness.lighterData().lastReqId, 0, "Record cleared by donation >= leg");
        harness.assertNavUnlocked();
    }

    /// @notice wallet USDC + Lighter app balance, in 6-dec USDC.
    function _nav() internal returns (uint256) {
        AppTokenBalance[] memory balances = harness.getLighterBalances(ACCOUNT, true);
        uint256 app = balances.length == 0 ? 0 : uint256(balances[0].amount);
        return MockERC20(USDC).balanceOf(address(harness)) + app;
    }

    /// @notice A rejected withdrawal (status 2) never moved anything: no adjustment, and the
    ///  record clears on the next evaluation.
    function testInFlightFailedWithdrawalClears() public {
        _mockAccountInfo(ACCOUNT, _accountInfo(1000e6));
        harness.recordAction(-400e6, 1);
        _mockTxStatus(1, 2, abi.encode(uint32(7003)));

        AppTokenBalance[] memory balances = harness.getLighterBalances(ACCOUNT, true);
        assertEq(balances[0].amount, 1000e6);
        assertEq(harness.lighterData().lastReqId, 0);
    }

    /// @notice Transfers are one at a time: a new deposit/withdrawal reverts while the previous
    ///  request is still pending, and succeeds once it settled.
    function testRecordActionRevertsWhilePreviousPending() public {
        harness.recordAction(100e6, 1);
        _mockTxStatus(1, 0, bytes(""));
        vm.expectRevert(LighterLib.PendingRequest.selector);
        harness.recordAction(50e6, 2);

        _mockTxStatus(1, 1, abi.encode(uint64(100e6)));
        harness.recordAction(50e6, 2);
        LighterData memory data = harness.lighterData();
        assertEq(data.inFlightAmount, 50e6);
        assertEq(data.lastReqId, 2);
    }

    /// @notice NavLocked whenever a transfer record is unresolved: from the request until the
    ///  leg lands; clearing (valuation) unlocks.
    function testAssertNavUnlockedLifecycle() public {
        harness.assertNavUnlocked();

        harness.recordAction(100e6, 1);
        vm.expectRevert(LighterLib.NavLocked.selector);
        harness.assertNavUnlocked();

        _mockTxStatus(1, 0, bytes(""));
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(LighterLib.NavLocked.selector);
        harness.assertNavUnlocked();

        // Nothing outstanding (fully accepted): the next valuation clears the record.
        _mockTxStatus(1, 1, abi.encode(uint64(100e6)));
        harness.getLighterBalances(ACCOUNT, true);
        harness.assertNavUnlocked();
    }

    /// @notice A failed tx-status read propagates as LighterReadFailed: the status is
    ///  authoritative and must not be silently dropped.
    function testInFlightReadFailureReverts() public {
        _mockAccountInfo(ACCOUNT, _accountInfo(0));
        harness.recordAction(100e6, 1);
        vm.mockCallRevert(READ_CORE, abi.encodePacked(LighterLib._SELECTOR_TX_STATUS, uint64(1)), "");
        vm.expectRevert(LighterLib.LighterReadFailed.selector);
        harness.getLighterBalances(ACCOUNT, true);
    }

    // =========================================================================
    // NAV-loop pruning of stale tracked markets (getLighterBalances is state-changing)
    // =========================================================================

    /// @dev Seeds MAX_TRACKED_MARKETS entries directly and reports found=false for every
    ///  position read of `account`: a not-found read is a zeroed position, i.e. an empty
    ///  (stale) market. Seeded markets carry no order reqId, so they are prunable.
    function _seedFullRegistry(address account) internal {
        for (uint256 i; i < LighterConstants.MAX_TRACKED_MARKETS; ++i) {
            uint16 marketId = 100 + uint16(i);
            harness.seedTrackedMarket(marketId);
            _mockPositionNotFound(account, marketId);
        }
        assertEq(harness.trackedMarkets().length, LighterConstants.MAX_TRACKED_MARKETS);
    }

    /// @notice The NAV loop prunes a tracked market that holds no position and no orders (and has
    ///  no pending order write), and a fully pruned registry with zero collateral and no in-flight
    ///  returns the purgeable empty list.
    function testNavLoopPrunesStaleMarket() public {
        _track(1);
        _mockPosition(ACCOUNT, 1, _position(0, 0, 0));

        AppTokenBalance[] memory balances = harness.getLighterBalances(ACCOUNT, true);

        assertEq(balances.length, 0, "Zero collateral and no active market: purgeable empty list");
        assertEq(harness.trackedMarkets().length, 0, "Stale market must be pruned by the NAV loop");
        assertEq(harness.marketIndex(1), 0);
    }

    /// @notice Markets holding an open position or open orders (including position-tied ones)
    ///  survive the NAV loop, and swap-pop keeps the survivors' 1-based indices consistent.
    function testNavLoopPreservesMarketsWithPositionOrOrders() public {
        _seedFullRegistry(ACCOUNT);
        _mockPosition(ACCOUNT, 105, _position(100, 0, 0));
        _mockPosition(ACCOUNT, 110, _position(0, 1, 0));
        _mockPosition(ACCOUNT, 115, _position(0, 0, 1));
        _mockMarketInfoWithPrice(105, 500_0000, 1);

        AppTokenBalance[] memory balances = harness.getLighterBalances(ACCOUNT, true);

        assertEq(balances.length, 1, "A surviving position keeps the list non-empty");
        uint16[] memory markets = harness.trackedMarkets();
        assertEq(markets.length, 3);
        uint16[3] memory survivors = [uint16(105), 110, 115];
        for (uint256 i; i < survivors.length; ++i) {
            uint256 index = harness.marketIndex(survivors[i]);
            assertGt(index, 0, "Stateful market must survive the NAV loop");
            assertEq(markets[index - 1], survivors[i], "Survivor index must point at the market");
        }
        assertEq(harness.marketIndex(100), 0);
    }

    /// @notice trackMarket no longer sweeps at the cap: with the registry full of stale entries,
    ///  tracking a new market reverts until a NAV-evaluating call prunes them.
    function testTrackAtCapRevertsWithoutSweeping() public {
        _seedFullRegistry(ACCOUNT);

        _mockMarketInfo(1, 0, 0, 1);
        vm.expectRevert(LighterLib.MaxTrackedMarketsReached.selector);
        harness.trackMarket(1);

        assertEq(harness.trackedMarkets().length, LighterConstants.MAX_TRACKED_MARKETS);
        assertEq(harness.marketIndex(1), 0, "New market must not be tracked while the cap holds");
    }

    /// @notice A NAV-evaluating call prunes the stale registry, so tracking succeeds afterwards.
    function testTrackSucceedsAtCapAfterNavLoopPruned() public {
        _seedFullRegistry(ACCOUNT);

        harness.getLighterBalances(ACCOUNT, true);
        assertEq(harness.trackedMarkets().length, 0, "NAV loop must prune the stale registry");

        _mockMarketInfo(1, 0, 0, 1);
        harness.trackMarket(1);
        uint16[] memory markets = harness.trackedMarkets();
        assertEq(markets.length, 1);
        assertEq(markets[0], 1);
    }
}
