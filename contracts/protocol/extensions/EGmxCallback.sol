// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {ARBITRUM_CHAIN_ID, _GMX_READER, _GMX_DATA_STORE, _GMX_ROLE_STORE, _GMX_CONTROLLER_ROLE} from "../types/GmxConstants.sol";

import {EventUtils} from "gmx-synthetics/event/EventUtils.sol";
import {Market} from "gmx-synthetics/market/Market.sol";
import {Reader} from "gmx-synthetics/reader/Reader.sol";
import {RoleStore} from "gmx-synthetics/role/RoleStore.sol";
import {DataStore} from "gmx-synthetics/data/DataStore.sol";
import {Bytes32Set, EnumerableSet} from "../libraries/EnumerableSet.sol";
import {GmxCallbackLib} from "../libraries/GmxCallbackLib.sol";
import {IEGmxCallback} from "./adapters/interfaces/IEGmxCallback.sol";

/// @title EGmxCallback
/// @notice GMX v2 order-execution callback extension. Records claimable collateral
///  rebates and tracked markets in pool storage so NAV remains accurate after full
///  closes, liquidations, and ADL.
/// @dev Runs as an extension (always delegatecalled). Only GMX controller contracts
///  may invoke the callback handler.
contract EGmxCallback is IEGmxCallback {
    using EnumerableSet for Bytes32Set;

    error NotGmxController();
    error InvalidCallbackAccount();
    error NotArbitrum();

    constructor() {
        require(block.chainid == ARBITRUM_CHAIN_ID, NotArbitrum());
    }

    modifier onlyGmxController() {
        require(RoleStore(_GMX_ROLE_STORE).hasRole(msg.sender, _GMX_CONTROLLER_ROLE), NotGmxController());
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
        if (!GmxCallbackLib.containsTrackedMarket(market)) {
            GmxCallbackLib.addTrackedMarket(market);
            emit IEGmxCallback.TrackedMarketAdded(market);
        }

        // Record claimable collateral keys for both market tokens. Price-impact rebates
        // are time-locked, so we only store the key for later NAV/claiming.
        uint256 timeKey = block.timestamp /
            DataStore(_GMX_DATA_STORE).getUint(GmxCallbackLib.CLAIMABLE_COLLATERAL_TIME_DIVISOR_KEY);
        Market.Props memory marketInfo = Reader(_GMX_READER).getMarket(DataStore(_GMX_DATA_STORE), market);

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
            abi.encode(GmxCallbackLib.CLAIMABLE_COLLATERAL_AMOUNT_KEY, market, token, timeKey, address(this))
        );

        // Only store keys that actually have claimable collateral and are not already tracked.
        if (
            DataStore(_GMX_DATA_STORE).getUint(amountKey) != 0 &&
            !callbackData.claimableCollateralKeys.contains(amountKey)
        ) {
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
