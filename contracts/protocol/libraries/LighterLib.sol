// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.4;

import {StorageLib} from "../libraries/StorageLib.sol";
import {AppTokenBalance} from "../types/ExternalApp.sol";
import {LighterConstants} from "../types/LighterConstants.sol";
import {LighterSlot, LighterData, LighterViewData, TrackedMarket} from "../types/Applications.sol";
import {LighterTypes} from "../extensions/adapters/interfaces/lighter/LighterTypes.sol";

/// @title LighterLib
/// @notice Rigoblock-specific helpers for LighterEVM NAV valuation, market tracking and the
///  post-action settlement lock.
/// @dev All LighterCore state is read through the READ_CORE precompile. Unlike Hyperliquid,
///  LighterEVM has no aggregated perps account-value read: NAV is computed as shared collateral
///  plus the sum of every tracked market's position value (unrealized PnL from Core's mark price,
///  plus isolated margin). Per-market size/price decimals are stored when the operator tracks a
///  market, sourced from LighterCore's `orderBookDetails` API. See docs/lighter/INTEGRATION.md.
library LighterLib {
    error NavLocked();
    error InvalidMarketDecimals();
    error MarketAlreadyTracked();
    error MarketNotTracked();
    error MaxTrackedMarketsReached();
    error InvalidMarket();
    error LighterReadFailed();

    /// @notice Settlement lock window after any recorded Core write. See docs/lighter/INTEGRATION.md
    ///  (open questions: exact Core-state observation lag on LighterEVM).
    uint48 internal constant _SETTLEMENT_WINDOW = 16 seconds;

    /// @notice READ_CORE selectors. Input encoding is `uint16 selector` packed with the query
    ///  parameters (see docs/lighter/INTEGRATION.md for the full selector table, verified against
    ///  the live devnet precompile).
    uint16 internal constant _SELECTOR_TX_STATUS = 0x0000;
    uint16 internal constant _SELECTOR_ACCOUNT_INFO = 0x0001;
    uint16 internal constant _SELECTOR_MARKET_INFO = 0x0005;
    uint16 internal constant _SELECTOR_POSITION = 0x0007;
    uint16 internal constant _SELECTOR_EVM_ACCOUNT_INDEX = 0x0009;
    /// @dev Asset index -> EVM token address (`uint32 assetIndex` input). Used internally by the
    ///  interop manager predeploy during sendToCore; the adapter never calls it. Named here for
    ///  documentation (see docs/lighter/INTEGRATION.md selector table).
    uint16 internal constant _SELECTOR_EVM_TOKEN = 0x0004;

    /// @dev USDC has 6 decimals; Lighter's isolated-margin field uses 12-decimal USDC, so converting
    ///  to 6-decimal USDC divides by 1e6.
    int256 internal constant _ISOLATED_MARGIN_DECIMALS = 1e6;

    /// @dev 10^6 USDC smallest units per whole USDC (the only trackable quote asset).
    int256 internal constant _USDC_DECIMAL_FACTOR = 1e6;

    /// @notice Returns the pool's Lighter balances valued in USDC (6 decimals).
    /// @param account The pool address on LighterCore.
    /// @param viewData The pool's Lighter slot contents, supplied by EApps.getLighterTrackedMarkets.
    ///  The adapter runs under staticcall and cannot read pool storage itself.
    /// @dev In-flight accounting is exact while a transfer's `reqId` is pending on Core (see
    ///  _inFlightAdjustment); the time lock in assertNavUnlocked covers refund/delivery lag.
    /// @dev Reverts (rather than degrading) if a tracked market's position read fails: the market
    ///  was validated at track time, so a failure means Core state is inconsistent and an
    ///  inaccurate NAV must not be produced.
    function getLighterBalances(
        address account,
        LighterViewData memory viewData
    ) internal view returns (AppTokenBalance[] memory balances) {
        // Without a Core account there is nothing to value; this also keeps the dust/empty
        // distinction below reachable (account-info read would revert on a missing account).
        if (!coreAccountExists(account)) return balances;

        int256 totalUsdcValue = int256(readAccountInfo(account).collateralBaseAmount);

        uint16[] memory marketIds = viewData.marketIds;
        for (uint256 i; i < marketIds.length; ++i) {
            totalUsdcValue += _positionValueUsdc(
                account,
                marketIds[i],
                viewData.sizeDecimals[i],
                viewData.priceDecimals[i]
            );
        }

        totalUsdcValue += _inFlightAdjustment(viewData);

        if (totalUsdcValue == 0) {
            // Dust keeps the app valued (and the branch active) while the account exists.
            totalUsdcValue = 1;
        }

        balances = new AppTokenBalance[](1);
        balances[0] = AppTokenBalance({token: LighterConstants.USDC, amount: totalUsdcValue});
    }

    /// @dev Values a single tracked market's position in 6-decimal USDC: unrealized PnL from Core's
    ///  mark price plus, for isolated positions, the margin allocated outside the shared collateral.
    /// @dev PnL is mark-to-market value minus the signed entry value. Core semantics (docs,
    ///  "Reading Core from EVM"/position): `position` is the signed size on createOrder's amount
    ///  scale, `markPrice` is a price (quote whole units * 10^priceDecimals), and `entryQuote` is
    ///  the unsigned entry NOTIONAL in Core USDC base units (1e6 per USDC). Converting the mark
    ///  value needs the fixed USDC 1e6 factor; the entry value needs no conversion at all:
    ///   markValue = position * markPrice * 1e6 / 10^(sizeDecimals + priceDecimals)   (signed)
    ///   pnl       = markValue - (position > 0 ? entryQuote : -entryQuote)
    function _positionValueUsdc(
        address account,
        uint16 marketId,
        uint8 sizeDecimals,
        uint8 priceDecimals
    ) private view returns (int256 value) {
        LighterTypes.Position memory position = readPosition(account, marketId);
        if (position.position == 0) return 0;

        LighterTypes.MarketInfo memory marketInfo = readMarketInfo(marketId);

        int256 markValue = (int256(position.position) * int256(uint256(marketInfo.markPrice)) * _USDC_DECIMAL_FACTOR) /
            int256(10 ** (sizeDecimals + priceDecimals));
        int256 entryValue = position.position > 0
            ? int256(uint256(position.entryQuote))
            : -int256(uint256(position.entryQuote));
        value = markValue - entryValue;

        if (position.marginMode == 1) {
            // Isolated margin is not part of the shared collateral balance.
            value += int256(position.allocatedMargin) / _ISOLATED_MARGIN_DECIMALS;
        }
    }

    /// @dev Exact in-flight adjustment for a pending or just-settled transfer, driven by the
    ///  transaction-status read (READ_CORE 0x0000):
    ///   - Deposit (amount > 0): the interop manager pulled the tokens from the pool, but Core has
    ///     not credited them yet. Add the amount back while `status == 0` (pending); drop it the
    ///     block Core processes the write, because status and collateral reads in the same EVM
    ///     block are pinned to the same parent Core block, so accepted collateral is visible
    ///     exactly when status flips to 1.
    ///   - Withdrawal (amount < 0): Core debits asynchronously and EVM delivery lands in a later
    ///     exogenous transaction whose timing no read exposes. Subtract only after `status == 1`
    ///     (debit processed) — while pending, neither the collateral read nor the pool wallet has
    ///     moved, so no adjustment is needed.
    /// @dev Orders/cancels record `reqId == 0` and move no wallet balance: a pending order write
    ///  changes no Core state visible to NAV, so no adjustment is ever needed for them.
    /// @dev Only the latest reqId is tracked, and only within `_SETTLEMENT_WINDOW`: past the
    ///  window collateral/delivery are assumed settled, matching assertNavUnlocked. Batching a
    ///  deposit and a withdrawal in one block loses per-request granularity (documented).
    function _inFlightAdjustment(LighterViewData memory viewData) private view returns (int256) {
        int256 amount = int256(viewData.inFlightAmount);
        if (viewData.lastReqId == 0 || amount == 0) return 0;
        if (block.timestamp > uint256(viewData.lastActionTimestamp) + _SETTLEMENT_WINDOW) return 0;

        uint8 status = readTxStatus(viewData.lastReqId);
        if (amount > 0) {
            return status == 0 ? amount : int256(0);
        }
        return status == 1 ? amount : int256(0);
    }

    /// @notice Records a Core write for in-flight accounting and the settlement lock.
    /// @param amount Signed in-flight delta, 6-decimal USDC (deposits positive, withdrawals
    ///  negative; 0 for orders/cancels, which move no wallet balance).
    /// @param reqId Core request ID for transfers (0 for orders/cancels). A nonzero reqId only
    ///  replaces the tracked one, so an order after a deposit cannot clobber the pending
    ///  transfer's in-flight tracking.
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

    /// @notice Adds a perp market to the tracked set after validating it on Core.
    /// @dev Reverts above LighterConstants.MAX_TRACKED_MARKETS markets.
    /// @dev Perps are USDC-settled by protocol design (Core position `entryQuote`/`allocatedMargin`
    ///  and account `collateralBaseAmount` are all USDC-denominated), and the market info's
    ///  `quoteAssetId` is documented and observed to be 0 for perpetuals — so marketType == 0 is
    ///  the USDC-quotation guarantee and no quote-asset check applies.
    function trackMarket(uint16 marketId, uint8 sizeDecimals, uint8 priceDecimals) internal {
        require(sizeDecimals <= 18 && priceDecimals <= 16, InvalidMarketDecimals());
        LighterSlot storage slot = StorageLib.lighterSlot();
        require(slot.marketIndex[marketId] == 0, MarketAlreadyTracked());

        LighterTypes.MarketInfo memory marketInfo = readMarketInfo(marketId);
        require(marketInfo.marketType == 0, InvalidMarket());

        uint16[] storage markets = slot.trackedMarkets;
        require(markets.length < LighterConstants.MAX_TRACKED_MARKETS, MaxTrackedMarketsReached());

        slot.marketIndex[marketId] = markets.length + 1;
        slot.markets[marketId] = TrackedMarket({sizeDecimals: sizeDecimals, priceDecimals: priceDecimals});
        markets.push(marketId);
    }

    /// @notice Removes a tracked market. Only allowed when the pool has no open position on it.
    function untrackMarket(uint16 marketId) internal {
        LighterSlot storage slot = StorageLib.lighterSlot();
        uint256 index = slot.marketIndex[marketId];
        require(index != 0, MarketNotTracked());

        uint16[] storage markets = slot.trackedMarkets;
        // Swap-remove from the array; the moved market's index is updated.
        uint256 lastIndex = markets.length - 1;
        uint16 lastMarket = markets[lastIndex];
        markets[index - 1] = lastMarket;
        markets.pop();
        slot.marketIndex[lastMarket] = index;
        delete slot.marketIndex[marketId];
        delete slot.markets[marketId];
    }

    function isTrackedMarket(uint16 marketId) internal view returns (bool) {
        return StorageLib.lighterSlot().marketIndex[marketId] != 0;
    }

    /// @notice Position size for a tracked market; used to gate untracking closed positions.
    function positionSize(address account, uint16 marketId) internal view returns (int64) {
        return readPosition(account, marketId).position;
    }

    /// @notice True when the account controls an existing LighterCore account.
    /// @dev Per the Lighter docs a read of a nonexistent account still succeeds and reports
    ///  found = false inside the (bool, bytes) envelope; older devnet builds failed the call
    ///  outright. Tolerate both: any non-success or non-enveloped return means "no account".
    function coreAccountExists(address account) internal view returns (bool) {
        (bool success, bytes memory ret) = LighterConstants.READ_CORE.staticcall(
            abi.encodePacked(_SELECTOR_ACCOUNT_INFO, account, false)
        );
        if (!success || ret.length < 64) return false;
        (bool found, ) = abi.decode(ret, (bool, bytes));
        return found;
    }

    /// @notice Processing status of an EVM-to-Core write: 0 pending/unknown, 1 successful, 2 failed.
    /// @dev Selector 0x0000 is the only read that does NOT use the (bool found, bytes) envelope.
    function readTxStatus(uint64 reqId) internal view returns (uint8 status) {
        (status, ) = abi.decode(_readCore(abi.encodePacked(_SELECTOR_TX_STATUS, reqId)), (uint8, bytes));
    }

    function readAccountInfo(address account) internal view returns (LighterTypes.AccountInfo memory info) {
        info = abi.decode(
            _readCoreData(abi.encodePacked(_SELECTOR_ACCOUNT_INFO, account, false)),
            (LighterTypes.AccountInfo)
        );
    }

    function readMarketInfo(uint16 marketId) internal view returns (LighterTypes.MarketInfo memory info) {
        info = abi.decode(_readCoreData(abi.encodePacked(_SELECTOR_MARKET_INFO, marketId)), (LighterTypes.MarketInfo));
    }

    function readPosition(
        address account,
        uint16 marketId
    ) internal view returns (LighterTypes.Position memory position) {
        position = abi.decode(
            _readCoreData(abi.encodePacked(_SELECTOR_POSITION, account, false, marketId)),
            (LighterTypes.Position)
        );
    }

    function readEvmAccountIndex(address account) internal view returns (uint48 accountIndex) {
        accountIndex = abi.decode(_readCoreData(abi.encodePacked(_SELECTOR_EVM_ACCOUNT_INDEX, account)), (uint48));
    }

    /// @dev Reads a Core object (selectors 0x0001–0x0009). Per the Lighter docs every read
    ///  except tx status (0x0000) returns abi.encode(bool found, bytes data), with the object
    ///  payload in data; found = false when the account/asset/market does not exist.
    function _readCoreData(bytes memory payload) private view returns (bytes memory data) {
        (bool found, bytes memory inner) = abi.decode(_readCore(payload), (bool, bytes));
        require(found, LighterReadFailed());
        data = inner;
    }

    /// @dev Staticcall wrapper around READ_CORE; reverts with LighterReadFailed when the precompile
    ///  call fails or returns no data (unknown selector / malformed input).
    function _readCore(bytes memory payload) private view returns (bytes memory data) {
        bool success;
        (success, data) = LighterConstants.READ_CORE.staticcall(payload);
        require(success && data.length >= 32, LighterReadFailed());
    }
}
