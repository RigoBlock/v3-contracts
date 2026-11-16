// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.4;

import {IERC20} from "../interfaces/IERC20.sol";
import {StorageLib} from "../libraries/StorageLib.sol";
import {AppTokenBalance} from "../types/ExternalApp.sol";
import {LighterConstants} from "../types/LighterConstants.sol";
import {LighterSlot, LighterData} from "../types/Applications.sol";
import {LighterTypes} from "../extensions/adapters/interfaces/lighter/LighterTypes.sol";

/// @title LighterLib
/// @notice Rigoblock-specific helpers for LighterCore perps: NAV valuation, market tracking and
///  in-flight accounting over the pool's Lighter slot.
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

    /// @dev Status-driven adjustment for the one outstanding transfer. Pending requests are valued
    ///  exactly and never lock. A settled request pins the pool's USDC wallet balance at its first
    ///  observation and carries the async EVM-side leg (deposit refund / withdrawal delivery) until
    ///  the wallet increases; while the leg is in transit mint/burn are locked (assertNavUnlocked),
    ///  so the increase is attributable to the leg itself. A landed or empty leg clears the record.
    function _inFlightAdjustment(LighterSlot storage lighterSlot) private returns (int256) {
        LighterData memory data = lighterSlot.data;
        int256 amount = int256(data.inFlightAmount);
        if (data.lastReqId == 0 || amount == 0) return 0;

        (uint8 status, bytes memory payload) = _readTxStatus(data.lastReqId);
        if (status == 0) {
            // pending: the deposit amount left the wallet and is not on Core yet; a withdrawal has
            //  moved neither side
            return amount > 0 ? amount : int256(0);
        } else {
            if (data.walletBaselineUsdc == 0) {
                lighterSlot.data.walletBaselineUsdc = uint128(IERC20(LighterConstants.USDC).balanceOf(address(this)));
                data.walletBaselineUsdc = lighterSlot.data.walletBaselineUsdc;
            }
            if (status == 1) {
                if (amount > 0) {
                    // deposit accepted, possibly partially: acceptedAmount is on Core and the
                    //  unaccepted remainder is refunded async
                    uint256 amount256 = uint256(amount);
                    uint256 accepted = payload.length >= 32 ? uint256(abi.decode(payload, (uint64))) : 0;
                    uint256 outstanding = accepted < amount256 ? amount256 - accepted : 0;
                    if (outstanding == 0 || _legLanded(data.walletBaselineUsdc)) {
                        delete lighterSlot.data;
                        return 0;
                    }
                    return int256(outstanding);
                } else {
                    // withdrawal accepted: Core debited and the delivery to the wallet is async
                    if (_legLanded(data.walletBaselineUsdc)) {
                        delete lighterSlot.data;
                        return 0;
                    }
                    return int256(uint256(-amount));
                }
            } else if (status == 2) {
                // rejected on Core (deposits never fail per spec): nothing is in transit
                delete lighterSlot.data;
                return 0;
            } else {
                // unknown future status: conservatively carry the amount and stay locked
                return amount > 0 ? amount : int256(0);
            }
        }
    }

    /// @dev True once the wallet increased over the pinned baseline. EVM-initiated transfers carry
    ///  no fee, and the settled lock blocks every other flow, so any increase is the async leg.
    function _legLanded(uint128 baseline) private view returns (bool) {
        return IERC20(LighterConstants.USDC).balanceOf(address(this)) > baseline;
    }

    function recordAction(int256 amount, uint64 reqId) internal {
        LighterData storage data = StorageLib.lighterSlot().data;
        uint64 lastReqId = data.lastReqId;
        if (lastReqId != 0) {
            uint8 status = readTxStatus(lastReqId);
            if (status == 0) revert PendingRequest();
        }
        data.inFlightAmount = int128(amount);
        data.lastReqId = reqId;
        data.walletBaselineUsdc = 0;
    }

    ///  lock: they are valued exactly by the in-flight amount.
    function assertNavUnlocked() internal view {
        LighterData memory data = StorageLib.lighterSlot().data;
        if (data.lastReqId == 0) return;
        uint8 status = readTxStatus(data.lastReqId);
        if (status == 0) return;
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

    /// @notice status: 0 pending, 1 successful, 2 failed (payload then abi.encode(uint32 errorCode)).
    function readTxStatus(uint64 reqId) internal view returns (uint8 status) {
        (status, ) = _readTxStatus(reqId);
    }

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
