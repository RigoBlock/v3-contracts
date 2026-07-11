// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {EventUtils} from "gmx-synthetics/event/EventUtils.sol";
import {Market} from "gmx-synthetics/market/Market.sol";
import {IGmxDataStore, IGmxReader, IGmxRoleStore} from "../../utils/exchanges/gmx/IGmxSynthetics.sol";
import {AddressSet, Bytes32Set, EnumerableSet} from "../libraries/EnumerableSet.sol";
import {GmxCallbackKeys} from "../libraries/GmxCallbackKeys.sol";
import {GmxCallbackLib} from "../libraries/GmxCallbackLib.sol";
import {GmxLib} from "../libraries/GmxLib.sol";
import {IEGmxCallback} from "./adapters/interfaces/IEGmxCallback.sol";

/// @title EGmxCallback
/// @notice GMX v2 order-execution callback extension. Records claimable collateral
///  rebates and tracked markets in pool storage so NAV remains accurate after full
///  closes, liquidations, and ADL.
/// @dev Runs as an extension (always delegatecalled). Only GMX controller contracts
///  may invoke the callback handler.
contract EGmxCallback is IEGmxCallback {
    using EnumerableSet for AddressSet;
    using EnumerableSet for Bytes32Set;

    bytes32 private constant _CONTROLLER_ROLE_STORE_KEY = keccak256(abi.encode("CONTROLLER"));

    error NotGmxController();
    error InvalidCallbackAccount();
    error NotArbitrum();

    constructor() {
        require(block.chainid == GmxLib.ARBITRUM_CHAIN_ID, NotArbitrum());
    }

    modifier onlyGmxController() {
        require(
            IGmxRoleStore(GmxLib._GMX_ROLE_STORE).hasRole(msg.sender, _CONTROLLER_ROLE_STORE_KEY),
            NotGmxController()
        );
        _;
    }

    /// @inheritdoc IEGmxCallback
    function afterOrderExecution(
        bytes32,
        EventUtils.EventLogData memory orderData,
        EventUtils.EventLogData memory
    ) external override onlyGmxController {
        // OrderEventUtils.createEventData() writes address items in this order:
        // 0=account, 1=receiver, 2=callbackContract, 3=uiFeeReceiver, 4=market, 5=initialCollateralToken
        address account = orderData.addressItems.items[0].value;
        address market = orderData.addressItems.items[4].value;

        require(account == address(this), InvalidCallbackAccount());

        GmxCallbackLib.GmxCallbackSlot storage callbackData = GmxCallbackLib.gmxCallbackData();

        // Track the market so NAV can query claimable funding fees even after the
        // position is closed/liquidated and no open positions remain.
        if (!callbackData.trackedMarkets.contains(market)) {
            callbackData.trackedMarkets.add(market);
            emit IEGmxCallback.TrackedMarketAdded(market);
        }

        // Record claimable collateral keys for both market tokens. Price-impact rebates
        // are time-locked, so we only store the key for later NAV/claiming.
        uint256 timeKey = block.timestamp /
            IGmxDataStore(GmxLib._GMX_DATA_STORE).getUint(GmxCallbackKeys.CLAIMABLE_COLLATERAL_TIME_DIVISOR_KEY);
        Market.Props memory marketInfo = IGmxReader(GmxLib._GMX_READER).getMarket(GmxLib._GMX_DATA_STORE, market);

        _recordClaimableCollateral(callbackData, market, marketInfo.longToken, timeKey);
        if (marketInfo.longToken != marketInfo.shortToken) {
            _recordClaimableCollateral(callbackData, market, marketInfo.shortToken, timeKey);
        }
    }

    /// @dev Records a claimable-collateral key if the pool has a non-zero claimable balance.
    function _recordClaimableCollateral(
        GmxCallbackLib.GmxCallbackSlot storage callbackData,
        address market,
        address token,
        uint256 timeKey
    ) private {
        bytes32 amountKey = keccak256(
            abi.encode(GmxCallbackKeys.CLAIMABLE_COLLATERAL_AMOUNT_KEY, market, token, timeKey, address(this))
        );

        // Only store keys that actually have claimable collateral.
        if (IGmxDataStore(GmxLib._GMX_DATA_STORE).getUint(amountKey) == 0) {
            return;
        }

        if (!callbackData.claimableCollateralKeys.contains(amountKey)) {
            callbackData.claimableCollateralKeys.add(amountKey);
            callbackData.claimableCollateralInfo[amountKey] = GmxCallbackLib.ClaimableCollateralInfo({
                token: token,
                market: market,
                timeKey: timeKey
            });
            emit IEGmxCallback.ClaimableCollateralAdded(amountKey, token, market, timeKey);
        }
    }
}
