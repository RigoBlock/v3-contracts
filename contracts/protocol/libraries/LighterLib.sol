// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.4;

import {SafeCast} from "@openzeppelin-legacy/contracts/utils/math/SafeCast.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {StorageLib} from "../libraries/StorageLib.sol";
import {AppTokenBalance} from "../types/ExternalApp.sol";
import {LighterConstants} from "../types/LighterConstants.sol";
import {LighterSlot, LighterData} from "../types/Applications.sol";
import {LighterTypes} from "../types/LighterTypes.sol";

/// @title LighterLib
/// @notice Rigoblock-specific helpers for LighterCore perps: NAV valuation, market tracking and
///  in-flight accounting over the pool's Lighter slot.
library LighterLib {
    using SafeCast for int256;
    using SafeCast for uint256;

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

    /// @param canPrune Permission to untrack dead markets during the loop. Pruning mutates the
    ///  tracked set, so it is operator-gated by the caller: a permissionless NAV evaluation
    ///  computes the same balances but leaves the set untouched (a stale-snapshot prune would
    ///  hide a freshly opened position from NAV; an operator pruning their own market is
    ///  self-harm, out of the threat model).
    function getLighterBalances(address account, bool canPrune) internal returns (AppTokenBalance[] memory balances) {
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
                // empty markets leave the tracked set only via an operator-gated evaluation;
                //  a market kept by a permissionless evaluation still pins the app valued
                if (canPrune) {
                    _untrackMarket(slot, marketId, i - 1);
                    continue;
                }
                hasActiveMarkets = true;
                continue;
            }
            hasActiveMarkets = true;
            totalUsdcValue += _positionValueUsdc(position, marketId);
        }

        totalUsdcValue += _inFlightAdjustment(slot);

        if (totalUsdcValue == 0) {
            if (!hasActiveMarkets && !hasInFlight) return balances;
            totalUsdcValue = 1;
        }

        balances = new AppTokenBalance[](1);
        balances[0] = AppTokenBalance({token: LighterConstants.USDC, amount: totalUsdcValue});
    }

    /// @dev value (USDC base units) = size * quoteMultiplier * markPrice - signedEntryQuote,
    ///  plus pending funding and isolated margin. Unreadable market info values the position flat.
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

    /// @dev Status-driven adjustment for the one outstanding transfer. The balanceSnapshot
    ///  predates the async leg (Core schedules refund/delivery only after processing the request),
    ///  so the record clears only when the wallet has grown by at least the outstanding leg amount.
    ///  A smaller inflow (e.g. a dust donation) leaves the record intact and keeps mint/burn locked.
    function _inFlightAdjustment(LighterSlot storage lighterSlot) private returns (int256 adjustment) {
        LighterData memory data = lighterSlot.data;
        int256 amount = int256(data.inFlightAmount);
        if (data.lastReqId == 0 || amount == 0) return 0;

        (uint8 status, bytes memory payload) = _readTxStatus(data.lastReqId);
        if (status == 0) {
            // pending: a deposit left the wallet and is not on Core yet; a withdrawal has not
            //  moved either side; the leg cannot have landed
            adjustment = amount > 0 ? amount : int256(0);
        } else if (status == 1) {
            uint256 outstanding;
            if (amount > 0) {
                // deposit confirmed, possibly partially: acceptedAmount sits on Core (visible in
                //  the collateral read) and the unaccepted remainder is refunded async
                uint256 accepted = payload.length >= 32 ? uint256(abi.decode(payload, (uint64))) : 0;
                outstanding = accepted < amount.toUint256() ? amount.toUint256() - accepted : 0;
            } else {
                // withdrawal confirmed: Core debited and the delivery to the wallet is async;
                //  inFlightAmount is negative, the app carries the undelivered amount
                outstanding = (-amount).toUint256();
            }
            adjustment = outstanding.toInt256();
            if (adjustment == 0 || _readBalance() >= data.balanceSnapshot + outstanding) {
                delete lighterSlot.data;
                adjustment = 0;
            }
        } else if (status == 2) {
            // rejected on Core (deposits never fail per spec): nothing is in transit
            delete lighterSlot.data;
        }
    }

    /// @dev The pool's USDC wallet balance; the landing reference for the async leg and the
    ///  request-time snapshot source.
    function _readBalance() private view returns (uint256) {
        return IERC20(LighterConstants.USDC).balanceOf(address(this));
    }

    function recordAction(int256 amount, uint64 reqId) internal {
        // a zero amount records nothing and disturbs no existing record (only nonzero transfers
        //  are ever tracked)
        if (amount == 0) return;
        LighterData storage data = StorageLib.lighterSlot().data;
        if (data.lastReqId != 0) {
            _inFlightAdjustment(StorageLib.lighterSlot());
            require(data.lastReqId == 0, PendingRequest());
        }
        data.inFlightAmount = amount.toInt128();
        data.lastReqId = reqId;
        data.balanceSnapshot = _readBalance().toUint128();
    }

    ///  lock: they are valued exactly by the in-flight amount.
    function assertNavUnlocked() internal view {
        if (StorageLib.lighterSlot().data.lastReqId == 0) return;
        revert NavLocked();
    }

    function trackMarket(uint16 marketId) internal {
        LighterSlot storage slot = StorageLib.lighterSlot();
        if (slot.marketIndex[marketId] != 0) return;

        LighterTypes.MarketInfo memory marketInfo = readMarketInfo(marketId);
        require(marketInfo.marketType == 0, InvalidMarket());
        require(marketInfo.quoteMultiplier != 0, InvalidMarket());

        uint16[] storage markets = slot.trackedMarkets;
        require(markets.length < LighterConstants.MAX_TRACKED_MARKETS, MaxTrackedMarketsReached());

        slot.marketIndex[marketId] = markets.length + 1;
        markets.push(marketId);
    }

    function _untrackMarket(LighterSlot storage lighterSlot, uint16 marketId, uint256 listIndex) private {
        uint16[] storage markets = lighterSlot.trackedMarkets;
        uint256 lastIndex = markets.length - 1;
        uint16 lastMarket = markets[lastIndex];
        markets[listIndex] = lastMarket;
        markets.pop();
        if (lastMarket != marketId) {
            lighterSlot.marketIndex[lastMarket] = listIndex + 1;
        }
        delete lighterSlot.marketIndex[marketId];
    }

    function coreAccountExists(address account) internal view returns (bool exists) {
        (exists, ) = _readCoreData(abi.encodePacked(_SELECTOR_ACCOUNT_INFO, account, false));
    }

    /// @dev status: 0 pending, 1 successful, 2 failed (payload then abi.encode(uint32 errorCode)).
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

    function _tryReadMarketInfo(
        uint16 marketId
    ) internal view returns (bool found, LighterTypes.MarketInfo memory info) {
        bytes memory data;
        (found, data) = _readCoreData(abi.encodePacked(_SELECTOR_MARKET_INFO, marketId));
        if (found) info = abi.decode(data, (LighterTypes.MarketInfo));
    }

    function _readCore(bytes memory payload) private view returns (bytes memory ret) {
        bool success;
        (success, ret) = LighterConstants.READ_CORE.staticcall(payload);
        require(success, LighterReadFailed());
    }

    function _readCoreData(bytes memory payload) private view returns (bool found, bytes memory data) {
        (found, data) = abi.decode(_readCore(payload), (bool, bytes));
    }
}
