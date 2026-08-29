// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

import {Price} from "gmx-synthetics/price/Price.sol";
import {Market} from "gmx-synthetics/market/Market.sol";
import {Position} from "gmx-synthetics/position/Position.sol";
import {Order} from "gmx-synthetics/order/Order.sol";
import {IPriceFeed} from "gmx-synthetics/oracle/IPriceFeed.sol";
import {IGmxReader, IGmxChainlinkPriceFeedProvider, IGmxDataStore, IGmxExchangeRouter, IGmxRoleStore, GmxValidatedPrice, GmxPositionInfo, GmxExecutionPriceResult, GmxMarketPrices, GmxOrderInfo} from "../../utils/exchanges/gmx/IGmxSynthetics.sol";
import {AppTokenBalance} from "../types/ExternalApp.sol";
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
    uint256 private constant _FALLBACK_HEARTBEAT = 24 hours;

    uint256 private constant _ORDER_ORACLE_PRICE_COUNT = 3;

    error MaxGmxPositionsReached();

    struct TokenPrice {
        address token;
        Price.Props price;
    }

    /// @dev Hardcoded Chainlink fallback feeds for GMX synthetic index tokens.
    ///  Each entry is packed as `bytes32(feedAddress << 96 | exponent)` where
    ///  `multiplier = 10 ** exponent`. Returns `(address(0), 0)` for unmapped tokens.
    function _getFallbackPriceFeed(address token) private pure returns (address feed, uint256 multiplier) {
        bytes32 packed;
        uint256 nibble = uint160(token) >> 156;
        if (nibble < 3) {
            if (token == 0x0315441076FF6d3eA09814a2F90a1f980cF03e9e)
                packed = 0x46306f3795342117721d8ded50fbcf6df2b3cc10000000000000000000000022;
            if (token == 0x13674172E6E44D31d4bE489d5184f3457c40153A)
                packed = 0x8c76e8cab5ef3b410a318ddb82d83ed47d7d2701000000000000000000000028;
            if (token == 0x13983f27Ce9365055a6a553233c49fE28e70103e)
                packed = 0xcca91a477fbf466d676b2056bfdfda94f343a64f000000000000000000000022;
            if (token == 0x197aa2DE1313c7AD50184234490E12409B2a1f95)
                packed = 0x4a85b128ebdafc24d5cb611e161376ffdeceb28900000000000000000000002b;
            if (token == 0x2aAB60E62f05d17e58dEc982870bfAdc7F4e7ADF)
                packed = 0xad57d7c059e2afef2241eb6ef43559f8a409897e000000000000000000000022;
            if (token == 0x2e73bDBee83D91623736D514b0BB41f2afd9C7Fd)
                packed = 0x1b47b4124b9a5094c59710e6b9126e5e32a4fb8e000000000000000000000018;
        } else if (nibble < 7) {
            if (token == 0x3E57D02f9d196873e55727382974b02EdebE6bfd)
                packed = 0x0e278d14b4bf6429ddb0a1b353e2ae8a4e128c93000000000000000000000018;
            if (token == 0x3f8f0dCE4dCE4d0D1d0871941e79CDA82cA50d0B)
                packed = 0xdc49f292ad1bb3dab6c11363d74ed06f38b9bd9c00000000000000000000002c;
            if (token == 0x4b9a2b862E1a30e6E844c991D31Dc6387c9d65D5)
                packed = 0x26dc0763135db2ec0dc4563148ac57eb48ed0bad000000000000000000000022;
            if (token == 0x55e85A147a1029b985384822c0B2262dF8023452)
                packed = 0xcc9742d77622ee9abbf1df03530594f9097bdcb3000000000000000000000022;
            if (token == 0x67ADABbAd211eA9b3B4E2fd0FD165E593De1e983)
                packed = 0x4f861f14246229530a881d32c8d26d78b8c48be6000000000000000000000022;
            if (token == 0x6eAbbaA3278556Dc5b19c034dc26c0eaB60d65B5)
                packed = 0x21082ca28570f0ccfb089465bfaefdc77b00d367000000000000000000000018;
        } else if (nibble < 10) {
            if (token == 0x8F6cCb99d4Fd0B4095915147b5ae3bbDb8075394)
                packed = 0xfeac1a3936514746e70170c0f539e70b23d36f19000000000000000000000022;
            if (token == 0x95c317066CF214b2E6588B2685D949384504F51e)
                packed = 0x47c38c695639ae97a00f57d6d9f5ece1debb033c000000000000000000000022;
            if (token == 0x9759C297fb6C91e252c7292cECa30a509558E5De)
                packed = 0xa0c8611b0cfb31bc8ade3189ae2b982c90d9302f000000000000000000000022;
            if (token == 0x97Ce1F309B949f7FBC4f58c5cb6aa417A5ff8964)
                packed = 0x17d8d87df3e279c737568ab0c5cc3ff750ab763e000000000000000000000022;
            if (token == 0x9c060B2fA953b5f69879a8B7B81f62BFfEF360be)
                packed = 0x0c997958cce7a0403aea7e34d14bbada897b5bb3000000000000000000000018;
            if (token == 0x9c74772b713a1B032aEB173E28683D937E51921c)
                packed = 0x82ba56a2fadf9c14f17d08bc51bda0bdb83a8934000000000000000000000022;
        } else if (nibble < 13) {
            if (token == 0xB2f7cefaeEb08Aa347705ac829a7b8bE2FB560f3)
                packed = 0x0301e5d0a8f7490444ebd1921e3d0f0fe772278600000000000000000000002b;
            if (token == 0xB46A094Bc4B0adBD801E14b9DB95e05E28962764)
                packed = 0x5698690a7b7b84f6aa985ef7690a8a7288fbc9c800000000000000000000002c;
            if (token == 0xB79Eb5BA64A167676694bB41bc1640F95d309a2F)
                packed = 0xe56bea9ff0780d668f92a9ab4ace1d713caa1016000000000000000000000022;
            if (token == 0xBaf07cF91D413C0aCB2b7444B9Bf13b4e03c9D71)
                packed = 0x3a9659c071dd3c37a8b1a2363409a8d41b2feae300000000000000000000002e;
            if (token == 0xC5799ab6E2818fD8d0788dB8D156B0c5db1Bf97b)
                packed = 0x4b13dd76de990db9a2dab58d35c2c02e5e3ae848000000000000000000000022;
            if (token == 0xc5dbD52Ae5a927Cf585B884011d0C7631C9974c6)
                packed = 0x5a0a07cd0e9e4754b3fec4fb1ee1a5babbaa6051000000000000000000000023;
        } else {
            if (token == 0xE6172EecBB07F197F52bb73d74daa0e19C31c4Db)
                packed = 0x569dca98c58d7a89cee87801805a8eaaf2c72b5b000000000000000000000022;
            if (token == 0xEcc5eb985Ddbb8335b175b0A2A1144E4c978F1f6)
                packed = 0x0b2ab7ae5276f6f466f8e62953138b106dd19a63000000000000000000000022;
            if (token == 0xF67b2a901D674B443Fa9f6DB2A689B37c07fD4fE)
                packed = 0x1e48733eeee02468b674b69958b046eb6a0a7d94000000000000000000000022;
        }
        if (packed != bytes32(0)) {
            uint256 packedData = uint256(packed);
            feed = address(uint160(packedData >> 96));
            multiplier = 10 ** (packedData & type(uint96).max);
        }
    }

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

    function getPnlToken(address market, bool isLong) internal view returns (address) {
        Market.Props memory mkt = IGmxReader(_GMX_READER).getMarket(_GMX_DATA_STORE, market);
        return isLong ? mkt.longToken : mkt.shortToken;
    }

    /// @notice Returns the indexToken of a GMX market.
    function getMarketIndexToken(address market) internal view returns (address) {
        return IGmxReader(_GMX_READER).getMarket(_GMX_DATA_STORE, market).indexToken;
    }

    /// @notice Returns true if `token` can be priced by the GMX provider or by a hardcoded fallback feed.
    function isIndexTokenPriced(address token) internal view returns (bool) {
        if (token == address(0)) return false;
        try IGmxChainlinkPriceFeedProvider(_GMX_CHAINLINK_PRICE_FEED).getOraclePrice(token, "") returns (
            GmxValidatedPrice memory
        ) {
            return true;
        } catch {
            (address feed, ) = _getFallbackPriceFeed(token);
            return feed != address(0);
        }
    }

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
        price = _safeGetGmxPrice(token);
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

            uint256 longAmount = _getClaimableFundingAmount(market, mkt.longToken, account);
            if (longAmount > 0) {
                tmp[count++] = AppTokenBalance({token: mkt.longToken, amount: longAmount.toInt256()});
            }

            if (mkt.shortToken != mkt.longToken) {
                uint256 shortAmount = _getClaimableFundingAmount(market, mkt.shortToken, account);
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

    function _getClaimableFundingAmount(address market, address token, address account) private view returns (uint256) {
        return
            IGmxDataStore(_GMX_DATA_STORE).getUint(
                keccak256(abi.encode(GmxCallbackLib.CLAIMABLE_FUNDING_AMOUNT_KEY, market, token, account))
            );
    }

    function _getClaimableCollateralAmount(
        bytes32 amountKey,
        GmxCallbackLib.ClaimableCollateralInfo memory info,
        address account
    ) private view returns (uint256 claimableAmount_) {
        IGmxDataStore ds = IGmxDataStore(_GMX_DATA_STORE);
        uint256 amount = ds.getUint(amountKey);
        if (amount == 0) return 0;

        bytes32 factorTimeKey = keccak256(
            abi.encode(GmxCallbackLib.CLAIMABLE_COLLATERAL_FACTOR_KEY, info.market, info.token, info.timeKey)
        );
        bytes32 factorKey = keccak256(
            abi.encode(GmxCallbackLib.CLAIMABLE_COLLATERAL_FACTOR_KEY, info.market, info.token, info.timeKey, account)
        );
        bytes32 reductionKey = keccak256(
            abi.encode(
                GmxCallbackLib.CLAIMABLE_COLLATERAL_REDUCTION_FACTOR_KEY,
                info.market,
                info.token,
                info.timeKey,
                account
            )
        );
        bytes32 claimedKey = keccak256(
            abi.encode(GmxCallbackLib.CLAIMED_COLLATERAL_AMOUNT_KEY, info.market, info.token, info.timeKey, account)
        );

        uint256 factor = ds.getUint(factorTimeKey);
        uint256 factorForAccount = ds.getUint(factorKey);
        if (factorForAccount > factor) factor = factorForAccount;

        uint256 reduction = ds.getUint(reductionKey);
        if (factor == 0 && reduction == 0) {
            uint256 divisor = ds.getUint(GmxCallbackLib.CLAIMABLE_COLLATERAL_TIME_DIVISOR_KEY);
            uint256 maturityTime = info.timeKey * divisor;
            // If GMX changes the time divisor after the key is recorded, maturityTime can
            // move past block.timestamp. Treat it as not-yet-matured rather than reverting.
            uint256 timeDiff = block.timestamp > maturityTime ? block.timestamp - maturityTime : 0;
            if (timeDiff > ds.getUint(GmxCallbackLib.CLAIMABLE_COLLATERAL_DELAY_KEY)) {
                factor = _FLOAT_PRECISION;
            }
        }

        factor = factor > reduction ? factor - reduction : 0;

        uint256 adjusted = (amount * factor) / _FLOAT_PRECISION;
        uint256 claimed = ds.getUint(claimedKey);
        claimableAmount_ = adjusted > claimed ? adjusted - claimed : 0;
    }

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

    function hasClaimableFundingFees(address account, address market) internal view returns (bool) {
        Market.Props memory mkt = IGmxReader(_GMX_READER).getMarket(_GMX_DATA_STORE, market);
        if (_getClaimableFundingAmount(market, mkt.longToken, account) > 0) return true;
        if (mkt.shortToken != mkt.longToken && _getClaimableFundingAmount(market, mkt.shortToken, account) > 0) {
            return true;
        }
        return false;
    }

    function claimableCollateralAmount(bytes32 amountKey, address account) internal view returns (uint256) {
        GmxCallbackLib.ClaimableCollateralInfo memory info = GmxCallbackLib.gmxCallbackData().claimableCollateralInfo[
            amountKey
        ];
        if (info.token == address(0)) return 0;
        return _getClaimableCollateralAmount(amountKey, info, account);
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

        int256 basePnlCollateral = _usdToCollateral(posInfo.basePnlUsd, colPrice);
        int256 impactCollateral = _usdToCollateral(posInfo.executionPriceResult.totalImpactUsd, colPrice);

        netCollateral =
            posInfo.position.numbers.collateralAmount.toInt256() +
            basePnlCollateral +
            impactCollateral -
            posInfo.fees.totalCostAmount.toInt256();
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

    function _safeGetGmxPrice(address token) internal view returns (Price.Props memory price) {
        if (token == address(0)) return price;
        try IGmxChainlinkPriceFeedProvider(_GMX_CHAINLINK_PRICE_FEED).getOraclePrice(token, "") returns (
            GmxValidatedPrice memory validated
        ) {
            price = Price.Props({min: validated.min, max: validated.max});
        } catch {
            price = _getFallbackPrice(token);
        }
    }

    /// @dev Reads a hardcoded Chainlink fallback aggregator for tokens GMX prices via Data Streams.
    ///  The multiplier is computed as 10^60 / 10^feedDecimals / 10^tokenDecimals so that
    ///  `answer * multiplier / 1e30` yields a GMX 1e30 token-unit price.
    function _getFallbackPrice(address token) private view returns (Price.Props memory price) {
        (address feed, uint256 multiplier) = _getFallbackPriceFeed(token);
        if (feed == address(0)) return price;

        try IPriceFeed(feed).latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0) return price;
            if (updatedAt + _FALLBACK_HEARTBEAT < block.timestamp) return price;

            uint256 scaled = (uint256(answer) * multiplier) / _FLOAT_PRECISION;
            price = Price.Props({min: scaled, max: scaled});
        } catch {}
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
