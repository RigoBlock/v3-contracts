// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

import {_GMX_READER, _GMX_DATA_STORE, _GMX_CHAINLINK_PRICE_FEED, _MAX_GMX_POSITIONS, _KEY_FEE_BASE, _KEY_FEE_PER_ORACLE, _POSITION_SIZE_IN_USD_KEY, _KEY_FEE_MULTIPLIER, _KEY_INCREASE_ORDER_GAS, _KEY_DECREASE_ORDER_GAS, _FLOAT_PRECISION, _ORDER_ORACLE_PRICE_COUNT} from "../types/GmxConstants.sol";

import {Market} from "gmx-synthetics/market/Market.sol";
import {Position} from "gmx-synthetics/position/Position.sol";
import {IGmxReader, IGmxChainlinkPriceFeedProvider, IGmxDataStore, GmxValidatedPrice} from "../../utils/exchanges/gmx/IGmxSynthetics.sol";
import {GmxCallbackLib} from "./GmxCallbackLib.sol";
import {GmxClaimableHelpers} from "../types/GmxClaimableHelpers.sol";
import {GmxFallback} from "../types/GmxFallback.sol";

library GmxAdapterLib {
    error MaxGmxPositionsReached();

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

    function getMarketIndexToken(address market) internal view returns (address) {
        return IGmxReader(_GMX_READER).getMarket(_GMX_DATA_STORE, market).indexToken;
    }

    function isIndexTokenPriced(address token) internal view returns (bool) {
        if (token == address(0)) return false;
        try IGmxChainlinkPriceFeedProvider(_GMX_CHAINLINK_PRICE_FEED).getOraclePrice(token, "") returns (
            GmxValidatedPrice memory
        ) {
            return true;
        } catch {
            return GmxFallback.getFallbackPrice(token).min > 0;
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
        if (GmxClaimableHelpers.getClaimableFundingAmount(market, mkt.longToken, account) > 0) return true;
        if (
            mkt.shortToken != mkt.longToken &&
            GmxClaimableHelpers.getClaimableFundingAmount(market, mkt.shortToken, account) > 0
        ) {
            return true;
        }
        return false;
    }

    function claimableCollateralAmount(bytes32 amountKey, address account) internal view returns (uint256) {
        GmxCallbackLib.ClaimableCollateralInfo memory info = GmxCallbackLib.gmxCallbackData().claimableCollateralInfo[
            amountKey
        ];
        if (info.token == address(0)) return 0;
        return GmxClaimableHelpers.getClaimableCollateralAmount(amountKey, info, account);
    }
}
