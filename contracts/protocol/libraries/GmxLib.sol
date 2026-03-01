// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

import {Price} from "gmx-synthetics/price/Price.sol";
import {Market} from "gmx-synthetics/market/Market.sol";
import {Position} from "gmx-synthetics/position/Position.sol";
import {Order} from "gmx-synthetics/order/Order.sol";
import {IGmxReader, IGmxChainlinkPriceFeedProvider, IGmxDataStore, IGmxExchangeRouter, GmxValidatedPrice, GmxPositionInfo, GmxExecutionPriceResult, GmxMarketPrices, GmxOrderInfo} from "../../utils/exchanges/gmx/IGmxSynthetics.sol";
import {AppTokenBalance} from "../types/ExternalApp.sol";

library GmxLib {
    uint256 internal constant ARBITRUM_CHAIN_ID = 42161;
    address internal constant WRAPPED_NATIVE = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    IGmxExchangeRouter internal constant GMX_ROUTER = IGmxExchangeRouter(0x1C3fa76e6E1088bCE750f23a5BFcffa1efEF6A41);

    address private constant _GMX_READER = 0x470fbC46bcC0f16532691Df360A07d8Bf5ee0789;
    address private constant _GMX_DATA_STORE = 0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8;
    address private constant _GMX_REFERRAL_STORAGE = 0xe6fab3F0c7199b0d34d7FbE83394fc0e0D06e99d;
    address private constant _GMX_CHAINLINK_PRICE_FEED = 0x38B8dB61b724b51e42A88Cb8eC564CD685a0f53B;
    uint256 private constant _MAX_GMX_POSITIONS = 32;

    // Key hashes from GMX Keys.sol / PositionStoreUtils.sol
    bytes32 private constant _KEY_FEE_BASE = keccak256(abi.encode("ESTIMATED_GAS_FEE_BASE_AMOUNT_V2_1"));
    bytes32 private constant _KEY_FEE_PER_ORACLE = keccak256(abi.encode("ESTIMATED_GAS_FEE_PER_ORACLE_PRICE"));
    // Matches PositionStoreUtils.SIZE_IN_USD — used to probe position existence via DataStore.
    bytes32 private constant _POSITION_SIZE_IN_USD_KEY = keccak256(abi.encode("SIZE_IN_USD"));
    bytes32 private constant _KEY_FEE_MULTIPLIER = keccak256(abi.encode("ESTIMATED_GAS_FEE_MULTIPLIER_FACTOR"));
    bytes32 private constant _KEY_INCREASE_ORDER_GAS = keccak256(abi.encode("INCREASE_ORDER_GAS_LIMIT"));
    bytes32 private constant _KEY_DECREASE_ORDER_GAS = keccak256(abi.encode("DECREASE_ORDER_GAS_LIMIT"));
    uint256 private constant _FLOAT_PRECISION = 1e30;

    /// @dev Oracle price count for a no-swap market order (3 = index + long + short).
    ///  From GasUtils.estimateOrderOraclePriceCount(swapsCount = 0) = 3 + 0.
    uint256 private constant _ORDER_ORACLE_PRICE_COUNT = 3;

    /// @dev Matches IAGmxV2.MaxGmxPositionsReached (same 4-byte selector).
    ///  Defined here so GmxLib.assertPositionLimitNotReached can use a custom error
    ///  without importing the adapter interface (which would create a circular dependency).
    error MaxGmxPositionsReached();

    /// @dev Reproduces GasUtils.adjustGasLimitForEstimate(dataStore, orderGasLimit, 3).
    ///  Excess fee above GMX's minimum is refunded to cancellationReceiver (the pool).
    /// @param isIncrease True for increase orders, false for decrease orders.
    function computeExecutionFee(bool isIncrease) internal view returns (uint256) {
        IGmxDataStore ds = IGmxDataStore(_GMX_DATA_STORE);
        uint256 orderGasLimit = ds.getUint(isIncrease ? _KEY_INCREASE_ORDER_GAS : _KEY_DECREASE_ORDER_GAS);
        uint256 baseGasLimit = ds.getUint(_KEY_FEE_BASE) + _ORDER_ORACLE_PRICE_COUNT * ds.getUint(_KEY_FEE_PER_ORACLE);
        uint256 multiplierFactor = ds.getUint(_KEY_FEE_MULTIPLIER);
        // Reproduces Precision.applyFactor(orderGasLimit, multiplierFactor) from GMX.
        uint256 adjustedGasLimit = baseGasLimit + (orderGasLimit * multiplierFactor) / _FLOAT_PRECISION;
        return adjustedGasLimit * tx.gasprice;
    }

    /// @notice Reverts when `account` is at the maximum open GMX positions AND the proposed
    ///  order would open a *new* position (i.e. no existing position matches the given
    ///  market + collateralToken + isLong tuple).  Increasing an existing position never
    ///  consumes a new slot, so the cap is not enforced in that case.
    ///  Lives in GmxLib so the private DataStore and Reader addresses are not duplicated in the
    ///  adapter (which has no constructor params for either).
    function assertPositionLimitNotReached(
        address account,
        address market,
        address collateralToken,
        bool isLong
    ) internal view {
        // Fast path: check whether this exact position already has size in the DataStore.
        // positionKey = keccak256(account, market, collateralToken, isLong) — Position.sol#L202.
        // sizeInUsd field is stored at keccak256(positionKey, SIZE_IN_USD) — PositionStoreUtils.sol#L53.
        // One DataStore.getUint call is far cheaper than fetching the full positions array.
        bytes32 positionKey = keccak256(abi.encode(account, market, collateralToken, isLong));
        if (IGmxDataStore(_GMX_DATA_STORE).getUint(keccak256(abi.encode(positionKey, _POSITION_SIZE_IN_USD_KEY))) > 0) {
            // Position exists — this is an increase order, no new slot is consumed.
            return;
        }

        // Slow path: new position.  We only need to know whether there are already
        // _MAX_GMX_POSITIONS open positions.  Fetching more than that is unnecessary, so cap
        // the Reader call at _MAX_GMX_POSITIONS to bound the returned array size.
        require(
            IGmxReader(_GMX_READER).getAccountPositions(_GMX_DATA_STORE, account, 0, _MAX_GMX_POSITIONS).length <
                _MAX_GMX_POSITIONS,
            MaxGmxPositionsReached()
        );
    }

    /// @notice Returns combined AppTokenBalance[] for executed positions and pending
    ///  increase orders held by `account` in GMX v2.
    /// @dev Assumes the caller has already verified the GMX_V2_POSITIONS application bit is set.
    ///  That bit is only set by AGmxV2.createIncreaseOrder, which is constructor-guarded to Arbitrum.
    ///  There is intentionally no redundant chain-id check here.
    function getGmxPositionBalances(address account) internal view returns (AppTokenBalance[] memory balances) {
        AppTokenBalance[] memory posBal = _getExecutedPositionBalances(account);
        AppTokenBalance[] memory ordBal = _getPendingOrderBalances(account);

        uint256 total = posBal.length + ordBal.length;
        if (total == 0) return balances;

        balances = new AppTokenBalance[](total);
        for (uint256 i; i < posBal.length; ++i) balances[i] = posBal[i];
        for (uint256 i; i < ordBal.length; ++i) balances[posBal.length + i] = ordBal[i];
    }

    /// @dev Returns net collateral ± PnL ± impact − fees for all open positions.
    ///  Delegates heavy lifting to helpers to stay within the 16-slot stack limit.
    function _getExecutedPositionBalances(address account) private view returns (AppTokenBalance[] memory balances) {
        // Step 1: fetch raw positions.
        Position.Props[] memory positions = IGmxReader(_GMX_READER).getAccountPositions(
            _GMX_DATA_STORE,
            account,
            0,
            type(uint256).max
        );
        if (positions.length == 0) return balances;

        // Steps 2–3: build market data and fetch PnL-enriched position structs.
        // Extracted into a helper so this function's stack stays shallow.
        (GmxPositionInfo[] memory posInfos, Market.Props[] memory marketStructs) = _fetchPositionInfos(
            positions,
            account
        );

        if (posInfos.length == 0) return _collateralOnlyBalances(positions);

        // Steps 4–5: per-position balance assembly (native-token values, no conversion).
        return _buildPositionBalances(posInfos, marketStructs);
    }

    /// @dev Converts PnL-enriched position structs into AppTokenBalance entries.
    ///  Extracted from `_getExecutedPositionBalances` to keep the caller's stack within 16 slots.
    function _buildPositionBalances(
        GmxPositionInfo[] memory posInfos,
        Market.Props[] memory marketStructs
    ) private pure returns (AppTokenBalance[] memory balances) {
        // 3 slots per position: net collateral + claimable long-token fees + claimable short-token fees.
        // All amounts are in the native token of each component — no WETH conversion.
        AppTokenBalance[] memory tmp = new AppTokenBalance[](posInfos.length * 3);
        uint256 count;
        for (uint256 i; i < posInfos.length; ++i) {
            count = _appendGmxPosBalances(tmp, count, posInfos[i], marketStructs[i]);
        }
        balances = new AppTokenBalance[](count);
        for (uint256 i; i < count; ++i) balances[i] = tmp[i];
    }

    /// @dev Builds per-position market data and fetches PnL-enriched PositionInfo structs.
    ///  Extracted from `_getExecutedPositionBalances` to keep each function's stack usage
    ///  within the 16-slot EVM limit.  Returns empty posInfos on reader revert (caller falls
    ///  back to collateral-only mode).
    function _fetchPositionInfos(
        Position.Props[] memory positions,
        address account
    ) private view returns (GmxPositionInfo[] memory posInfos, Market.Props[] memory marketStructs) {
        uint256 n = positions.length;
        address[] memory markets = new address[](n);
        marketStructs = new Market.Props[](n);
        GmxMarketPrices[] memory marketPrices = new GmxMarketPrices[](n);

        for (uint256 i; i < n; ++i) {
            address mktAddr = positions[i].addresses.market;
            markets[i] = mktAddr;
            marketStructs[i] = IGmxReader(_GMX_READER).getMarket(_GMX_DATA_STORE, mktAddr);
            marketPrices[i] = GmxMarketPrices({
                indexTokenPrice: _safeGetGmxPrice(marketStructs[i].indexToken),
                longTokenPrice: _safeGetGmxPrice(marketStructs[i].longToken),
                shortTokenPrice: _safeGetGmxPrice(marketStructs[i].shortToken)
            });
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

    /// @dev Returns the initial collateral amount for every pending MarketIncrease
    ///  or LimitIncrease order.  Converted to wrappedNative when possible.
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

        // 2 entries per order: initialCollateralDeltaAmount + executionFee (always WETH).
        AppTokenBalance[] memory tmp = new AppTokenBalance[](n * 2);
        uint256 count;

        for (uint256 i; i < n; ++i) {
            Order.OrderType ot = orders[i].order.numbers.orderType;
            // Only increase orders move collateral to the OrderVault.
            if (ot != Order.OrderType.MarketIncrease && ot != Order.OrderType.LimitIncrease) continue;

            address colToken = orders[i].order.addresses.initialCollateralToken;
            uint256 amount = orders[i].order.numbers.initialCollateralDeltaAmount;
            if (amount == 0) continue;

            // Collateral token (EOracle can price it; no WETH conversion needed).
            tmp[count++] = AppTokenBalance({token: colToken, amount: int256(amount)});

            // Execution fee: always WETH, stored separately in the order vault.
            // Counted here so NAV is not understated during the pending period.
            // GMX refunds it on cancellation; keepers consume it on execution.
            uint256 fee = orders[i].order.numbers.executionFee;
            if (fee > 0) {
                tmp[count++] = AppTokenBalance({token: WRAPPED_NATIVE, amount: int256(fee)});
            }
        }

        balances = new AppTokenBalance[](count);
        for (uint256 i; i < count; ++i) balances[i] = tmp[i];
    }

    /// @dev Appends up to 3 entries per position (net collateral, claimable long-token funding,
    ///  claimable short-token funding) to `tmp`.  Returns the updated count.
    ///  All amounts are expressed in the NATIVE TOKEN of each component.
    function _appendGmxPosBalances(
        AppTokenBalance[] memory tmp,
        uint256 count,
        GmxPositionInfo memory posInfo,
        Market.Props memory mkt
    ) private pure returns (uint256) {
        // --- net collateral (collateral ± PnL ± impact − fees) in collateralToken units ---
        address colToken = posInfo.position.addresses.collateralToken;
        int256 net = _computeGmxNetCollateral(posInfo);

        // Floor at zero — NAV cannot be inflated by this choice.
        if (net > 0) {
            tmp[count++] = AppTokenBalance({token: colToken, amount: net});
        }

        // --- claimable long-token funding fees ---
        uint256 cl = posInfo.fees.funding.claimableLongTokenAmount;
        if (cl > 0) {
            tmp[count++] = AppTokenBalance({token: mkt.longToken, amount: int256(cl)});
        }

        // --- claimable short-token funding fees ---
        uint256 cs = posInfo.fees.funding.claimableShortTokenAmount;
        if (cs > 0) {
            tmp[count++] = AppTokenBalance({token: mkt.shortToken, amount: int256(cs)});
        }

        return count;
    }

    /// @dev Computes net collateral in collateral-token units for one GMX position.
    ///  If either collateral price is zero (malformed Reader response), returns raw collateral
    ///  amount with no PnL/impact adjustment — consistent with _collateralOnlyBalances fallback.
    function _computeGmxNetCollateral(GmxPositionInfo memory posInfo) private pure returns (int256 netCollateral) {
        Price.Props memory colPrice = posInfo.fees.collateralTokenPrice;

        // Guard against division by zero if Reader returns a zeroed price struct.
        if (colPrice.min == 0 || colPrice.max == 0) {
            return int256(posInfo.position.numbers.collateralAmount);
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
            int256(posInfo.position.numbers.collateralAmount) +
            basePnlCollateral +
            impactCollateral -
            int256(posInfo.fees.totalCostAmount);
    }

    /// @dev Fallback: return raw collateral amounts when Reader.getAccountPositionInfoList fails.
    function _collateralOnlyBalances(
        Position.Props[] memory positions
    ) private pure returns (AppTokenBalance[] memory balances) {
        balances = new AppTokenBalance[](positions.length);
        for (uint256 i; i < positions.length; ++i) {
            balances[i] = AppTokenBalance({
                token: positions[i].addresses.collateralToken,
                amount: int256(positions[i].numbers.collateralAmount)
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
