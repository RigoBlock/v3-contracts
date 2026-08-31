// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {ARBITRUM_CHAIN_ID, _GMX_READER, _GMX_DATA_STORE, _GMX_ROLE_STORE} from "../../contracts/protocol/types/GmxConstants.sol";

import {Test} from "forge-std/Test.sol";
import {EventUtils} from "gmx-synthetics/event/EventUtils.sol";
import {Market} from "gmx-synthetics/market/Market.sol";
import {Order} from "gmx-synthetics/order/Order.sol";
import {OrderEventUtils} from "gmx-synthetics/order/OrderEventUtils.sol";
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
        vm.chainId(ARBITRUM_CHAIN_ID);
        callback = new EGmxCallback();
        market = makeAddr("market");
    }

    /// @notice A valid controller call records the market in callback storage.
    function test_AfterOrderExecution_ControllerCall_RecordsMarket() public {
        address longToken = makeAddr("longToken");
        address shortToken = makeAddr("shortToken");

        // Mock controller role check.
        vm.mockCall(
            _GMX_ROLE_STORE,
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
            _GMX_READER,
            abi.encodeWithSelector(IGmxReader.getMarket.selector, _GMX_DATA_STORE, market),
            abi.encode(
                Market.Props({marketToken: market, indexToken: longToken, longToken: longToken, shortToken: shortToken})
            )
        );

        // Mock time divisor so the callback can compute the time key.
        vm.mockCall(
            _GMX_DATA_STORE,
            abi.encodeWithSelector(
                IGmxDataStore.getUint.selector,
                GmxCallbackLib.CLAIMABLE_COLLATERAL_TIME_DIVISOR_KEY
            ),
            abi.encode(uint256(1))
        );

        // No claimable collateral.
        vm.mockCall(_GMX_DATA_STORE, abi.encodeWithSelector(IGmxDataStore.getUint.selector), abi.encode(uint256(0)));

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

    /// @notice A non-zero claimable collateral amount causes the callback to record the
    ///  (market, token, timeKey) key and emit ClaimableCollateralAdded.
    function test_AfterOrderExecution_RecordsClaimableCollateralKey() public {
        _mockController();
        address token = makeAddr("token");
        _mockMarketInfo(market, token, token);
        _mockTimeDivisor(1);

        vm.mockCall(
            _GMX_DATA_STORE,
            abi.encodeWithSelector(IGmxDataStore.getUint.selector),
            abi.encode(uint256(1 ether))
        );

        uint256 timeKey = block.timestamp;
        bytes32 expectedKey = keccak256(
            abi.encode(GmxCallbackLib.CLAIMABLE_COLLATERAL_AMOUNT_KEY, market, token, timeKey, address(callback))
        );
        vm.expectEmit(true, true, true, false);
        emit IEGmxCallback.ClaimableCollateralAdded(expectedKey, token, market, timeKey);
        callback.afterOrderExecution(bytes32(0), _orderData(market), _emptyEventData());
    }

    /// @notice Regression guard: if the pinned gmx-synthetics commit ever changes the
    ///  address-items order in OrderEventUtils.createEventData(), this test fails at the
    ///  source before EGmxCallback can silently decode the wrong fields.
    function test_AfterOrderExecution_EventLayout_Regression() public pure {
        Order.Props memory order = Order.Props({
            addresses: Order.Addresses({
                account: address(0x1111111111111111111111111111111111111111),
                receiver: address(0x2222222222222222222222222222222222222222),
                cancellationReceiver: address(0x3333333333333333333333333333333333333333),
                callbackContract: address(0x4444444444444444444444444444444444444444),
                uiFeeReceiver: address(0x5555555555555555555555555555555555555555),
                market: address(0x6666666666666666666666666666666666666666),
                initialCollateralToken: address(0x7777777777777777777777777777777777777777),
                swapPath: new address[](0)
            }),
            numbers: Order.Numbers({
                orderType: Order.OrderType.MarketIncrease,
                decreasePositionSwapType: Order.DecreasePositionSwapType.NoSwap,
                sizeDeltaUsd: 1,
                initialCollateralDeltaAmount: 2,
                triggerPrice: 3,
                acceptablePrice: 4,
                executionFee: 5,
                callbackGasLimit: 6,
                minOutputAmount: 7,
                updatedAtTime: 8,
                validFromTime: 9,
                srcChainId: 0
            }),
            flags: Order.Flags({isLong: true, shouldUnwrapNativeToken: false, isFrozen: false, autoCancel: false}),
            _dataList: new bytes32[](0)
        });

        EventUtils.EventLogData memory data = OrderEventUtils.createEventData(order);

        assertEq(data.addressItems.items[0].value, order.addresses.account);
        assertEq(data.addressItems.items[1].value, order.addresses.receiver);
        assertEq(data.addressItems.items[2].value, order.addresses.callbackContract);
        assertEq(data.addressItems.items[3].value, order.addresses.uiFeeReceiver);
        assertEq(data.addressItems.items[4].value, order.addresses.market);
        assertEq(data.addressItems.items[5].value, order.addresses.initialCollateralToken);
    }

    function _mockController() private {
        vm.mockCall(_GMX_ROLE_STORE, abi.encodeWithSelector(IGmxRoleStore.hasRole.selector), abi.encode(true));
    }

    function _mockMarketInfo(address mkt, address longToken, address shortToken) private {
        vm.mockCall(
            _GMX_READER,
            abi.encodeWithSelector(IGmxReader.getMarket.selector),
            abi.encode(
                Market.Props({marketToken: mkt, indexToken: longToken, longToken: longToken, shortToken: shortToken})
            )
        );
    }

    function _mockTimeDivisor(uint256 divisor) private {
        vm.mockCall(
            _GMX_DATA_STORE,
            abi.encodeWithSelector(
                IGmxDataStore.getUint.selector,
                GmxCallbackLib.CLAIMABLE_COLLATERAL_TIME_DIVISOR_KEY
            ),
            abi.encode(divisor)
        );
    }

    function _orderData(address mkt) private view returns (EventUtils.EventLogData memory) {
        EventUtils.AddressKeyValue[] memory items = new EventUtils.AddressKeyValue[](5);
        items[0] = EventUtils.AddressKeyValue({key: "account", value: address(callback)});
        items[4] = EventUtils.AddressKeyValue({key: "market", value: mkt});
        return
            EventUtils.EventLogData({
                addressItems: EventUtils.AddressItems({
                    items: items,
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
            });
    }

    function _emptyEventData() private pure returns (EventUtils.EventLogData memory) {
        return
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
            });
    }
}
