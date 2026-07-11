// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

import {Price} from "gmx-synthetics/price/Price.sol";
import {Market} from "gmx-synthetics/market/Market.sol";
import {Position} from "gmx-synthetics/position/Position.sol";
import {Order} from "gmx-synthetics/order/Order.sol";
import {IGmxReader, IGmxChainlinkPriceFeedProvider, IGmxDataStore, IGmxExchangeRouter, IGmxRoleStore, GmxValidatedPrice, GmxPositionInfo, GmxExecutionPriceResult, GmxMarketPrices, GmxOrderInfo} from "../../utils/exchanges/gmx/IGmxSynthetics.sol";
import {AppTokenBalance} from "../types/ExternalApp.sol";
import {GmxCallbackKeys} from "./GmxCallbackKeys.sol";
import {GmxCallbackLib} from "./GmxCallbackLib.sol";
import {SafeCast} from "@openzeppelin-legacy/contracts/utils/math/SafeCast.sol";

library GmxLib {
    using SafeCast for uint256;
    uint256 internal constant ARBITRUM_CHAIN_ID = 42161;
    address internal constant WRAPPED_NATIVE = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    IGmxExchangeRouter internal constant GMX_ROUTER = IGmxExchangeRouter(0x1C3fa76e6E1088bCE750f23a5BFcffa1efEF6A41);

    address internal constant _GMX_READER = 0x470fbC46bcC0f16532691Df360A07d8Bf5ee0789;
    address internal constant _GMX_DATA_STORE = 0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8;
    address internal constant _GMX_ROLE_STORE = 0x3c3d99FD298f679DBC2CEcd132b4eC4d0F5e6e72;
    address private constant _GMX_REFERRAL_STORAGE = 0xe6fab3F0c7199b0d34d7FbE83394fc0e0D06e99d;
    address private constant _GMX_CHAINLINK_PRICE_FEED = 0x38B8dB61b724b51e42A88Cb8eC564CD685a0f53B;
    uint256 private constant _MAX_GMX_POSITIONS = 32;

    bytes32 private constant _KEY_FEE_BASE = keccak256(abi.encode("ESTIMATED_GAS_FEE_BASE_AMOUNT_V2_1"));
    bytes32 private constant _KEY_FEE_PER_ORACLE = keccak256(abi.encode("ESTIMATED_GAS_FEE_PER_ORACLE_PRICE"));
    bytes32 private constant _POSITION_SIZE_IN_USD_KEY = keccak256(abi.encode("SIZE_IN_USD"));
    bytes32 private constant _KEY_FEE_MULTIPLIER = keccak256(abi.encode("ESTIMATED_GAS_FEE_MULTIPLIER_FACTOR"));
    bytes32 private constant _KEY_INCREASE_ORDER_GAS = keccak256(abi.encode("INCREASE_ORDER_GAS_LIMIT"));
    bytes32 private constant _KEY_DECREASE_ORDER_GAS = keccak256(abi.encode("DECREASE_ORDER_GAS_LIMIT"));
    uint256 private constant _FLOAT_PRECISION = 1e30;

    uint256 private constant _ORDER_ORACLE_PRICE_COUNT = 3;

    error MaxGmxPositionsReached();

    /// @dev Mirrors GMX GasUtils.adjustGasLimitForEstimate; fee = adjustedGasLimit * tx.gasprice.
    function computeExecutionFee(bool isIncrease, uint256 callbackGasLimit) internal view returns (uint256) {
        IGmxDataStore ds = IGmxDataStore(_GMX_DATA_STORE);
        uint256 orderGasLimit = ds.getUint(isIncrease ? _KEY_INCREASE_ORDER_GAS : _KEY_DECREASE_ORDER_GAS);
        uint256 baseGasLimit = ds.getUint(_KEY_FEE_BASE) + _ORDER_ORACLE_PRICE_COUNT * ds.getUint(_KEY_FEE_PER_ORACLE);
        uint256 multiplierFactor = ds.getUint(_KEY_FEE_MULTIPLIER);
        uint256 adjustedGasLimit = baseGasLimit +
            ((orderGasLimit + callbackGasLimit) * multiplierFactor) /
            _FLOAT_PRECISION;
        return adjustedGasLimit * tx.gasprice;
    }

    /// @dev Returns the market token in which GMX settles PnL for a direction.
    function getPnlToken(address market, bool isLong) internal view returns (address) {
        Market.Props memory mkt = IGmxReader(_GMX_READER).getMarket(_GMX_DATA_STORE, market);
        return isLong ? mkt.longToken : mkt.shortToken;
    }

    /// @dev Reverts if `account` already has `_MAX_GMX_POSITIONS` open and the order would
    ///  create a new (market, collateralToken, isLong) tuple. Existing positions are ignored.
    function assertPositionLimitNotReached(
        address account,
        address market,
        address collateralToken,
        bool isLong
    ) internal view {
        bytes32 positionKey = keccak256(abi.encode(account, market, collateralToken, isLong));
        if (IGmxDataStore(_GMX_DATA_STORE).getUint(keccak256(abi.encode(positionKey, _POSITION_SIZE_IN_USD_KEY))) > 0) {
            return;
        }

        require(
            IGmxReader(_GMX_READER).getAccountPositions(_GMX_DATA_STORE, account, 0, _MAX_GMX_POSITIONS).length <
                _MAX_GMX_POSITIONS,
            MaxGmxPositionsReached()
        );
    }

    /// @dev Returns executed positions, pending orders, and callback-recorded claimables.
    function getGmxPositionBalances(address account) internal view returns (AppTokenBalance[] memory balances) {
        AppTokenBalance[] memory posBal = _getExecutedPositionBalances(account);
        AppTokenBalance[] memory ordBal = _getPendingOrderBalances(account);
        AppTokenBalance[] memory cbBal = _getCallbackBalances(account);

        uint256 total = posBal.length + ordBal.length + cbBal.length;
        if (total == 0) return balances;

        balances = new AppTokenBalance[](total);
        for (uint256 i; i < posBal.length; ++i) {
            balances[i] = posBal[i];
        }
        for (uint256 i; i < ordBal.length; ++i) {
            balances[posBal.length + i] = ordBal[i];
        }
        for (uint256 i; i < cbBal.length; ++i) {
            balances[posBal.length + ordBal.length + i] = cbBal[i];
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

    /// @dev In-memory token price cache used by `_fetchPositionInfos`.
    struct TokenPrice {
        address token;
        Price.Props price;
    }

    /// @dev Fetches markets and prices, deduplicated across positions. Returns empty on revert
    ///  so the caller can fall back to collateral-only balances.
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
            if (seenAt == i) {
                marketStructs[i] = IGmxReader(_GMX_READER).getMarket(_GMX_DATA_STORE, mktAddr);
            } else {
                marketStructs[i] = marketStructs[seenAt];
            }

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
        } catch {
            // Return empty — caller falls back to collateral-only balances.
        }
    }

    /// @dev Returns the index of `target` in `arr[0..count)`, or `count` if not found.
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
        price = _safeGetGmxPrice(token);
        cache[count] = TokenPrice({token: token, price: price});
        newCount = count + 1;
    }

    /// @dev Returns funding fees and collateral rebates recorded by EGmxCallback.
    function _getCallbackBalances(address account) private view returns (AppTokenBalance[] memory balances) {
        GmxCallbackLib.GmxCallbackSlot storage callbackData = GmxCallbackLib.gmxCallbackData();
        uint256 marketCount = callbackData.trackedMarkets.addresses.length;
        uint256 keyCount = callbackData.claimableCollateralKeys.values.length;
        if (marketCount == 0 && keyCount == 0) return balances;

        AppTokenBalance[] memory tmp = new AppTokenBalance[](marketCount * 2 + keyCount);
        uint256 count;

        for (uint256 i; i < marketCount; ++i) {
            address market = callbackData.trackedMarkets.addresses[i];
            Market.Props memory mkt;
            try IGmxReader(_GMX_READER).getMarket(_GMX_DATA_STORE, market) returns (Market.Props memory result) {
                mkt = result;
            } catch {
                continue;
            }

            uint256 longAmount = _claimableFundingAmount(market, mkt.longToken, account);
            if (longAmount > 0) {
                tmp[count++] = AppTokenBalance({token: mkt.longToken, amount: longAmount.toInt256()});
            }

            if (mkt.shortToken != mkt.longToken) {
                uint256 shortAmount = _claimableFundingAmount(market, mkt.shortToken, account);
                if (shortAmount > 0) {
                    tmp[count++] = AppTokenBalance({token: mkt.shortToken, amount: shortAmount.toInt256()});
                }
            }
        }

        for (uint256 i; i < keyCount; ++i) {
            bytes32 key = callbackData.claimableCollateralKeys.values[i];
            GmxCallbackLib.ClaimableCollateralInfo memory info = callbackData.claimableCollateralInfo[key];
            uint256 amount = _getClaimableCollateralAmount(key, info, account);
            if (amount > 0) {
                tmp[count++] = AppTokenBalance({token: info.token, amount: amount.toInt256()});
            }
        }

        balances = new AppTokenBalance[](count);
        for (uint256 i; i < count; ++i) {
            balances[i] = tmp[i];
        }
    }

    function _claimableFundingAmount(address market, address token, address account) private view returns (uint256) {
        return
            IGmxDataStore(_GMX_DATA_STORE).getUint(
                keccak256(abi.encode(GmxCallbackKeys.CLAIMABLE_FUNDING_AMOUNT_KEY, market, token, account))
            );
    }

    /// @dev Computes the currently claimable collateral rebate for a recorded key.
    function _getClaimableCollateralAmount(
        bytes32 amountKey,
        GmxCallbackLib.ClaimableCollateralInfo memory info,
        address account
    ) private view returns (uint256 claimableAmount_) {
        uint256 amount = IGmxDataStore(_GMX_DATA_STORE).getUint(amountKey);
        if (amount == 0) return 0;

        bytes32 factorTimeKey = keccak256(
            abi.encode(GmxCallbackKeys.CLAIMABLE_COLLATERAL_FACTOR_KEY, info.market, info.token, info.timeKey)
        );
        bytes32 factorKey = keccak256(
            abi.encode(GmxCallbackKeys.CLAIMABLE_COLLATERAL_FACTOR_KEY, info.market, info.token, info.timeKey, account)
        );
        bytes32 reductionKey = keccak256(
            abi.encode(
                GmxCallbackKeys.CLAIMABLE_COLLATERAL_REDUCTION_FACTOR_KEY,
                info.market,
                info.token,
                info.timeKey,
                account
            )
        );
        bytes32 claimedKey = keccak256(
            abi.encode(GmxCallbackKeys.CLAIMED_COLLATERAL_AMOUNT_KEY, info.market, info.token, info.timeKey, account)
        );

        uint256 factor = IGmxDataStore(_GMX_DATA_STORE).getUint(factorTimeKey);
        uint256 factorForAccount = IGmxDataStore(_GMX_DATA_STORE).getUint(factorKey);
        if (factorForAccount > factor) factor = factorForAccount;

        uint256 reduction = IGmxDataStore(_GMX_DATA_STORE).getUint(reductionKey);
        if (factor == 0 && reduction == 0) {
            uint256 timeDiff = block.timestamp -
                info.timeKey *
                IGmxDataStore(_GMX_DATA_STORE).getUint(GmxCallbackKeys.CLAIMABLE_COLLATERAL_TIME_DIVISOR_KEY);
            if (timeDiff > IGmxDataStore(_GMX_DATA_STORE).getUint(GmxCallbackKeys.CLAIMABLE_COLLATERAL_DELAY_KEY)) {
                factor = _FLOAT_PRECISION;
            }
        }

        if (factor > reduction) {
            factor -= reduction;
        } else {
            factor = 0;
        }

        uint256 adjusted = (amount * factor) / _FLOAT_PRECISION;
        uint256 claimed = IGmxDataStore(_GMX_DATA_STORE).getUint(claimedKey);
        claimableAmount_ = adjusted > claimed ? adjusted - claimed : 0;
    }

    /// @notice Returns true when `account` still has an open position on `market`.
    function isMarketActive(address account, address market) internal view returns (bool) {
        Position.Props[] memory positions = IGmxReader(_GMX_READER).getAccountPositions(
            _GMX_DATA_STORE,
            account,
            0,
            type(uint256).max
        );
        for (uint256 i; i < positions.length; ++i) {
            if (positions[i].addresses.market == market) return true;
        }
        return false;
    }

    /// @notice Returns true when `account` has any unclaimed funding fees on `market`.
    function hasClaimableFundingFees(address account, address market) internal view returns (bool) {
        Market.Props memory mkt = IGmxReader(_GMX_READER).getMarket(_GMX_DATA_STORE, market);
        if (_claimableFundingAmount(market, mkt.longToken, account) > 0) return true;
        if (mkt.shortToken != mkt.longToken && _claimableFundingAmount(market, mkt.shortToken, account) > 0) {
            return true;
        }
        return false;
    }

    /// @notice Computes the currently-claimable collateral amount for a recorded key.
    function claimableCollateralAmount(bytes32 amountKey, address account) internal view returns (uint256) {
        GmxCallbackLib.ClaimableCollateralInfo memory info = GmxCallbackLib.gmxCallbackData().claimableCollateralInfo[
            amountKey
        ];
        if (info.token == address(0)) return 0;
        return _getClaimableCollateralAmount(amountKey, info, account);
    }

    /// @dev Returns assets held in GMX's OrderVault for pending orders.
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

            // Increase orders escrow collateral; decrease-order collateral stays in the position.
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

    /// @dev Appends net collateral and claimable funding fees for one position.
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

    /// @dev Computes net collateral in collateral-token units. Falls back to raw collateral
    ///  if the Reader returns zero prices.
    function _computeGmxNetCollateral(GmxPositionInfo memory posInfo) private pure returns (int256 netCollateral) {
        Price.Props memory colPrice = posInfo.fees.collateralTokenPrice;

        if (colPrice.min == 0 || colPrice.max == 0) {
            return posInfo.position.numbers.collateralAmount.toInt256();
        }

        int256 basePnlCollateral;
        if (posInfo.basePnlUsd > 0) {
            basePnlCollateral = posInfo.basePnlUsd / int256(colPrice.max);
        } else if (posInfo.basePnlUsd < 0) {
            basePnlCollateral = -int256(_ceilDiv(uint256(-posInfo.basePnlUsd), colPrice.min));
        }

        int256 impactCollateral;
        if (posInfo.executionPriceResult.totalImpactUsd > 0) {
            impactCollateral = posInfo.executionPriceResult.totalImpactUsd / int256(colPrice.max);
        } else if (posInfo.executionPriceResult.totalImpactUsd < 0) {
            impactCollateral = -int256(_ceilDiv(uint256(-posInfo.executionPriceResult.totalImpactUsd), colPrice.min));
        }

        netCollateral =
            posInfo.position.numbers.collateralAmount.toInt256() +
            basePnlCollateral +
            impactCollateral -
            posInfo.fees.totalCostAmount.toInt256();
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

    function _safeGetGmxPrice(address token) private view returns (Price.Props memory price) {
        if (token == address(0)) return price;
        try IGmxChainlinkPriceFeedProvider(_GMX_CHAINLINK_PRICE_FEED).getOraclePrice(token, "") returns (
            GmxValidatedPrice memory validated
        ) {
            price = Price.Props({min: validated.min, max: validated.max});
        } catch {}
    }

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        return (a - 1) / b + 1;
    }
}
