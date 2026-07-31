// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {AHyperliquid} from "../../contracts/protocol/extensions/adapters/AHyperliquid.sol";
import {IAHyperliquid} from "../../contracts/protocol/extensions/adapters/interfaces/IAHyperliquid.sol";
import {HyperliquidLib} from "../../contracts/protocol/libraries/HyperliquidLib.sol";
import {AppTokenBalance} from "../../contracts/protocol/types/ExternalApp.sol";

/// @notice Minimal mock for the Hyperliquid CoreWriter.
contract MockCoreWriter {
    bytes public lastActionData;

    function sendRawAction(bytes calldata data) external {
        lastActionData = data;
    }
}

/// @notice Minimal mock for the Circle CoreDepositWallet.
contract MockCoreDepositWallet {
    address public lastToken;
    uint256 public lastAmount;
    uint32 public lastDestinationDex;

    function deposit(uint256 amount, uint32 destinationDex) external {
        lastAmount = amount;
        lastDestinationDex = destinationDex;
    }

    function setToken(address token) external {
        lastToken = token;
    }
}

/// @notice Simple ERC20 used as the Hyperliquid USDC stand-in.
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public decimals = 6;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "insufficient");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Exposes HyperliquidLib internal functions for unit testing.
contract HyperliquidLibHarness {
    function getHyperliquidBalances(address account) external view returns (AppTokenBalance[] memory) {
        return HyperliquidLib.getHyperliquidBalances(account);
    }

    function recordAction(int256 amount) external {
        HyperliquidLib.recordAction(address(this), amount);
    }

    function getHyperliquidData() external view returns (HyperliquidLib.HyperliquidData memory) {
        return HyperliquidLib.hyperliquidData();
    }

    function isHyperliquidBaseToken(address token) external view returns (bool) {
        return HyperliquidLib.isHyperliquidBaseToken(token);
    }

    function isPredictionMarketAsset(uint64 assetId) external pure returns (bool) {
        return HyperliquidLib.isPredictionMarketAsset(assetId);
    }

    function validatePredictionToken(uint64 assetId, uint64 spotIndex, uint64 tokenIndex) external view returns (bool) {
        return HyperliquidLib.validatePredictionToken(assetId, spotIndex, tokenIndex);
    }

    function recordPredictionToken(uint64 assetId, uint64 spotIndex, uint64 tokenIndex) external {
        HyperliquidLib.recordPredictionToken(assetId, spotIndex, tokenIndex);
    }

    function deregisterPredictionToken(uint64 tokenIndex) external {
        HyperliquidLib.removePredictionToken(address(this), tokenIndex);
    }

    function getPredictionTokenCount() external view returns (uint256) {
        return HyperliquidLib.getPredictionTokenCount();
    }

    function getPredictionBalances(address account) external view returns (AppTokenBalance[] memory) {
        return HyperliquidLib.getPredictionBalances(account);
    }

    function recordSpotAction(int256 amount) external {
        HyperliquidLib.recordSpotAction(address(this), amount);
    }

    function encodeLimitOrder(HyperliquidLib.LimitOrderParams calldata params) external pure returns (bytes memory) {
        return HyperliquidLib.encodeLimitOrder(params);
    }

    function encodeSpotSend(HyperliquidLib.SpotSendParams calldata params) external pure returns (bytes memory) {
        return HyperliquidLib.encodeSpotSend(params);
    }

    function encodeUsdClassTransfer(
        HyperliquidLib.UsdClassTransferParams calldata params
    ) external pure returns (bytes memory) {
        return HyperliquidLib.encodeUsdClassTransfer(params);
    }
}

/// @notice Simple byte-slice helper for `bytes memory` (Forge tests cannot use calldata slicing).
library BytesSlice {
    function slice(bytes memory data, uint256 start, uint256 length) internal pure returns (bytes memory result) {
        require(start + length <= data.length, "BytesSlice: out of bounds");
        result = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            result[i] = data[start + i];
        }
    }
}

/// @notice A minimal pool that delegatecalls the Hyperliquid adapter.
contract PoolHarness {
    address public implementation;

    constructor(address impl) {
        implementation = impl;
    }

    fallback() external payable {
        (bool success, bytes memory result) = implementation.delegatecall(msg.data);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
        assembly {
            return(add(result, 32), mload(result))
        }
    }

    receive() external payable {}
}

