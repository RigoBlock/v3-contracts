// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IGmxDataStore, IGmxReader, IGmxExchangeRouter, IGmxOrderHandler, IGmxChainlinkPriceFeedProvider, GmxValidatedPrice} from "../../contracts/utils/exchanges/gmx/IGmxSynthetics.sol";
import {IBaseOrderUtils} from "gmx-synthetics/order/IBaseOrderUtils.sol";
import {Market} from "gmx-synthetics/market/Market.sol";
import {Order} from "gmx-synthetics/order/Order.sol";
import {Position} from "gmx-synthetics/position/Position.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {IWETH9} from "../../contracts/protocol/interfaces/IWETH9.sol";
import {StorageLib} from "../../contracts/protocol/libraries/StorageLib.sol";
import {GmxCallbackLib} from "../../contracts/protocol/libraries/GmxCallbackLib.sol";
import {GmxLib} from "../../contracts/protocol/libraries/GmxLib.sol";
import {AGmxV2} from "../../contracts/protocol/extensions/adapters/AGmxV2.sol";
import {IAGmxV2} from "../../contracts/protocol/extensions/adapters/interfaces/IAGmxV2.sol";
import {IEGmxCallback} from "../../contracts/protocol/extensions/adapters/interfaces/IEGmxCallback.sol";

/// @dev Proxy that delegatecalls an AGmxV2 adapter. Implements hasPriceFeed so
///  `_trackToken` can skip the oracle check when the token is the base token.
contract AGmxV2UnitProxy {
    address public immutable adapter;

    constructor(address _adapter) {
        adapter = _adapter;
    }

    function exec(bytes calldata data) external payable returns (bytes memory) {
        (bool ok, bytes memory res) = adapter.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(res, 32), mload(res))
            }
        }
        return res;
    }

    function hasPriceFeed(address) external pure returns (bool) {
        return true;
    }

    receive() external payable {}
}

