// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.4;

import {StorageLib} from "../libraries/StorageLib.sol";
import {AppTokenBalance} from "../types/ExternalApp.sol";
import {LighterConstants} from "../types/LighterConstants.sol";
import {LighterSlot, LighterData, TrackedMarket} from "../types/Applications.sol";
import {LighterTypes} from "../extensions/adapters/interfaces/lighter/LighterTypes.sol";

/// @title LighterLib
/// @notice Rigoblock-specific helpers for LighterCore perps: NAV valuation, market tracking and
///  the post-action settlement lock. READ_CORE response shapes and the NAV formula are specified
///  in docs/lighter/INTEGRATION.md.
library LighterLib {
    error NavLocked();
    error MaxTrackedMarketsReached();
    error InvalidMarket();
    error LighterReadFailed();

    /// @notice Settlement lock window after any recorded Core write.
    uint48 internal constant _SETTLEMENT_WINDOW = 16 seconds;

    uint16 internal constant _SELECTOR_TX_STATUS = 0x0000;
    uint16 internal constant _SELECTOR_ACCOUNT_INFO = 0x0001;
    uint16 internal constant _SELECTOR_MARKET_INFO = 0x0005;
    uint16 internal constant _SELECTOR_POSITION = 0x0007;
    uint16 internal constant _SELECTOR_EVM_ACCOUNT_INDEX = 0x0009;

    /// @dev Isolated margin is 12-decimal USDC; everything else here is 6-decimal.
    int256 internal constant _ISOLATED_MARGIN_DECIMALS = 1e6;

    int256 internal constant _USDC_DECIMAL_FACTOR = 1e6;

    /// @notice Returns the pool's Lighter balances valued in 6-decimal USDC, pruning stale
    ///  tracked markets while looping.
    /// @dev Absence semantics follow the Lighter docs: READ_CORE fails a read for a nonexistent
    ///  account/market, so NAV degrades instead of reverting (missing account/position = zero,
    ///  unreadable mark price = position valued flat at entry). A revert here would freeze
    ///  updateUnitaryValue for every token holder; GmxLib applies the same never-revert policy.
    /// @dev This runs inside the non-view getAppTokenBalances path, so it prunes tracked markets
    ///  that hold no position and no orders as it loops (backward, swap-pop safe); see
    ///  docs/lighter/INTEGRATION.md ("Trading flow").
    function getLighterBalances(address account) internal returns (AppTokenBalance[] memory balances) {
        if (!coreAccountExists(account)) return balances;

        LighterSlot storage slot = StorageLib.lighterSlot();

        int256 totalUsdcValue = int256(readAccountInfo(account).collateralBaseAmount);

        bool hasActiveMarkets;
        bool hasInFlight = slot.data.inFlightAmount != 0;
        uint16[] storage marketIds = slot.trackedMarkets;
        for (uint256 i = marketIds.length; i > 0; --i) {
            uint16 marketId = marketIds[i - 1];
            TrackedMarket memory market = slot.markets[marketId];
            LighterTypes.Position memory position = readPosition(account, marketId);
            if (position.size == 0 && position.totalOrderCount == 0 && position.totalPositionTiedOrderCount == 0) {
                _untrackMarket(slot, marketId, i - 1);
                continue;
            }
            hasActiveMarkets = true;
            totalUsdcValue += _positionValueUsdc(position, marketId, market.sizeDecimals, market.priceDecimals);
        }

        totalUsdcValue += _inFlightAdjustment(slot.data);

        if (totalUsdcValue == 0) {
            // Dust keeps the app valued (and unpurgeable) while a position/orders or an in-flight
            //  transfer exists; otherwise the empty list lets purgeInactiveTokensAndApps drop the
            //  app bit. Mirrors HyperliquidLib's sign handling below.
            if (!hasActiveMarkets && !hasInFlight) return balances;
            totalUsdcValue = 1;
        }

        // A negative total falls through unchanged: the liability stays in NAV, the list stays
        //  non-empty and the app cannot be purged while the pool owes money (mirrors HyperliquidLib).
        balances = new AppTokenBalance[](1);
        balances[0] = AppTokenBalance({token: LighterConstants.USDC, amount: totalUsdcValue});
    }

    /// @dev Unrealized PnL of one position from Core's mark price, plus isolated margin (which
    ///  sits outside the shared collateral). If the mark price is unreadable the position is
    ///  valued flat at its entry notional (zero PnL).
    function _positionValueUsdc(
        LighterTypes.Position memory position,
        uint16 marketId,
        uint8 sizeDecimals,
        uint8 priceDecimals
    ) private view returns (int256 value) {
        if (position.size == 0) return 0;

        int256 entryValue = position.size > 0
            ? int256(uint256(position.entryQuote))
            : -int256(uint256(position.entryQuote));

        (bool found, LighterTypes.MarketInfo memory marketInfo) = _tryReadMarketInfo(marketId);
        value = found
            ? ((int256(position.size) * int256(uint256(marketInfo.markPrice)) * _USDC_DECIMAL_FACTOR) /
                int256(10 ** (sizeDecimals + priceDecimals))) - entryValue
            : int256(0);

        if (position.marginMode == 1) {
            value += int256(position.allocatedMargin) / _ISOLATED_MARGIN_DECIMALS;
        }
    }

    /// @dev In-flight adjustment for a pending or just-settled transfer, driven by the
    ///  transaction-status read. See docs/lighter/INTEGRATION.md ("In-flight accounting").
    function _inFlightAdjustment(LighterData memory data) private view returns (int256) {
        int256 amount = int256(data.inFlightAmount);
        if (data.lastReqId == 0 || amount == 0) return 0;
        if (block.timestamp > uint256(data.lastActionTimestamp) + _SETTLEMENT_WINDOW) return 0;

        uint8 status = readTxStatus(data.lastReqId);
        if (amount > 0) {
            return status == 0 ? amount : int256(0);
        }
        return status == 1 ? amount : int256(0);
    }

    /// @notice Records a Core write for in-flight accounting and the settlement lock.
    function recordAction(int256 amount, uint64 reqId) internal {
        LighterSlot storage slot = StorageLib.lighterSlot();
        if (reqId != 0) {
            if (slot.data.lastActionBlock != block.number) {
                slot.data.inFlightAmount = 0;
            }
            slot.data.inFlightAmount += int128(amount);
            slot.data.lastReqId = reqId;
        }
        slot.data.lastActionBlock = uint48(block.number);
        slot.data.lastActionTimestamp = uint48(block.timestamp);
    }

    /// @notice Reverts while NAV reads may still be stale after a Core deposit/withdrawal.
    function assertNavUnlocked() internal view {
        LighterData memory data = StorageLib.lighterSlot().data;
        if (data.lastActionBlock == 0) return;
        if (data.lastActionBlock == block.number) return;
        require(block.timestamp >= data.lastActionTimestamp + _SETTLEMENT_WINDOW, NavLocked());
    }

    /// @notice Tracks a perp market for NAV valuation, validating it against Core. No-op when
    ///  already tracked. Called by ALighter on every createOrder so the traded market is always
    ///  valued; decimals come from the LighterConstants release-time table, never from calldata.
    /// @dev Reverts with LighterConstants.UnknownMarket for markets absent from the decimals
    ///  table, with InvalidMarket for non-perp markets, and with MaxTrackedMarketsReached at
    ///  LighterConstants.MAX_TRACKED_MARKETS. Stale entries are pruned by the NAV loop in
    ///  getLighterBalances instead, so an order that hits a full list of stale entries reverts
    ///  until any NAV-evaluating tx (updateUnitaryValue/mint/purge — or even an eth_call read,
    ///  since the pruning is state-changing) removes them.
    function trackMarket(uint16 marketId) internal {
        LighterSlot storage slot = StorageLib.lighterSlot();
        if (slot.marketIndex[marketId] != 0) return;

        (uint8 sizeDecimals, uint8 priceDecimals) = LighterConstants.marketDecimals(marketId);
        LighterTypes.MarketInfo memory marketInfo = readMarketInfo(marketId);
        require(marketInfo.marketType == 0, InvalidMarket());

        uint16[] storage markets = slot.trackedMarkets;
        require(markets.length < LighterConstants.MAX_TRACKED_MARKETS, MaxTrackedMarketsReached());

        slot.marketIndex[marketId] = markets.length + 1;
        slot.markets[marketId] = TrackedMarket({sizeDecimals: sizeDecimals, priceDecimals: priceDecimals});
        markets.push(marketId);
    }

    /// @dev Swap-removes a tracked market and its decimal scales; no Core reads, no requires.
    function _untrackMarket(LighterSlot storage slot, uint16 marketId, uint256 listIndex) private {
        uint16[] storage markets = slot.trackedMarkets;
        uint256 lastIndex = markets.length - 1;
        uint16 lastMarket = markets[lastIndex];
        markets[listIndex] = lastMarket;
        markets.pop();
        if (lastMarket != marketId) {
            slot.marketIndex[lastMarket] = listIndex + 1;
        }
        delete slot.marketIndex[marketId];
        delete slot.markets[marketId];
    }

    /// @notice True when the account controls an existing LighterCore account. Per the Lighter
    ///  docs the account-info read fails when the account does not exist, so success alone is
    ///  the existence proof.
    function coreAccountExists(address account) internal view returns (bool success) {
        (success, ) = LighterConstants.READ_CORE.staticcall(abi.encodePacked(_SELECTOR_ACCOUNT_INFO, account, false));
    }

    /// @notice Processing status of an EVM-to-Core write: 0 pending/unknown, 1 successful,
    ///  2 failed (data then holds abi.encode(uint32 errorCode)).
    function readTxStatus(uint64 reqId) internal view returns (uint8 status) {
        (status, ) = abi.decode(_readCore(abi.encodePacked(_SELECTOR_TX_STATUS, reqId)), (uint8, bytes));
    }

    function readAccountInfo(address account) internal view returns (LighterTypes.AccountInfo memory info) {
        info = abi.decode(
            _readCore(abi.encodePacked(_SELECTOR_ACCOUNT_INFO, account, false)),
            (LighterTypes.AccountInfo)
        );
    }

    function readMarketInfo(uint16 marketId) internal view returns (LighterTypes.MarketInfo memory info) {
        info = abi.decode(_readCore(abi.encodePacked(_SELECTOR_MARKET_INFO, marketId)), (LighterTypes.MarketInfo));
    }

    /// @notice Reads a position; per the Lighter docs the read fails when the account or market
    ///  does not exist, which here means "no position". An existing market with no position
    ///  returns a zeroed struct directly.
    function readPosition(
        address account,
        uint16 marketId
    ) internal view returns (LighterTypes.Position memory position) {
        (bool success, bytes memory ret) = LighterConstants.READ_CORE.staticcall(
            abi.encodePacked(_SELECTOR_POSITION, account, false, marketId)
        );
        if (!success) return position;
        position = abi.decode(ret, (LighterTypes.Position));
    }

    function readEvmAccountIndex(address account) internal view returns (uint48 accountIndex) {
        accountIndex = abi.decode(_readCore(abi.encodePacked(_SELECTOR_EVM_ACCOUNT_INDEX, account)), (uint48));
    }

    /// @dev NAV variant of readMarketInfo: failure reports found=false so the position can be
    ///  valued flat instead of freezing NAV.
    function _tryReadMarketInfo(
        uint16 marketId
    ) internal view returns (bool found, LighterTypes.MarketInfo memory info) {
        (bool success, bytes memory ret) = LighterConstants.READ_CORE.staticcall(
            abi.encodePacked(_SELECTOR_MARKET_INFO, marketId)
        );
        if (!success) return (false, info);
        found = true;
        info = abi.decode(ret, (LighterTypes.MarketInfo));
    }

    /// @dev Staticcall wrapper around READ_CORE; reverts with LighterReadFailed when the
    ///  precompile rejects the query (unknown selector, malformed input, nonexistent
    ///  account/asset/market per the Lighter docs).
    function _readCore(bytes memory payload) private view returns (bytes memory data) {
        bool success;
        (success, data) = LighterConstants.READ_CORE.staticcall(payload);
        require(success, LighterReadFailed());
    }
}