contract AHyperliquidUnitTest is Test {
    uint256 private constant _HYPEREVM_CHAIN_ID = 999;

    AHyperliquid private adapter;
    PoolHarness private pool;
    HyperliquidLibHarness private libHarness;

    address private constant _USDC = HyperliquidLib.USDC;
    address private constant _CORE_WRITER = HyperliquidLib.CORE_WRITER;
    address private constant _CORE_DEPOSIT_WALLET = HyperliquidLib.CORE_DEPOSIT_WALLET;
    address private constant _ORACLE_PX = 0x0000000000000000000000000000000000000807;
    address private constant _SPOT_PX = 0x0000000000000000000000000000000000000808;
    address private constant _SPOT_INFO = 0x000000000000000000000000000000000000080b;
    address private constant _PERP_ASSET_INFO = 0x000000000000000000000000000000000000080a;
    address private constant _TOKEN_INFO = 0x000000000000000000000000000000000000080C;
    address private constant _SPOT_BALANCE = 0x0000000000000000000000000000000000000801;
    address private constant _ACCOUNT_MARGIN_SUMMARY = 0x000000000000000000000000000000000000080F;

    function setUp() public {
        vm.chainId(_HYPEREVM_CHAIN_ID);

        adapter = new AHyperliquid();
        pool = new PoolHarness(address(adapter));
        libHarness = new HyperliquidLibHarness();

        // Deploy mocks at the Hyperliquid fixed addresses so the adapter can reach them.
        MockCoreWriter coreWriter = new MockCoreWriter();
        MockCoreDepositWallet depositWallet = new MockCoreDepositWallet();
        MockERC20 usdc = new MockERC20();

        vm.etch(_CORE_WRITER, address(coreWriter).code);
        vm.etch(_CORE_DEPOSIT_WALLET, address(depositWallet).code);
        vm.etch(_USDC, address(usdc).code);

        // Fund the pool harness with USDC.
        MockERC20(_USDC).mint(address(pool), 1_000_000e6);
    }

    function testDeployRevertsOnNonHyperEVM() public {
        vm.chainId(1);
        vm.expectRevert(IAHyperliquid.NotHyperEVM.selector);
        new AHyperliquid();
    }

    function testDepositToCoreRevertsForNonUSDC() public {
        vm.chainId(_HYPEREVM_CHAIN_ID);
        vm.expectRevert(IAHyperliquid.InvalidToken.selector);
        IAHyperliquid(address(pool)).depositToCore(address(0xdead), 0, 100e6);
    }

    function testDepositToCoreRevertsForNonCorePerpDex() public {
        vm.chainId(_HYPEREVM_CHAIN_ID);
        vm.expectRevert(IAHyperliquid.InvalidDex.selector);
        IAHyperliquid(address(pool)).depositToCore(_USDC, 1, 100e6);
    }

    function testDepositToCoreBridgesUSDC() public {
        vm.chainId(_HYPEREVM_CHAIN_ID);
        IAHyperliquid(address(pool)).depositToCore(_USDC, 0, 100e6);

        MockCoreDepositWallet depositWallet = MockCoreDepositWallet(_CORE_DEPOSIT_WALLET);
        assertEq(depositWallet.lastAmount(), 100e6);
        assertEq(depositWallet.lastDestinationDex(), 0);

        // Approval is reset to 1 after the call.
        assertEq(MockERC20(_USDC).allowance(address(pool), _CORE_DEPOSIT_WALLET), 1);
    }

    function testWithdrawFromCoreBridgesUSDC() public {
        vm.chainId(_HYPEREVM_CHAIN_ID);

        IAHyperliquid(address(pool)).withdrawFromCore(100e6);

        MockCoreWriter coreWriter = MockCoreWriter(_CORE_WRITER);
        bytes memory actionData = coreWriter.lastActionData();

        // First byte: version = 1, next 3 bytes: action id = 6 (spotSend).
        assertEq(uint8(actionData[0]), 1);
        assertEq(uint24(bytes3(BytesSlice.slice(actionData, 1, 3))), 6);

        // Decode the SpotSend params.
        HyperliquidLib.SpotSendParams memory params = abi.decode(
            BytesSlice.slice(actionData, 4, actionData.length - 4),
            (HyperliquidLib.SpotSendParams)
        );
        assertEq(params.destinationAddress, HyperliquidLib.USDC_SYSTEM_ADDRESS);
        assertEq(params.token, HyperliquidLib.USDC_TOKEN_INDEX);
        assertEq(params.amount, 100e6 * 1e2); // 6-decimal USDC scaled to 8-decimal Core wei
    }

    function testWithdrawFromCoreRevertsForExcessiveAmount() public {
        vm.chainId(_HYPEREVM_CHAIN_ID);
        uint256 excessiveAmount = type(uint64).max / 1e2 + 1;
        vm.expectRevert(IAHyperliquid.InvalidAmount.selector);
        IAHyperliquid(address(pool)).withdrawFromCore(excessiveAmount);
    }

    function testTransferUsdClass() public {
        vm.chainId(_HYPEREVM_CHAIN_ID);

        IAHyperliquid(address(pool)).transferUsdClass(100e6, true);

        MockCoreWriter coreWriter = MockCoreWriter(_CORE_WRITER);
        bytes memory actionData = coreWriter.lastActionData();

        // First byte: version = 1, next 3 bytes: action id = 7 (usdClassTransfer).
        assertEq(uint8(actionData[0]), 1);
        assertEq(uint24(bytes3(BytesSlice.slice(actionData, 1, 3))), 7);

        HyperliquidLib.UsdClassTransferParams memory params = abi.decode(
            BytesSlice.slice(actionData, 4, actionData.length - 4),
            (HyperliquidLib.UsdClassTransferParams)
        );
        assertEq(params.ntl, 100e6);
        assertTrue(params.toPerp);
    }

    function testSubmitPerpOrderRevertsForSpotAsset() public {
        vm.chainId(_HYPEREVM_CHAIN_ID);
        HyperliquidLib.LimitOrderParams memory params = HyperliquidLib.LimitOrderParams({
            asset: 10_000, // spot asset boundary
            isBuy: true,
            limitPx: 100_000_000,
            sz: 1e6,
            reduceOnly: false,
            encodedTif: 3,
            cloid: 0
        });
        vm.expectRevert(IAHyperliquid.OnlyCorePerp.selector);
        IAHyperliquid(address(pool)).submitPerpOrder(params);
    }

    function testSubmitPerpOrderRevertsForInvalidTif() public {
        vm.chainId(_HYPEREVM_CHAIN_ID);
        HyperliquidLib.LimitOrderParams memory params = HyperliquidLib.LimitOrderParams({
            asset: 1,
            isBuy: true,
            limitPx: 100_000_000,
            sz: 1e6,
            reduceOnly: false,
            encodedTif: 1, // ALO, not allowed
            cloid: 0
        });
        vm.expectRevert(IAHyperliquid.InvalidTif.selector);
        IAHyperliquid(address(pool)).submitPerpOrder(params);
    }

    function testSubmitPerpOrderRevertsForGtcNonReduceOnly() public {
        vm.chainId(_HYPEREVM_CHAIN_ID);
        HyperliquidLib.LimitOrderParams memory params = HyperliquidLib.LimitOrderParams({
            asset: 1,
            isBuy: true,
            limitPx: 100_000_000,
            sz: 1e6,
            reduceOnly: false,
            encodedTif: 2, // GTC
            cloid: 0
        });
        vm.expectRevert(IAHyperliquid.ReduceOnlyGtcOnly.selector);
        IAHyperliquid(address(pool)).submitPerpOrder(params);
    }

    function testSubmitPerpOrderSlippageCheck() public {
        vm.chainId(_HYPEREVM_CHAIN_ID);

        // Mock perp asset info: szDecimals = 5.
        vm.mockCall(
            _PERP_ASSET_INFO,
            abi.encode(uint32(1)),
            abi.encode(
                HyperliquidLib.PerpAssetInfo({
                    coin: "BTC",
                    marginTableId: 0,
                    szDecimals: 5,
                    maxLeverage: 25,
                    onlyIsolated: false
                })
            )
        );

        // Mock oracle price: 50_000 USD. For szDecimals=5, raw oraclePx = human * 10^(6-5) = 500_000.
        vm.mockCall(_ORACLE_PX, abi.encode(uint32(1)), abi.encode(uint64(500_000)));

        // Expected px = 500_000 * 1e5 * 1e2 = 5e12 (50_000 with 8 decimals). 1% slippage = 5e10.
        // Buy limit above expected + slippage should revert.
        HyperliquidLib.LimitOrderParams memory params = HyperliquidLib.LimitOrderParams({
            asset: 1,
            isBuy: true,
            limitPx: 6e12, // > 5.05e12
            sz: 1e6,
            reduceOnly: false,
            encodedTif: 3,
            cloid: 0
        });
        vm.expectRevert(IAHyperliquid.SlippageExceeded.selector);
        IAHyperliquid(address(pool)).submitPerpOrder(params);

        // Acceptable price should succeed.
        params.limitPx = 5.04e12;
        IAHyperliquid(address(pool)).submitPerpOrder(params);

        MockCoreWriter coreWriter = MockCoreWriter(_CORE_WRITER);
        assertTrue(coreWriter.lastActionData().length > 0);
    }

    function testGetHyperliquidBalancesWithAccountValue() public {
        vm.chainId(_HYPEREVM_CHAIN_ID);

        vm.mockCall(
            _ACCOUNT_MARGIN_SUMMARY,
            abi.encode(uint32(0), address(libHarness)),
            abi.encode(
                HyperliquidLib.AccountMarginSummary({accountValue: 1_000_000, marginUsed: 0, ntlPos: 0, rawUsd: 0})
            )
        );

        AppTokenBalance[] memory balances = libHarness.getHyperliquidBalances(address(libHarness));
        assertEq(balances.length, 1);
        assertEq(balances[0].token, _USDC);
        assertEq(balances[0].amount, 1_000_000);
    }

    function testGetHyperliquidBalancesDustAfterRecentAction() public {
        vm.chainId(_HYPEREVM_CHAIN_ID);

        vm.mockCall(
            _ACCOUNT_MARGIN_SUMMARY,
            abi.encode(uint32(0), address(libHarness)),
            abi.encode(HyperliquidLib.AccountMarginSummary({accountValue: 0, marginUsed: 0, ntlPos: 0, rawUsd: 0}))
        );

        // Before any action, zero account value means no balances.
        AppTokenBalance[] memory balances = libHarness.getHyperliquidBalances(address(libHarness));
        assertEq(balances.length, 0);

        // After recording an action, zero account value returns 1 wei dust to prevent purge.
        libHarness.recordAction(0);
        balances = libHarness.getHyperliquidBalances(address(libHarness));
        assertEq(balances.length, 1);
        assertEq(balances[0].token, _USDC);
        assertEq(balances[0].amount, 1);

        // After advancing one block, the dust is gone and the app can be purged.
        vm.roll(block.number + 1);
        balances = libHarness.getHyperliquidBalances(address(libHarness));
        assertEq(balances.length, 0);
    }

    function testIsHyperliquidBaseTokenOnlyOnHyperEVM() public {
        vm.chainId(_HYPEREVM_CHAIN_ID);
        assertTrue(libHarness.isHyperliquidBaseToken(_USDC));
        assertFalse(libHarness.isHyperliquidBaseToken(address(0)));

        vm.chainId(1);
        assertFalse(libHarness.isHyperliquidBaseToken(_USDC));
    }

    // =========================================================================
    // Prediction market unit tests
    // =========================================================================

    uint64 private constant _HIP4_ASSET_ID = 100_000_010; // encoding 10, outcome 1, side 0
    uint64 private constant _HIP4_SPOT_INDEX = 1000;
    uint64 private constant _HIP4_TOKEN_INDEX = 42;
    uint64 private constant _USDC_TOKEN_INDEX_LOCAL = 0;

    function _mockPredictionTokenPrecompiles() private {
        vm.mockCall(
            _SPOT_INFO,
            abi.encode(_HIP4_SPOT_INDEX),
            abi.encode(HyperliquidLib.SpotInfo({name: "BTC-OUTCOME-1", tokens: [uint64(0), _HIP4_TOKEN_INDEX]}))
        );

        vm.mockCall(
            _TOKEN_INFO,
            abi.encode(_USDC_TOKEN_INDEX_LOCAL),
            abi.encode(
                HyperliquidLib.TokenInfo({
                    name: "USDC",
                    spots: new uint64[](0),
                    deployerTradingFeeShare: 0,
                    deployer: address(0),
                    evmContract: _USDC,
                    szDecimals: 0,
                    weiDecimals: 8,
                    evmExtraWeiDecimals: 2
                })
            )
        );

        vm.mockCall(
            _TOKEN_INFO,
            abi.encode(_HIP4_TOKEN_INDEX),
            abi.encode(
                HyperliquidLib.TokenInfo({
                    name: "+10",
                    spots: new uint64[](0),
                    deployerTradingFeeShare: 0,
                    deployer: address(0),
                    evmContract: address(0),
                    szDecimals: 0,
                    weiDecimals: 8,
                    evmExtraWeiDecimals: 0
                })
            )
        );
    }

    function _mockSpotBalance(address account, uint64 tokenIndex, uint64 total) private {
        vm.mockCall(
            _SPOT_BALANCE,
            abi.encode(account, tokenIndex),
            abi.encode(HyperliquidLib.SpotBalance({total: total, hold: 0, entryNtl: 0}))
        );
    }

    function _mockSpotPx(uint64 spotIndex, uint64 price) private {
        vm.mockCall(_SPOT_PX, abi.encode(spotIndex), abi.encode(price));
    }

    function testIsPredictionMarketAsset() public {
        vm.chainId(_HYPEREVM_CHAIN_ID);
        assertTrue(libHarness.isPredictionMarketAsset(_HIP4_ASSET_ID));
        assertFalse(libHarness.isPredictionMarketAsset(9999));
        assertFalse(libHarness.isPredictionMarketAsset(10_000));
    }

    function testValidatePredictionToken() public {
        vm.chainId(_HYPEREVM_CHAIN_ID);
        _mockPredictionTokenPrecompiles();

        assertTrue(libHarness.validatePredictionToken(_HIP4_ASSET_ID, _HIP4_SPOT_INDEX, _HIP4_TOKEN_INDEX));
        // USDC index is not a valid prediction token.
        assertFalse(libHarness.validatePredictionToken(_HIP4_ASSET_ID, _HIP4_SPOT_INDEX, _USDC_TOKEN_INDEX_LOCAL));
    }

    function testRegisterAndDeregisterPredictionToken() public {
        vm.chainId(_HYPEREVM_CHAIN_ID);
        _mockPredictionTokenPrecompiles();

        assertEq(libHarness.getPredictionTokenCount(), 0);
        libHarness.recordPredictionToken(_HIP4_ASSET_ID, _HIP4_SPOT_INDEX, _HIP4_TOKEN_INDEX);
        assertEq(libHarness.getPredictionTokenCount(), 1);

        // Duplicate registration reverts.
        vm.expectRevert(
            abi.encodeWithSelector(HyperliquidLib.HyperliquidPredictionTokenAlreadyRegistered.selector, _HIP4_ASSET_ID)
        );
        libHarness.recordPredictionToken(_HIP4_ASSET_ID, _HIP4_SPOT_INDEX, _HIP4_TOKEN_INDEX);

        // Deregistration succeeds only when the tracked token has no balance.
        _mockSpotBalance(address(libHarness), _HIP4_TOKEN_INDEX, 0);
        libHarness.deregisterPredictionToken(_HIP4_TOKEN_INDEX);
        assertEq(libHarness.getPredictionTokenCount(), 0);
    }

    function testDeregisterPredictionTokenRevertsIfBalanceNotZero() public {
        vm.chainId(_HYPEREVM_CHAIN_ID);
        _mockPredictionTokenPrecompiles();
        _mockSpotBalance(address(libHarness), _HIP4_TOKEN_INDEX, 1e8);

        libHarness.recordPredictionToken(_HIP4_ASSET_ID, _HIP4_SPOT_INDEX, _HIP4_TOKEN_INDEX);

        vm.expectRevert(
            abi.encodeWithSelector(HyperliquidLib.HyperliquidPredictionTokenBalanceNotZero.selector, _HIP4_TOKEN_INDEX)
        );
        libHarness.deregisterPredictionToken(_HIP4_TOKEN_INDEX);
    }

    function testGetPredictionBalances() public {
        vm.chainId(_HYPEREVM_CHAIN_ID);
        _mockPredictionTokenPrecompiles();
        _mockSpotBalance(address(libHarness), _USDC_TOKEN_INDEX_LOCAL, 10_000e8); // 10k USDC in spot
        _mockSpotBalance(address(libHarness), _HIP4_TOKEN_INDEX, 27e8); // 27 outcome tokens
        _mockSpotPx(_HIP4_SPOT_INDEX, 47_000_000); // 0.47 USDC

        libHarness.recordPredictionToken(_HIP4_ASSET_ID, _HIP4_SPOT_INDEX, _HIP4_TOKEN_INDEX);

        AppTokenBalance[] memory balances = libHarness.getPredictionBalances(address(libHarness));
        assertEq(balances.length, 1);
        assertEq(balances[0].token, _USDC);

        // 10_000 USDC spot + 27 * 0.47 USDC = 10_012.69 USDC in 6 decimals.
        int256 expected = 10_000e6 + 12_690_000;
        assertEq(balances[0].amount, expected);
    }

    function testGetPredictionBalancesAddsInFlightDeposit() public {
        vm.chainId(_HYPEREVM_CHAIN_ID);
        _mockPredictionTokenPrecompiles();
        _mockSpotBalance(address(libHarness), _USDC_TOKEN_INDEX_LOCAL, 0);
        _mockSpotBalance(address(libHarness), _HIP4_TOKEN_INDEX, 0);
        _mockSpotPx(_HIP4_SPOT_INDEX, 47_000_000);

        libHarness.recordPredictionToken(_HIP4_ASSET_ID, _HIP4_SPOT_INDEX, _HIP4_TOKEN_INDEX);
        libHarness.recordSpotAction(1_000e6);

        AppTokenBalance[] memory balances = libHarness.getPredictionBalances(address(libHarness));
        assertEq(balances.length, 1);
        assertEq(balances[0].token, _USDC);
        assertEq(balances[0].amount, 1_000e6);

        // Next block the in-flight amount is cleared and the balance is zero again.
        vm.roll(block.number + 1);
        balances = libHarness.getPredictionBalances(address(libHarness));
        assertEq(balances.length, 0);
    }

    function testDepositToSpotBridgesUSDC() public {
        vm.chainId(_HYPEREVM_CHAIN_ID);
        IAHyperliquid(address(pool)).depositToSpot(_USDC, 100e6);

        MockCoreDepositWallet depositWallet = MockCoreDepositWallet(_CORE_DEPOSIT_WALLET);
        assertEq(depositWallet.lastAmount(), 100e6);
        assertEq(depositWallet.lastDestinationDex(), uint32(HyperliquidLib.DEX_ID_CORE_SPOT));
        assertEq(MockERC20(_USDC).allowance(address(pool), _CORE_DEPOSIT_WALLET), 1);
    }

    function testSubmitPredictionOrderRevertsForUnregisteredAsset() public {
        vm.chainId(_HYPEREVM_CHAIN_ID);
        _mockPredictionTokenPrecompiles();

        HyperliquidLib.LimitOrderParams memory params = HyperliquidLib.LimitOrderParams({
            asset: uint32(_HIP4_ASSET_ID),
            isBuy: true,
            limitPx: 47_000_000,
            sz: 22e8, // 22 tokens, notional > 10 USDC
            reduceOnly: false,
            encodedTif: 3,
            cloid: 0
        });

        vm.expectRevert(IAHyperliquid.PredictionTokenNotRegistered.selector);
        IAHyperliquid(address(pool)).submitPredictionOrder(params);
    }

    function testSubmitPredictionOrderSlippageAndNotional() public {
        vm.chainId(_HYPEREVM_CHAIN_ID);
        _mockPredictionTokenPrecompiles();
        _mockSpotPx(_HIP4_SPOT_INDEX, 47_000_000);

        IAHyperliquid(address(pool)).registerPredictionToken(_HIP4_ASSET_ID, _HIP4_SPOT_INDEX, _HIP4_TOKEN_INDEX);

        HyperliquidLib.LimitOrderParams memory params = HyperliquidLib.LimitOrderParams({
            asset: uint32(_HIP4_ASSET_ID),
            isBuy: true,
            limitPx: 47_400_000, // within 1% of 47_000_000 spot price
            sz: 22, // 22 tokens at 0.474 USDC = 10.428 USDC notional
            reduceOnly: false,
            encodedTif: 3,
            cloid: 0
        });
        IAHyperliquid(address(pool)).submitPredictionOrder(params);

        MockCoreWriter coreWriter = MockCoreWriter(_CORE_WRITER);
        assertTrue(coreWriter.lastActionData().length > 0);

        // Too small notional reverts.
        params.sz = 21;
        vm.expectRevert(IAHyperliquid.PredictionOrderTooSmall.selector);
        IAHyperliquid(address(pool)).submitPredictionOrder(params);

        // Excessive slippage reverts.
        params.sz = 22;
        params.limitPx = 50_000_000;
        vm.expectRevert(IAHyperliquid.SlippageExceeded.selector);
        IAHyperliquid(address(pool)).submitPredictionOrder(params);
    }
}