/// @title AGmxV2UnitTest
/// @notice Non-fork unit tests for AGmxV2 pruning logic.
contract AGmxV2UnitTest is Test {
    AGmxV2 internal adapter;
    AGmxV2UnitProxy internal proxy;
    address internal market;
    address internal token;

    address internal constant GMX_CHAINLINK_PRICE_FEED = 0x38B8dB61b724b51e42A88Cb8eC564CD685a0f53B;

    function setUp() public {
        vm.chainId(GmxLib.ARBITRUM_CHAIN_ID);
        adapter = new AGmxV2();
        proxy = new AGmxV2UnitProxy(address(adapter));
        market = makeAddr("market");
        token = GmxLib.WRAPPED_NATIVE;

        // Base token == token so _trackToken returns early without oracle calls.
        vm.store(address(proxy), bytes32(uint256(StorageLib.POOL_INIT_SLOT) + 2), bytes32(uint256(uint160(token))));
    }

    /// @notice claimFundingFees removes a tracked market with no open position and no fees.
    function test_ClaimFundingFees_RemovesUnusedTrackedMarket() public {
        _setTrackedMarket(market);

        // No open positions.
        vm.mockCall(
            GmxLib._GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountPositions.selector),
            abi.encode(new Position.Props[](0))
        );

        // No claimable funding fees.
        vm.mockCall(
            GmxLib._GMX_READER,
            abi.encodeWithSelector(IGmxReader.getMarket.selector, GmxLib._GMX_DATA_STORE, market),
            abi.encode(Market.Props({marketToken: market, indexToken: token, longToken: token, shortToken: token}))
        );
        vm.mockCall(
            GmxLib._GMX_DATA_STORE,
            abi.encodeWithSelector(IGmxDataStore.getUint.selector),
            abi.encode(uint256(0))
        );

        // Mock router call.
        address[] memory markets = new address[](1);
        markets[0] = market;
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        vm.mockCall(
            address(GmxLib.GMX_ROUTER),
            abi.encodeWithSelector(IGmxExchangeRouter.claimFundingFees.selector, markets, tokens, address(proxy)),
            abi.encode(new uint256[](1))
        );

        vm.expectEmit(true, false, false, false);
        emit IEGmxCallback.TrackedMarketRemoved(market);

        proxy.exec(abi.encodeWithSelector(IAGmxV2.claimFundingFees.selector, markets, tokens, address(this)));
    }

    /// @notice claimCollateral removes a fully-claimed collateral key.
    function test_ClaimCollateral_RemovesFullyClaimedKey() public {
        uint256 timeKey = 1;
        bytes32 amountKey = keccak256(
            abi.encode(GmxCallbackLib.CLAIMABLE_COLLATERAL_AMOUNT_KEY, market, token, timeKey, address(proxy))
        );
        _setClaimableCollateralKey(amountKey);

        // claimCollateral amount is zero.
        vm.mockCall(
            GmxLib._GMX_DATA_STORE,
            abi.encodeWithSelector(IGmxDataStore.getUint.selector),
            abi.encode(uint256(0))
        );

        address[] memory markets = new address[](1);
        markets[0] = market;
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory timeKeys = new uint256[](1);
        timeKeys[0] = timeKey;

        vm.mockCall(
            address(GmxLib.GMX_ROUTER),
            abi.encodeWithSelector(
                IGmxExchangeRouter.claimCollateral.selector,
                markets,
                tokens,
                timeKeys,
                address(proxy)
            ),
            abi.encode(new uint256[](1))
        );

        vm.expectEmit(true, false, false, false);
        emit IEGmxCallback.ClaimableCollateralRemoved(amountKey);

        proxy.exec(abi.encodeWithSelector(IAGmxV2.claimCollateral.selector, markets, tokens, timeKeys, address(this)));
    }

    function _setTrackedMarket(address _market) internal {
        bytes32 slot = GmxCallbackLib.GMX_CALLBACK_DATA_SLOT;
        vm.store(address(proxy), slot, bytes32(uint256(1)));

        bytes32 arrayBase = keccak256(abi.encode(slot));
        vm.store(address(proxy), arrayBase, bytes32(uint256(uint160(_market))));

        bytes32 mappingBase = bytes32(uint256(slot) + 1);
        bytes32 positionSlot = keccak256(abi.encode(bytes32(uint256(uint160(_market))), mappingBase));
        vm.store(address(proxy), positionSlot, bytes32(uint256(1)));
    }

    function _setClaimableCollateralKey(bytes32 amountKey) internal {
        bytes32 slot = GmxCallbackLib.GMX_CALLBACK_DATA_SLOT;
        // claimableCollateralKeys struct starts 2 slots after trackedMarkets struct.
        bytes32 keysSlot = bytes32(uint256(slot) + 2);
        vm.store(address(proxy), keysSlot, bytes32(uint256(1)));

        bytes32 arrayBase = keccak256(abi.encode(keysSlot));
        vm.store(address(proxy), arrayBase, amountKey);

        bytes32 mappingBase = bytes32(uint256(keysSlot) + 1);
        bytes32 positionSlot = keccak256(abi.encode(amountKey, mappingBase));
        vm.store(address(proxy), positionSlot, bytes32(uint256(1)));

        // claimableCollateralInfo mapping base starts 4 slots after the slot origin.
        bytes32 infoBase = bytes32(uint256(slot) + 4);
        bytes32 infoSlot = keccak256(abi.encode(amountKey, infoBase));
        // token at offset 0, market at offset 1, timeKey at offset 2
        vm.store(address(proxy), infoSlot, bytes32(uint256(uint160(token))));
        vm.store(address(proxy), bytes32(uint256(infoSlot) + 1), bytes32(uint256(uint160(market))));
        vm.store(address(proxy), bytes32(uint256(infoSlot) + 2), bytes32(uint256(1)));
    }

    function _buildCreateOrderParams(
        address _market,
        address _collateralToken,
        bool _isLong
    ) internal pure returns (IBaseOrderUtils.CreateOrderParams memory) {
        return
            IBaseOrderUtils.CreateOrderParams({
                addresses: IBaseOrderUtils.CreateOrderParamsAddresses({
                    receiver: address(0),
                    cancellationReceiver: address(0),
                    callbackContract: address(0),
                    uiFeeReceiver: address(0),
                    market: _market,
                    initialCollateralToken: _collateralToken,
                    swapPath: new address[](0)
                }),
                numbers: IBaseOrderUtils.CreateOrderParamsNumbers({
                    sizeDeltaUsd: 1e30,
                    initialCollateralDeltaAmount: 1e18,
                    triggerPrice: 0,
                    acceptablePrice: 0,
                    executionFee: 0,
                    callbackGasLimit: 0,
                    minOutputAmount: 0,
                    validFromTime: 0
                }),
                orderType: Order.OrderType.MarketIncrease,
                decreasePositionSwapType: Order.DecreasePositionSwapType.NoSwap,
                isLong: _isLong,
                shouldUnwrapNativeToken: false,
                autoCancel: false,
                referralCode: bytes32(0),
                dataList: new bytes32[](0)
            });
    }

    function test_CreateIncreaseOrder_UnmappedIndexToken_Reverts() public {
        address indexToken = makeAddr("unmappedIndexToken");
        vm.deal(address(proxy), 1 ether);

        _mockCreateOrderInfrastructure();

        // Market props: indexToken is unmapped.
        vm.mockCall(
            GmxLib._GMX_READER,
            abi.encodeWithSelector(IGmxReader.getMarket.selector, GmxLib._GMX_DATA_STORE, market),
            abi.encode(Market.Props({marketToken: market, indexToken: indexToken, longToken: token, shortToken: token}))
        );
        // GMX provider has no feed for the unmapped token.
        vm.mockCallRevert(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeWithSelector(IGmxChainlinkPriceFeedProvider.getOraclePrice.selector, indexToken, ""),
            abi.encode("no price feed")
        );

        IBaseOrderUtils.CreateOrderParams memory params = _buildCreateOrderParams(market, token, true);

        vm.expectRevert(abi.encodeWithSelector(IAGmxV2.UnpricedIndexToken.selector, indexToken));
        proxy.exec(abi.encodeWithSelector(IAGmxV2.createIncreaseOrder.selector, params));
    }

    function test_CreateIncreaseOrder_MappedIndexToken_Succeeds() public {
        address indexToken = 0xE6172EecBB07F197F52bb73d74daa0e19C31c4Db; // LIT / USD
        vm.deal(address(proxy), 1 ether);

        _mockCreateOrderInfrastructure();

        vm.mockCall(
            GmxLib._GMX_READER,
            abi.encodeWithSelector(IGmxReader.getMarket.selector, GmxLib._GMX_DATA_STORE, market),
            abi.encode(Market.Props({marketToken: market, indexToken: indexToken, longToken: token, shortToken: token}))
        );
        vm.mockCall(
            GMX_CHAINLINK_PRICE_FEED,
            abi.encodeWithSelector(IGmxChainlinkPriceFeedProvider.getOraclePrice.selector, indexToken, ""),
            abi.encode(GmxValidatedPrice(indexToken, 1e30, 1e30, block.timestamp, block.number))
        );

        IBaseOrderUtils.CreateOrderParams memory params = _buildCreateOrderParams(market, token, true);

        // Succeeds without reverting.
        proxy.exec(abi.encodeWithSelector(IAGmxV2.createIncreaseOrder.selector, params));
    }

    /// @dev Mocks the GMX DataStore, Reader, Router, OrderHandler and OrderVault calls
    ///  that createIncreaseOrder needs regardless of the market being tested.
    function _mockCreateOrderInfrastructure() internal {
        address orderHandler = makeAddr("orderHandler");
        address orderVault = makeAddr("orderVault");

        // Execution fee reads return zero so the fee is small.
        vm.mockCall(
            GmxLib._GMX_DATA_STORE,
            abi.encodeWithSelector(IGmxDataStore.getUint.selector),
            abi.encode(uint256(0))
        );
        // No existing positions.
        vm.mockCall(
            GmxLib._GMX_READER,
            abi.encodeWithSelector(IGmxReader.getAccountPositions.selector),
            abi.encode(new Position.Props[](0))
        );
        // Pretend the pool already holds enough WETH so the adapter does not need to call deposit().
        vm.mockCall(
            GmxLib.WRAPPED_NATIVE,
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(proxy)),
            abi.encode(uint256(2 ether))
        );
        // Router -> handler -> vault.
        vm.mockCall(
            address(GmxLib.GMX_ROUTER),
            abi.encodeWithSelector(IGmxExchangeRouter.orderHandler.selector),
            abi.encode(orderHandler)
        );
        vm.mockCall(orderHandler, abi.encodeWithSelector(IGmxOrderHandler.orderVault.selector), abi.encode(orderVault));
        // createOrder succeeds and the adapter registers a saved callback.
        vm.mockCall(
            address(GmxLib.GMX_ROUTER),
            abi.encodeWithSelector(IGmxExchangeRouter.createOrder.selector),
            abi.encode(bytes32(uint256(1)))
        );
        vm.mockCall(
            address(GmxLib.GMX_ROUTER),
            abi.encodeWithSelector(IGmxExchangeRouter.setSavedCallbackContract.selector),
            abi.encode()
        );
    }
}
