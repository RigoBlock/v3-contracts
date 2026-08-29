// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

import {Price} from "gmx-synthetics/price/Price.sol";
import {Market} from "gmx-synthetics/market/Market.sol";
import {Position} from "gmx-synthetics/position/Position.sol";
import {Order} from "gmx-synthetics/order/Order.sol";
import {IGmxReader, IGmxChainlinkPriceFeedProvider, IGmxExchangeRouter, GmxPositionInfo, GmxMarketPrices, GmxOrderInfo, GmxValidatedPrice} from "../../utils/exchanges/gmx/IGmxSynthetics.sol";
import {AppTokenBalance} from "../types/ExternalApp.sol";
import {GmxClaimableHelpers} from "../types/GmxClaimableHelpers.sol";
import {GmxFallback} from "../types/GmxFallback.sol";
import {GmxConstants} from "../types/GmxConstants.sol";
import {GmxCallbackLib} from "./GmxCallbackLib.sol";
import {SafeCast} from "@openzeppelin-legacy/contracts/utils/math/SafeCast.sol";

/// @title GmxLib
/// @notice NAV-only GMX v2 helpers. Keeps the adapter surface out of the NAV
///  code path so `ENavView` / `EApps` stay as small as possible.
library GmxLib {
    using SafeCast for uint256;

    // Re-export shared GMX constants so existing consumers/tests do not break.
    uint256 internal constant ARBITRUM_CHAIN_ID = GmxConstants.ARBITRUM_CHAIN_ID;
    address internal constant WRAPPED_NATIVE = GmxConstants.WRAPPED_NATIVE;
    IGmxExchangeRouter internal constant GMX_ROUTER = GmxConstants.GMX_ROUTER;
    address internal constant _GMX_READER = GmxConstants._GMX_READER;
    address internal constant _GMX_DATA_STORE = GmxConstants._GMX_DATA_STORE;
    address internal constant _GMX_ROLE_STORE = GmxConstants._GMX_ROLE_STORE;
    address internal constant _GMX_REFERRAL_STORAGE = GmxConstants._GMX_REFERRAL_STORAGE;
    address internal constant _GMX_CHAINLINK_PRICE_FEED = GmxConstants._GMX_CHAINLINK_PRICE_FEED;
    uint256 internal constant _MAX_GMX_POSITIONS = GmxConstants._MAX_GMX_POSITIONS;
    bytes32 internal constant _KEY_FEE_BASE = GmxConstants._KEY_FEE_BASE;
    bytes32 internal constant _KEY_FEE_PER_ORACLE = GmxConstants._KEY_FEE_PER_ORACLE;
    bytes32 internal constant _POSITION_SIZE_IN_USD_KEY = GmxConstants._POSITION_SIZE_IN_USD_KEY;
    bytes32 internal constant _KEY_FEE_MULTIPLIER = GmxConstants._KEY_FEE_MULTIPLIER;
    bytes32 internal constant _KEY_INCREASE_ORDER_GAS = GmxConstants._KEY_INCREASE_ORDER_GAS;
    bytes32 internal constant _KEY_DECREASE_ORDER_GAS = GmxConstants._KEY_DECREASE_ORDER_GAS;
    uint256 internal constant _FLOAT_PRECISION = GmxConstants._FLOAT_PRECISION;
    uint256 internal constant _ORDER_ORACLE_PRICE_COUNT = GmxConstants._ORDER_ORACLE_PRICE_COUNT;

    struct TokenPrice {
        address token;
        Price.Props price;
    }

    function getGmxPositionBalances(address account) internal view returns (AppTokenBalance[] memory balances) {
        AppTokenBalance[] memory posBal = _getExecutedPositionBalances(account);
        AppTokenBalance[] memory ordBal = _getPendingOrderBalances(account);
        AppTokenBalance[] memory cbBal = _getClaimableBalances(account);

        uint256 total = posBal.length + ordBal.length + cbBal.length;
        if (total == 0) return balances;

        balances = new AppTokenBalance[](total);
        uint256 offset = _copyBalances(balances, 0, posBal);
        offset = _copyBalances(balances, offset, ordBal);
        _copyBalances(balances, offset, cbBal);
    }

    /// @notice Returns the best available GMX price for `token`.
    /// @dev Tries the GMX Chainlink price provider first, falls back to a hardcoded Chainlink aggregator.
    ///  Returns a zero Price.Props when the token cannot be priced or the fallback is stale/invalid.
    function getGmxPrice(address token) internal view returns (Price.Props memory price) {
        try IGmxChainlinkPriceFeedProvider(GmxConstants._GMX_CHAINLINK_PRICE_FEED).getOraclePrice(token, "") returns (
            GmxValidatedPrice memory validated
        ) {
            price = Price.Props({min: validated.min, max: validated.max});
        } catch {
            price = GmxFallback.getFallbackPrice(token);
        }
    }

    function _getExecutedPositionBalances(address account) private view returns (AppTokenBalance[] memory balances) {
        Position.Props[] memory positions = IGmxReader(_GMX_READER).getAccountPositions(
            _GMX_DATA_STORE,
            account,
            0,
            type(uint256).max
        );
        if (positions.length == 0) return balances;

        (GmxPositionInfo[] memory posInfos, Market.Props[] memory marketStructs) = _fetchPositionInfos(
            positions,
            account
        );

        if (posInfos.length == 0) return _collateralOnlyBalances(positions);

        return _buildPositionBalances(posInfos, marketStructs);
    }

    function _buildPositionBalances(
        GmxPositionInfo[] memory posInfos,
        Market.Props[] memory marketStructs
    ) private pure returns (AppTokenBalance[] memory balances) {
        AppTokenBalance[] memory tmp = new AppTokenBalance[](posInfos.length * 3);
        uint256 count;
        for (uint256 i; i < posInfos.length; ++i) {
            count = _appendGmxPosBalances(tmp, count, posInfos[i], marketStructs[i]);
        }
        balances = new AppTokenBalance[](count);
        for (uint256 i; i < count; ++i) {
            balances[i] = tmp[i];
        }
    }

    function _fetchPositionInfos(
        Position.Props[] memory positions,
        address account
    ) private view returns (GmxPositionInfo[] memory posInfos, Market.Props[] memory marketStructs) {
        uint256 n = positions.length;
        address[] memory markets = new address[](n);
        marketStructs = new Market.Props[](n);
        GmxMarketPrices[] memory marketPrices = new GmxMarketPrices[](n);

        TokenPrice[] memory tokenCache = new TokenPrice[](n * 3);
        uint256 tokenCacheCount;

        for (uint256 i; i < n; ++i) {
            address mktAddr = positions[i].addresses.market;
            markets[i] = mktAddr;

            uint256 seenAt = _findAddress(markets, i, mktAddr);
            marketStructs[i] = seenAt == i
                ? IGmxReader(_GMX_READER).getMarket(_GMX_DATA_STORE, mktAddr)
                : marketStructs[seenAt];

            Price.Props memory price;
            (price, tokenCacheCount) = _cachedTokenPrice(tokenCache, marketStructs[i].indexToken, tokenCacheCount);
            marketPrices[i].indexTokenPrice = price;
            (price, tokenCacheCount) = _cachedTokenPrice(tokenCache, marketStructs[i].longToken, tokenCacheCount);
            marketPrices[i].longTokenPrice = price;
            (price, tokenCacheCount) = _cachedTokenPrice(tokenCache, marketStructs[i].shortToken, tokenCacheCount);
            marketPrices[i].shortTokenPrice = price;
        }

        try
            IGmxReader(_GMX_READER).getAccountPositionInfoList(
                _GMX_DATA_STORE,
                _GMX_REFERRAL_STORAGE,
                account,
                markets,
                marketPrices,
                address(0),
                0,
                type(uint256).max
            )
        returns (GmxPositionInfo[] memory result) {
            posInfos = result;
        } catch {}
    }

    function _findAddress(address[] memory arr, uint256 count, address target) private pure returns (uint256) {
        for (uint256 i; i < count; ++i) {
            if (arr[i] == target) return i;
        }
        return count;
    }

    function _cachedTokenPrice(
        TokenPrice[] memory cache,
        address token,
        uint256 count
    ) private view returns (Price.Props memory price, uint256 newCount) {
        for (uint256 i; i < count; ++i) {
            if (cache[i].token == token) {
                return (cache[i].price, count);
            }
        }
        price = getGmxPrice(token);
        cache[count] = TokenPrice({token: token, price: price});
        newCount = count + 1;
    }

    function _getClaimableBalances(address account) private view returns (AppTokenBalance[] memory balances) {
        GmxCallbackLib.GmxCallbackSlot storage callbackData = GmxCallbackLib.gmxCallbackData();
        uint256 marketCount = GmxCallbackLib.trackedMarketsCount();
        uint256 keyCount = callbackData.claimableCollateralKeys.values.length;
        if (marketCount == 0 && keyCount == 0) return balances;

        AppTokenBalance[] memory tmp = new AppTokenBalance[](marketCount * 2 + keyCount);
        uint256 count;

        for (uint256 i; i < marketCount; ++i) {
            address market = GmxCallbackLib.trackedMarketAt(i);
            Market.Props memory mkt;
            try IGmxReader(_GMX_READER).getMarket(_GMX_DATA_STORE, market) returns (Market.Props memory result) {
                mkt = result;
            } catch {
                continue;
            }

            uint256 longAmount = GmxClaimableHelpers.getClaimableFundingAmount(market, mkt.longToken, account);
            if (longAmount > 0) {
                tmp[count++] = AppTokenBalance({token: mkt.longToken, amount: longAmount.toInt256()});
            }

            if (mkt.shortToken != mkt.longToken) {
                uint256 shortAmount = GmxClaimableHelpers.getClaimableFundingAmount(market, mkt.shortToken, account);
                if (shortAmount > 0) {
                    tmp[count++] = AppTokenBalance({token: mkt.shortToken, amount: shortAmount.toInt256()});
                }
            }
        }

        for (uint256 i; i < keyCount; ++i) {
            bytes32 key = callbackData.claimableCollateralKeys.values[i];
            GmxCallbackLib.ClaimableCollateralInfo memory info = callbackData.claimableCollateralInfo[key];
            uint256 amount = GmxClaimableHelpers.getClaimableCollateralAmount(key, info, account);
            if (amount > 0) {
                tmp[count++] = AppTokenBalance({token: info.token, amount: amount.toInt256()});
            }
        }

        balances = new AppTokenBalance[](count);
        for (uint256 i; i < count; ++i) {
            balances[i] = tmp[i];
        }
    }

    function _getPendingOrderBalances(address account) private view returns (AppTokenBalance[] memory balances) {
        GmxOrderInfo[] memory orders;
        try IGmxReader(_GMX_READER).getAccountOrders(_GMX_DATA_STORE, account, 0, type(uint256).max) returns (
            GmxOrderInfo[] memory result
        ) {
            orders = result;
        } catch {
            return balances;
        }

        uint256 n = orders.length;
        if (n == 0) return balances;

        AppTokenBalance[] memory tmp = new AppTokenBalance[](n * 2);
        uint256 count;

        for (uint256 i; i < n; ++i) {
            Order.OrderType ot = orders[i].order.numbers.orderType;
            bool isIncrease = ot == Order.OrderType.MarketIncrease || ot == Order.OrderType.LimitIncrease;

            address colToken = orders[i].order.addresses.initialCollateralToken;
            uint256 amount = orders[i].order.numbers.initialCollateralDeltaAmount;
            uint256 fee = orders[i].order.numbers.executionFee;

            if (isIncrease && amount > 0) {
                tmp[count++] = AppTokenBalance({token: colToken, amount: amount.toInt256()});
            }

            if (fee > 0) {
                tmp[count++] = AppTokenBalance({token: WRAPPED_NATIVE, amount: fee.toInt256()});
            }
        }

        balances = new AppTokenBalance[](count);
        for (uint256 i; i < count; ++i) {
            balances[i] = tmp[i];
        }
    }

    function _appendGmxPosBalances(
        AppTokenBalance[] memory tmp,
        uint256 count,
        GmxPositionInfo memory posInfo,
        Market.Props memory mkt
    ) private pure returns (uint256) {
        address colToken = posInfo.position.addresses.collateralToken;
        int256 net = _computeGmxNetCollateral(posInfo);

        if (net > 0) {
            tmp[count++] = AppTokenBalance({token: colToken, amount: net});
        }

        uint256 cl = posInfo.fees.funding.claimableLongTokenAmount;
        if (cl > 0) {
            tmp[count++] = AppTokenBalance({token: mkt.longToken, amount: cl.toInt256()});
        }

        uint256 cs = posInfo.fees.funding.claimableShortTokenAmount;
        if (cs > 0) {
            tmp[count++] = AppTokenBalance({token: mkt.shortToken, amount: cs.toInt256()});
        }

        return count;
    }

    function _computeGmxNetCollateral(GmxPositionInfo memory posInfo) private pure returns (int256 netCollateral) {
        Price.Props memory colPrice = posInfo.fees.collateralTokenPrice;

        if (colPrice.min == 0 || colPrice.max == 0) {
            return posInfo.position.numbers.collateralAmount.toInt256();
        }

        (int256 basePnlCollateral, int256 impactCollateral) = _getPnlCollaterals(posInfo, colPrice);

        netCollateral =
            posInfo.position.numbers.collateralAmount.toInt256() +
            basePnlCollateral +
            impactCollateral -
            posInfo.fees.totalCostAmount.toInt256();
    }

    /// @notice Converts both PnL components of a position from USD to collateral units.
    function _getPnlCollaterals(
        GmxPositionInfo memory posInfo,
        Price.Props memory price
    ) private pure returns (int256 basePnlCollateral, int256 impactCollateral) {
        basePnlCollateral = _usdToCollateral(posInfo.basePnlUsd, price);
        impactCollateral = _usdToCollateral(posInfo.executionPriceResult.totalImpactUsd, price);
    }

    function _usdToCollateral(int256 usd, Price.Props memory price) private pure returns (int256) {
        if (usd > 0) {
            return usd / int256(price.max);
        } else if (usd < 0) {
            return -int256(_ceilDiv(uint256(-usd), price.min));
        }
        return 0;
    }

    function _collateralOnlyBalances(
        Position.Props[] memory positions
    ) private pure returns (AppTokenBalance[] memory balances) {
        balances = new AppTokenBalance[](positions.length);
        for (uint256 i; i < positions.length; ++i) {
            balances[i] = AppTokenBalance({
                token: positions[i].addresses.collateralToken,
                amount: positions[i].numbers.collateralAmount.toInt256()
            });
        }
    }

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        return (a - 1) / b + 1;
    }

    function _copyBalances(
        AppTokenBalance[] memory dst,
        uint256 offset,
        AppTokenBalance[] memory src
    ) private pure returns (uint256) {
        for (uint256 i; i < src.length; ++i) {
            dst[offset + i] = src[i];
        }
        return offset + src.length;
    }
}
