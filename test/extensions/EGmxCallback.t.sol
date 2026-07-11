// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {EventUtils} from "gmx-synthetics/event/EventUtils.sol";
import {Market} from "gmx-synthetics/market/Market.sol";
import {IGmxDataStore, IGmxReader, IGmxRoleStore} from "../../contracts/utils/exchanges/gmx/IGmxSynthetics.sol";
import {GmxCallbackLib} from "../../contracts/protocol/libraries/GmxCallbackLib.sol";
import {GmxLib} from "../../contracts/protocol/libraries/GmxLib.sol";
import {EGmxCallback} from "../../contracts/protocol/extensions/EGmxCallback.sol";
import {IEGmxCallback} from "../../contracts/protocol/extensions/adapters/interfaces/IEGmxCallback.sol";

/// @title EGmxCallbackTest
/// @notice Non-fork unit tests for the GMX v2 order-execution callback extension.
contract EGmxCallbackTest is Test {
    EGmxCallback internal callback;
    address internal market;

    function setUp() public {
        vm.chainId(GmxLib.ARBITRUM_CHAIN_ID);
        callback = new EGmxCallback();
        market = makeAddr("market");
    }

    /// @notice A valid controller call records the market in callback storage.
    function test_AfterOrderExecution_ControllerCall_RecordsMarket() public {
        address longToken = makeAddr("longToken");
        address shortToken = makeAddr("shortToken");

        // Mock controller role check.
        vm.mockCall(
            GmxLib._GMX_ROLE_STORE,
            abi.encodeWithSelector(IGmxRoleStore.hasRole.selector, address(this), keccak256(abi.encode("CONTROLLER"))),
            abi.encode(true)
        );

        // Build minimal order data: account must be the callback contract, market at index 4.
        EventUtils.EventLogData memory orderData;
        orderData.addressItems.items = new EventUtils.AddressKeyValue[](5);
        orderData.addressItems.items[0].value = address(callback);
        orderData.addressItems.items[4].value = market;

        // Mock market info.
        vm.mockCall(
            GmxLib._GMX_READER,
            abi.encodeWithSelector(IGmxReader.getMarket.selector, GmxLib._GMX_DATA_STORE, market),
            abi.encode(
                Market.Props({marketToken: market, indexToken: longToken, longToken: longToken, shortToken: shortToken})
            )
        );

        // Mock time divisor so the callback can compute the time key.
        vm.mockCall(
            GmxLib._GMX_DATA_STORE,
            abi.encodeWithSelector(
                IGmxDataStore.getUint.selector,
                GmxCallbackLib.CLAIMABLE_COLLATERAL_TIME_DIVISOR_KEY
            ),
            abi.encode(uint256(1))
        );

        // No claimable collateral.
        vm.mockCall(
            GmxLib._GMX_DATA_STORE,
            abi.encodeWithSelector(IGmxDataStore.getUint.selector),
            abi.encode(uint256(0))
        );

        vm.expectEmit(true, false, false, false);
        emit IEGmxCallback.TrackedMarketAdded(market);

        callback.afterOrderExecution(
            bytes32(0),
            orderData,
            EventUtils.EventLogData({
                addressItems: EventUtils.AddressItems({
                    items: new EventUtils.AddressKeyValue[](0),
                    arrayItems: new EventUtils.AddressArrayKeyValue[](0)
                }),
                uintItems: EventUtils.UintItems({
                    items: new EventUtils.UintKeyValue[](0),
                    arrayItems: new EventUtils.UintArrayKeyValue[](0)
                }),
                intItems: EventUtils.IntItems({
                    items: new EventUtils.IntKeyValue[](0),
                    arrayItems: new EventUtils.IntArrayKeyValue[](0)
                }),
                boolItems: EventUtils.BoolItems({
                    items: new EventUtils.BoolKeyValue[](0),
                    arrayItems: new EventUtils.BoolArrayKeyValue[](0)
                }),
                bytes32Items: EventUtils.Bytes32Items({
                    items: new EventUtils.Bytes32KeyValue[](0),
                    arrayItems: new EventUtils.Bytes32ArrayKeyValue[](0)
                }),
                bytesItems: EventUtils.BytesItems({
                    items: new EventUtils.BytesKeyValue[](0),
                    arrayItems: new EventUtils.BytesArrayKeyValue[](0)
                }),
                stringItems: EventUtils.StringItems({
                    items: new EventUtils.StringKeyValue[](0),
                    arrayItems: new EventUtils.StringArrayKeyValue[](0)
                })
            })
        );
    }
}
