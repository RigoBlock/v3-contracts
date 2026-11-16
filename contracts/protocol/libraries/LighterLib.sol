// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.4;

import {StorageLib} from "../libraries/StorageLib.sol";
import {AppTokenBalance} from "../types/ExternalApp.sol";
import {LighterConstants} from "../types/LighterConstants.sol";
import {LighterSlot, LighterData} from "../types/Applications.sol";
import {LighterTypes} from "../extensions/adapters/interfaces/lighter/LighterTypes.sol";

/// @title LighterLib
/// @notice Rigoblock-specific helpers for LighterCore perps: NAV valuation, market tracking and
///  status-driven in-flight accounting. READ_CORE response shapes and the NAV formula are
///  specified in docs/lighter/INTEGRATION.md.
library LighterLib {
    error NavLocked();
    error PendingRequest();
    error MaxTrackedMarketsReached();
    error InvalidMarket();
    error LighterReadFailed();

    uint16 internal constant _SELECTOR_TX_STATUS = 0x0000;
    uint16 internal constant _SELECTOR_ACCOUNT_INFO = 0x0001;
    uint16 internal constant _SELECTOR_MARKET_INFO = 0x0005;
    uint16 internal constant _SELECTOR_POSITION = 0x0007;
    uint16 internal constant _SELECTOR_EVM_ACCOUNT_INDEX = 0x0009;

    /// @notice Returns the pool's Lighter balances valued in 6-decimal USDC, pruning stale
    ///  tracked markets while looping.
    /// @dev Absence semantics follow the Lighter docs: READ_CORE reports found=false for a
    ///  nonexistent account/market, so NAV degrades instead of reverting (missing
    ///  account/position = zero, unreadable mark price = position valued flat at entry). A
    ///  revert here would freeze updateUnitaryValue for every token holder; GmxLib applies the
    ///  same never-revert policy.
    /// @dev This runs inside the non-view getAppTokenBalances path, so it prunes tracked markets
    ///  that hold no position and no orders as it loops (backward, swap-pop safe) and clears
    ///  fully-settled in-flight requests; see docs/lighter/INTEGRATION.md ("Trading flow").
    function getLighterBalances(address account) internal returns (AppTokenBalance[] memory balances) {
        if (!coreAccountExists(account)) return balances;

        LighterSlot storage slot = StorageLib.lighterSlot();

        int256 totalUsdcValue = int256(readAccountInfo(account).collateralBaseAmount);

        bool hasActiveMarkets;
        bool hasInFlight = slot.data.inFlightAmount != 0;
        uint16[] storage marketIds = slot.trackedMarkets;
        for (uint256 i = marketIds.length; i > 0; --i) {
            uint16 marketId = marketIds[i - 1];
            LighterTypes.Position memory position = readPosition(account, marketId);
            if (position.size == 0 && position.totalOrderCount == 0 && position.totalPositionTiedOrderCount == 0) {
                _untrackMarket(slot, marketId, i - 1);
                continue;
            }
            hasActiveMarkets = true;
            totalUsdcValue += _positionValueUsdc(position, marketId);
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

    /// @dev Unrealized PnL of one position from Core's mark price, plus pending funding (funding
    ///  settles into Core collateral only when a transaction next touches the position, so the
    ///  collateral read lags) and isolated margin (which sits outside the shared collateral).
    ///  Devnet 1.2.0 formula, USDC base units: value = size * markPrice * quoteMultiplier.
    function _positionValueUsdc(
        LighterTypes.Position memory position,
        uint16 marketId
    ) private view returns (int256 value) {
        if (position.size == 0) return 0;

        int256 entryValue = position.size > 0
            ? int256(uint256(position.entryQuote))
            : -int256(uint256(position.entryQuote));

        (bool found, LighterTypes.MarketInfo memory marketInfo) = _tryReadMarketInfo(marketId);
        if (found) {
            int256 quoteMultiplier = int256(uint256(marketInfo.quoteMultiplier));
            value = (int256(position.size) * quoteMultiplier * int256(uint256(marketInfo.markPrice))) - entryValue;
            value += _pendingFunding(position, quoteMultiplier, marketInfo.fundingRatePrefixSum);
        }

        if (position.marginMode == 1) {
            value += int256(position.allocatedMargin);
        }
    }

    /// @dev Funding accrued since it was last settled for the position. Docs formula:
    ///  pendingFunding = size * quoteMultiplier * (lastFundingRatePrefixSum - fundingRatePrefixSum)
    ///  / 1e6, rounded toward negative infinity like Core. Positive = the account receives.
    function _pendingFunding(
        LighterTypes.Position memory position,
        int256 quoteMultiplier,
        int64 fundingRatePrefixSum
    ) private pure returns (int256 pendingFunding) {
        int256 fundingDelta = int256(position.lastFundingRatePrefixSum) - int256(fundingRatePrefixSum);
        int256 numerator = int256(position.size) * quoteMultiplier * fundingDelta;
        pendingFunding = numerator / 1e6;
        if (numerator < 0 && numerator % 1e6 != 0) pendingFunding -= 1;
    }

    /// @dev In-flight adjustment for the one outstanding transfer, driven by the transaction-status
    ///  read. Pending requests (status 0) are exact at every stage and for arbitrarily long Core
    ///  processing delays (downtime included — no wall-clock window). Settled requests (status != 0)
    ///  carry the async EVM-side leg exactly until it lands; because the landing is not observable
    ///  on-chain (the wallet balance is polluted by other flows), NAV-dependent flows are locked
    ///  while a settled request is outstanding (assertNavUnlocked) and the owner clears the record
    ///  via syncTransfer after off-chain verification — see docs/lighter/INTEGRATION.md
    ///  ("In-flight accounting").
    function _inFlightAdjustment(LighterData memory data) private view returns (int256) {
        int256 amount = int256(data.inFlightAmount);
        if (data.lastReqId == 0 || amount == 0) return 0;

        (uint8 status, bytes memory payload) = _readTxStatus(data.lastReqId);
        if (status == 0) {
            // Pending: Core has not processed the request yet. Deposit: the pool wallet was
            //  debited while Core shows nothing, so add the amount back. Withdrawal: neither the
            //  collateral read nor the pool wallet has moved, so no adjustment is needed.
            return amount > 0 ? amount : int256(0);
        }
        if (amount > 0) {
            // Deposit settled. acceptedAmount is credited on Core (visible in the collateral
            //  read); per the docs this write never fails. The unaccepted remainder is refunded
            //  asynchronously: until the owner attests the refund landed it sits on neither side.
            uint256 amount256 = uint256(amount);
            uint256 accepted = payload.length >= 32 ? uint256(abi.decode(payload, (uint64))) : 0;
            return accepted < amount256 ? int256(amount256 - accepted) : int256(0);
        }
        // Withdrawal settled. status 2 (rejected): Core never debited, nothing moved.
        if (status == 2) return 0;
        // Core debited the amount (the collateral read already excludes it) but the EVM delivery
        //  has not landed in the wallet yet: the amount still belongs to the pool, so the app
        //  carries it until the owner attests the delivery landed.
        return int256(uint256(-amount));
    }

    /// @notice Records a Core deposit/withdrawal for in-flight accounting. Transfers are one at a
    ///  time: the previous request must have reached a nonzero status before a new one starts, so
    ///  the tracked amount always describes exactly one request.
    function recordAction(int256 amount, uint64 reqId) internal {
        LighterData storage data = StorageLib.lighterSlot().data;
        uint64 lastReqId = data.lastReqId;
        if (lastReqId != 0) {
            require(readTxStatus(lastReqId) != 0, PendingRequest());
        }
        data.inFlightAmount = int128(amount);
        data.lastReqId = reqId;
    }

    /// @notice Clears the settled transfer record after the owner has verified off-chain that the
    ///  async EVM-side leg (refund/delivery) landed (per Lighter's docs: the delivery transaction's
    ///  receipt, found via the Core transaction's event_info). No on-chain check is possible — the
    ///  pool's USDC wallet balance cannot distinguish the leg from unrelated flows — so attestation
    ///  is owner-gated; mint/burn stay locked until then.
    function clearAction() internal {
        delete StorageLib.lighterSlot().data;
    }

    /// @notice Reverts while a settled transfer's async EVM-side leg is unconfirmed, blocking
    ///  NAV-dependent flows (mint, burn, donate, deposits) from trading on a NAV that may be off
    ///  by the in-flight amount in either direction. Pending requests never lock: the in-flight
    ///  amount values them exactly. Asserted from the LIGHTER_PERPS branch of EApps, exempt for
    ///  the updateUnitaryValue self-call (TransientStorage nav-lock-exempt flag).
    function assertNavUnlocked() internal view {
        LighterData memory data = StorageLib.lighterSlot().data;
        if (data.lastReqId == 0) return;
        require(readTxStatus(data.lastReqId) == 0, NavLocked());
    }

    /// @notice Tracks a perp market for NAV valuation, validating it against Core. No-op when
    ///  already tracked. Called by ALighter on every createOrder so the traded market is always
    ///  valued; since devnet 1.2.0 the on-chain quoteMultiplier replaces the release-time decimal
    ///  table, so any Core perp market can be tracked.
    /// @dev Reverts with InvalidMarket for non-perp markets or a zero quoteMultiplier, with
    ///  MaxTrackedMarketsReached at LighterConstants.MAX_TRACKED_MARKETS. Stale entries are pruned
    ///  by the NAV loop in getLighterBalances instead, so an order that hits a full list of stale
    ///  entries reverts until any NAV-evaluating tx (updateUnitaryValue/mint/purge — or even an
    ///  eth_call read, since the pruning is state-changing) removes them.
    function trackMarket(uint16 marketId) internal {
        LighterSlot storage slot = StorageLib.lighterSlot();
        if (slot.marketIndex[marketId] != 0) return;

        LighterTypes.MarketInfo memory marketInfo = readMarketInfo(marketId);
        require(marketInfo.marketType == 0, InvalidMarket());
        // Perps carry quoteMultiplier in [1, 10000] (docs); it is the NAV conversion factor, so
        //  a zero multiplier would silently zero every position on the market.
        require(marketInfo.quoteMultiplier != 0, InvalidMarket());

        uint16[] storage markets = slot.trackedMarkets;
        require(markets.length < LighterConstants.MAX_TRACKED_MARKETS, MaxTrackedMarketsReached());

        slot.marketIndex[marketId] = markets.length + 1;
        markets.push(marketId);
    }

    /// @dev Swap-removes a tracked market; no Core reads, no requires.
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
    }

    /// @notice True when the account controls an existing LighterCore account. The account-info
    ///  read reports found=false when the account does not exist.
    function coreAccountExists(address account) internal view returns (bool exists) {
        (exists, ) = _readCoreData(abi.encodePacked(_SELECTOR_ACCOUNT_INFO, account, false));
    }

    /// @notice Processing status of an EVM-to-Core write: 0 pending/unknown, 1 successful,
    ///  2 failed (data then holds the write-specific response). The tx-status read is the one
    ///  read without the (bool found, bytes) envelope.
    function readTxStatus(uint64 reqId) internal view returns (uint8 status) {
        (status, ) = _readTxStatus(reqId);
    }

    /// @notice Status plus response payload of an EVM-to-Core write (e.g. a deposit's
    ///  abi.encode(uint64 acceptedAmount) on success).
    function readTxStatusResult(uint64 reqId) internal view returns (uint8 status, bytes memory payload) {
        return _readTxStatus(reqId);
    }

    function _readTxStatus(uint64 reqId) private view returns (uint8 status, bytes memory payload) {
        (status, payload) = abi.decode(_readCore(abi.encodePacked(_SELECTOR_TX_STATUS, reqId)), (uint8, bytes));
    }

    function readAccountInfo(address account) internal view returns (LighterTypes.AccountInfo memory info) {
        (bool found, bytes memory data) = _readCoreData(abi.encodePacked(_SELECTOR_ACCOUNT_INFO, account, false));
        require(found, LighterReadFailed());
        info = abi.decode(data, (LighterTypes.AccountInfo));
    }

    function readMarketInfo(uint16 marketId) internal view returns (LighterTypes.MarketInfo memory info) {
        (bool found, bytes memory data) = _readCoreData(abi.encodePacked(_SELECTOR_MARKET_INFO, marketId));
        require(found, LighterReadFailed());
        info = abi.decode(data, (LighterTypes.MarketInfo));
    }

    /// @notice Reads a position; found=false (account or market absent, or no position) yields a
    ///  zeroed struct, which callers read as "no position".
    function readPosition(
        address account,
        uint16 marketId
    ) internal view returns (LighterTypes.Position memory position) {
        (bool found, bytes memory data) = _readCoreData(abi.encodePacked(_SELECTOR_POSITION, account, false, marketId));
        if (found) position = abi.decode(data, (LighterTypes.Position));
    }

    function readEvmAccountIndex(address account) internal view returns (uint48 accountIndex) {
        (bool found, bytes memory data) = _readCoreData(abi.encodePacked(_SELECTOR_EVM_ACCOUNT_INDEX, account));
        require(found, LighterReadFailed());
        accountIndex = abi.decode(data, (uint48));
    }

    /// @dev NAV variant of readMarketInfo: found=false reports failure so the position can be
    ///  valued flat instead of freezing NAV.
    function _tryReadMarketInfo(
        uint16 marketId
    ) internal view returns (bool found, LighterTypes.MarketInfo memory info) {
        bytes memory data;
        (found, data) = _readCoreData(abi.encodePacked(_SELECTOR_MARKET_INFO, marketId));
        if (found) info = abi.decode(data, (LighterTypes.MarketInfo));
    }

    /// @dev Staticcall wrapper around READ_CORE; reverts with LighterReadFailed when the
    ///  precompile rejects the query (unsupported selector, malformed input, or less than
    ///  20,000 gas forwarded, per the Lighter docs).
    function _readCore(bytes memory payload) private view returns (bytes memory ret) {
        bool success;
        (success, ret) = LighterConstants.READ_CORE.staticcall(payload);
        require(success, LighterReadFailed());
    }

    /// @dev Unwraps the documented abi.encode(bool found, bytes data) envelope every read
    ///  except tx status returns; found=false means the account, asset, or market does not
    ///  exist and data is empty.
    function _readCoreData(bytes memory payload) private view returns (bool found, bytes memory data) {
        (found, data) = abi.decode(_readCore(payload), (bool, bytes));
    }
}
