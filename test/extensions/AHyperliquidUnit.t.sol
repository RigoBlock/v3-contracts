// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AHyperliquid} from "../../contracts/protocol/extensions/adapters/AHyperliquid.sol";
import {IAHyperliquid} from "../../contracts/protocol/extensions/adapters/interfaces/IAHyperliquid.sol";
import {HyperliquidLib} from "../../contracts/protocol/libraries/HyperliquidLib.sol";
import {HLConstants} from "hyper-evm-lib/common/HLConstants.sol";
import {PrecompileLib} from "hyper-evm-lib/PrecompileLib.sol";
import {CoreWriterLib} from "hyper-evm-lib/CoreWriterLib.sol";
import {AppTokenBalance} from "../../contracts/protocol/types/ExternalApp.sol";
import {Constants} from "../../contracts/test/Constants.sol";

/// @notice Minimal mock for the Hyperliquid CoreWriter.
contract MockCoreWriter {
    bytes public lastActionData;

    function sendRawAction(bytes calldata data) external {
        lastActionData = data;
    }
}

/// @notice Minimal mock for the Circle CoreDepositWallet.
contract MockCoreDepositWallet {
    uint256 public lastAmount;
    uint32 public lastDestinationDex;
    address public lastRecipient;

    function depositFor(address recipient, uint256 amount, uint32 destinationDex) external {
        lastAmount = amount;
        lastDestinationDex = destinationDex;
        lastRecipient = recipient;
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
        HyperliquidLib.recordAction(amount);
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

contract AHyperliquidUnit is Test {
    AHyperliquid private adapter;
    PoolHarness private pool;
    HyperliquidLibHarness private libHarness;

    // Hyperliquid system and precompile addresses are sourced from hyper-evm-lib and Constants.
    address private immutable _usdc = Constants.HYPER_USDC;
    address private immutable _coreWriter = address(CoreWriterLib.coreWriter);
    address private immutable _coreDepositWallet = HLConstants.CORE_DEPOSIT_WALLET;
    address private immutable _tokenInfo = HLConstants.TOKEN_INFO_PRECOMPILE_ADDRESS;
    address private immutable _spotBalance = HLConstants.SPOT_BALANCE_PRECOMPILE_ADDRESS;
    address private immutable _accountMarginSummary = HLConstants.ACCOUNT_MARGIN_SUMMARY_PRECOMPILE_ADDRESS;
    address private immutable _coreUserExists = HLConstants.CORE_USER_EXISTS_PRECOMPILE_ADDRESS;

    function _mockTokenInfo(
        uint64 tokenIndex,
        string memory name,
        address evmContract,
        uint8 szDecimals,
        uint8 weiDecimals,
        int8 evmExtraWeiDecimals
    ) private {
        vm.mockCall(
            _tokenInfo,
            abi.encode(tokenIndex),
            abi.encode(
                PrecompileLib.TokenInfo({
                    name: name,
                    spots: new uint64[](0),
                    deployerTradingFeeShare: 0,
                    deployer: address(0),
                    evmContract: evmContract,
                    szDecimals: szDecimals,
                    weiDecimals: weiDecimals,
                    evmExtraWeiDecimals: evmExtraWeiDecimals
                })
            )
        );
    }

    function setUp() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);

        adapter = new AHyperliquid();
        pool = new PoolHarness(address(adapter));
        libHarness = new HyperliquidLibHarness();

        // Deploy mocks at the Hyperliquid fixed addresses so the adapter can reach them.
        MockCoreWriter coreWriter = new MockCoreWriter();
        MockCoreDepositWallet depositWallet = new MockCoreDepositWallet();
        MockERC20 usdc = new MockERC20();

        vm.etch(_coreWriter, address(coreWriter).code);
        vm.etch(_coreDepositWallet, address(depositWallet).code);
        vm.etch(_usdc, address(usdc).code);

        // Fund the pool harness with USDC.
        MockERC20(_usdc).mint(address(pool), 1_000_000e6);

        // Mock USDC tokenInfo for decimal conversions.
        // HyperCore USDC has 8 decimals, EVM USDC has 6 decimals -> evmExtraWeiDecimals = -2.
        _mockTokenInfo(HLConstants.USDC_TOKEN_INDEX, "USDC", _usdc, 0, 8, -2);

        // Mock the account-existence precompile so sendRawAction tests can run.
        _mockCoreUserExists(address(pool), true);
    }

    function _mockCoreUserExists(address account, bool exists) private {
        vm.mockCall(_coreUserExists, abi.encode(account), abi.encode(exists));
    }

    function _mockSpotBalance(address account, uint64 tokenIndex, uint64 total) private {
        vm.mockCall(
            _spotBalance,
            abi.encode(account, tokenIndex),
            abi.encode(PrecompileLib.SpotBalance({total: total, hold: 0, entryNtl: 0}))
        );
    }

    function testDeployRevertsOnNonHyperEVM() public {
        vm.chainId(1);
        vm.expectRevert(IAHyperliquid.NotHyperEVM.selector);
        new AHyperliquid();
    }

    function testDepositRevertsForInvalidDex() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);
        vm.expectRevert(IAHyperliquid.InvalidDex.selector);
        IAHyperliquid(address(pool)).deposit(100e6, 1);
    }

    function testDepositBridgesUSDC() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);
        IAHyperliquid(address(pool)).deposit(100e6, 0);

        MockCoreDepositWallet depositWallet = MockCoreDepositWallet(_coreDepositWallet);
        assertEq(depositWallet.lastAmount(), 100e6);
        assertEq(depositWallet.lastDestinationDex(), 0);
        assertEq(depositWallet.lastRecipient(), address(pool));

        // Approval is reset to 1 after the call.
        assertEq(MockERC20(_usdc).allowance(address(pool), _coreDepositWallet), 1);
    }

    function testDepositForBridgesUSDCOnBehalfOfPool() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);
        IAHyperliquid(address(pool)).depositFor(address(pool), 100e6, 0);

        MockCoreDepositWallet depositWallet = MockCoreDepositWallet(_coreDepositWallet);
        assertEq(depositWallet.lastAmount(), 100e6);
        assertEq(depositWallet.lastDestinationDex(), 0);
        assertEq(depositWallet.lastRecipient(), address(pool));

        // Approval is reset to 1 after the call.
        assertEq(MockERC20(_usdc).allowance(address(pool), _coreDepositWallet), 1);
    }

    function testDepositForRevertsForNonPoolRecipient() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);
        vm.expectRevert(IAHyperliquid.InvalidActionData.selector);
        IAHyperliquid(address(pool)).depositFor(address(0xdead), 100e6, 0);
    }

    function testDepositToSpotReverts() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);
        vm.expectRevert(IAHyperliquid.InvalidDex.selector);
        IAHyperliquid(address(pool)).deposit(100e6, HLConstants.SPOT_DEX);
    }

    function testSendRawActionUnsupportedActionReverts() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);
        bytes memory data = abi.encodePacked(uint8(1), uint24(99));
        vm.expectRevert(abi.encodeWithSelector(IAHyperliquid.UnsupportedAction.selector, uint24(99)));
        IAHyperliquid(address(pool)).sendRawAction(data);
    }

    function testSendRawActionUsdClassTransfer() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);

        bytes memory data = abi.encodePacked(
            uint8(1),
            uint24(HLConstants.USD_CLASS_TRANSFER_ACTION),
            abi.encode(uint64(100e6), true)
        );
        IAHyperliquid(address(pool)).sendRawAction(data);

        MockCoreWriter coreWriter = MockCoreWriter(_coreWriter);
        bytes memory actionData = coreWriter.lastActionData();

        assertEq(uint8(actionData[0]), 1);
        assertEq(uint24(bytes3(BytesSlice.slice(actionData, 1, 3))), HLConstants.USD_CLASS_TRANSFER_ACTION);

        (uint64 ntl, bool toPerp) = abi.decode(BytesSlice.slice(actionData, 4, actionData.length - 4), (uint64, bool));
        assertEq(ntl, 100e6);
        assertTrue(toPerp);
    }

    function testSendRawActionSpotSend() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);

        uint64 amountWei = 100e6 * 1e2; // 6-decimal USDC scaled to 8-decimal Core wei
        address systemAddress = CoreWriterLib.getSystemAddress(HLConstants.USDC_TOKEN_INDEX);

        // Mock enough spot USDC to cover the requested amount plus the bridge gas reserve.
        _mockSpotBalance(address(pool), HLConstants.USDC_TOKEN_INDEX, amountWei + 1e7);

        bytes memory data = abi.encodePacked(
            uint8(1),
            uint24(HLConstants.SPOT_SEND_ACTION),
            abi.encode(systemAddress, HLConstants.USDC_TOKEN_INDEX, amountWei)
        );
        IAHyperliquid(address(pool)).sendRawAction(data);

        MockCoreWriter coreWriter = MockCoreWriter(_coreWriter);
        bytes memory actionData = coreWriter.lastActionData();
        assertEq(uint24(bytes3(BytesSlice.slice(actionData, 1, 3))), HLConstants.SPOT_SEND_ACTION);
    }

    function testSendRawActionSpotSendRevertsForNonUsdcToken() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);

        uint64 amountWei = 100e6 * 1e2;
        bytes memory data = abi.encodePacked(
            uint8(1),
            uint24(HLConstants.SPOT_SEND_ACTION),
            abi.encode(CoreWriterLib.getSystemAddress(999), uint64(999), amountWei)
        );
        vm.expectRevert(IAHyperliquid.InvalidActionData.selector);
        IAHyperliquid(address(pool)).sendRawAction(data);
    }

    function testSendRawActionSpotSendRevertsForArbitraryDestination() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);

        uint64 amountWei = 100e6 * 1e2;
        bytes memory data = abi.encodePacked(
            uint8(1),
            uint24(HLConstants.SPOT_SEND_ACTION),
            abi.encode(address(0xdead), HLConstants.USDC_TOKEN_INDEX, amountWei)
        );
        vm.expectRevert(IAHyperliquid.InvalidActionData.selector);
        IAHyperliquid(address(pool)).sendRawAction(data);
    }

    function testSendRawActionSpotSendRevertsForInsufficientReserve() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);

        uint64 amountWei = 100e6 * 1e2;
        address systemAddress = CoreWriterLib.getSystemAddress(HLConstants.USDC_TOKEN_INDEX);

        // Mock a spot balance that leaves less than the 0.1 USDC bridge gas reserve.
        _mockSpotBalance(address(pool), HLConstants.USDC_TOKEN_INDEX, amountWei + 1e6);

        bytes memory data = abi.encodePacked(
            uint8(1),
            uint24(HLConstants.SPOT_SEND_ACTION),
            abi.encode(systemAddress, HLConstants.USDC_TOKEN_INDEX, amountWei)
        );
        vm.expectRevert(IAHyperliquid.InsufficientBridgeReserve.selector);
        IAHyperliquid(address(pool)).sendRawAction(data);
    }

    function testSendRawActionLimitOrderForwardsToCoreWriter() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);

        bytes memory data = _encodeLimitOrder(1, true, 100_000_000, 1e6, false, HLConstants.LIMIT_ORDER_TIF_IOC, 0);
        IAHyperliquid(address(pool)).sendRawAction(data);

        MockCoreWriter coreWriter = MockCoreWriter(_coreWriter);
        bytes memory actionData = coreWriter.lastActionData();

        assertEq(uint8(actionData[0]), 1);
        assertEq(uint24(bytes3(BytesSlice.slice(actionData, 1, 3))), HLConstants.LIMIT_ORDER_ACTION);

        (uint32 asset, bool isBuy, uint64 limitPx, uint64 sz, bool reduceOnly, uint8 encodedTif, uint128 cloid) = abi
            .decode(
                BytesSlice.slice(actionData, 4, actionData.length - 4),
                (uint32, bool, uint64, uint64, bool, uint8, uint128)
            );

        assertEq(asset, 1);
        assertTrue(isBuy);
        assertEq(limitPx, 100_000_000);
        assertEq(sz, 1e6);
        assertFalse(reduceOnly);
        assertEq(encodedTif, HLConstants.LIMIT_ORDER_TIF_IOC);
        assertEq(cloid, 0);
    }

    function testSendRawActionLimitOrderRevertsForZeroSize() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);

        bytes memory data = _encodeLimitOrder(1, true, 100_000_000, 0, false, HLConstants.LIMIT_ORDER_TIF_IOC, 0);
        vm.expectRevert(IAHyperliquid.InvalidAmount.selector);
        IAHyperliquid(address(pool)).sendRawAction(data);
    }

    function testSendRawActionLimitOrderRevertsForSpotAsset() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);

        bytes memory data = _encodeLimitOrder(
            uint32(10_000),
            true,
            100_000_000,
            1e6,
            false,
            HLConstants.LIMIT_ORDER_TIF_IOC,
            0
        );
        vm.expectRevert(IAHyperliquid.InvalidActionData.selector);
        IAHyperliquid(address(pool)).sendRawAction(data);
    }

    function testSendRawActionLimitOrderRevertsForOutcomeMarket() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);

        bytes memory data = _encodeLimitOrder(
            uint32(100_000_000),
            true,
            100_000_000,
            1e6,
            false,
            HLConstants.LIMIT_ORDER_TIF_IOC,
            0
        );
        vm.expectRevert(IAHyperliquid.InvalidActionData.selector);
        IAHyperliquid(address(pool)).sendRawAction(data);
    }

    function _encodeLimitOrder(
        uint32 asset,
        bool isBuy,
        uint64 limitPx,
        uint64 sz,
        bool reduceOnly,
        uint8 encodedTif,
        uint128 cloid
    ) private pure returns (bytes memory) {
        return
            abi.encodePacked(
                uint8(1),
                uint24(HLConstants.LIMIT_ORDER_ACTION),
                abi.encode(asset, isBuy, limitPx, sz, reduceOnly, encodedTif, cloid)
            );
    }

    function testGetHyperliquidBalancesWithAccountValue() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);

        vm.mockCall(
            _accountMarginSummary,
            abi.encode(uint32(0), address(libHarness)),
            abi.encode(
                PrecompileLib.AccountMarginSummary({accountValue: 1_000_000, marginUsed: 0, ntlPos: 0, rawUsd: 0})
            )
        );

        // Mock zero spot USDC balance.
        vm.mockCall(
            _spotBalance,
            abi.encode(address(libHarness), uint64(0)),
            abi.encode(PrecompileLib.SpotBalance({total: 0, hold: 0, entryNtl: 0}))
        );

        AppTokenBalance[] memory balances = libHarness.getHyperliquidBalances(address(libHarness));
        assertEq(balances.length, 1);
        assertEq(balances[0].token, _usdc);
        assertEq(balances[0].amount, 10_000); // 1_000_000 HyperCore wei / 1e2 -> 10_000 EVM USDC
    }

    function testGetHyperliquidBalancesReturnsNegativeNet() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);

        // Perp account value -0.01 USDC Core wei, zero spot -> return -0.01 USDC (EVM 6-dec).
        vm.mockCall(
            _accountMarginSummary,
            abi.encode(uint32(0), address(libHarness)),
            abi.encode(
                PrecompileLib.AccountMarginSummary({accountValue: -1_000_000, marginUsed: 0, ntlPos: 0, rawUsd: 0})
            )
        );

        vm.mockCall(
            _spotBalance,
            abi.encode(address(libHarness), uint64(0)),
            abi.encode(PrecompileLib.SpotBalance({total: 0, hold: 0, entryNtl: 0}))
        );

        AppTokenBalance[] memory balances = libHarness.getHyperliquidBalances(address(libHarness));
        assertEq(balances.length, 1);
        assertEq(balances[0].token, _usdc);
        assertEq(balances[0].amount, -10_000, "Negative net balance should be returned as-is");
    }

    function testGetHyperliquidBalancesNegativePerpOffsetBySpot() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);

        // Perp -0.5 USDC Core wei, spot +1.5 USDC Core wei -> net 1 USDC (EVM 6-dec).
        vm.mockCall(
            _accountMarginSummary,
            abi.encode(uint32(0), address(libHarness)),
            abi.encode(
                PrecompileLib.AccountMarginSummary({accountValue: -50_000_000, marginUsed: 0, ntlPos: 0, rawUsd: 0})
            )
        );

        vm.mockCall(
            _spotBalance,
            abi.encode(address(libHarness), uint64(0)),
            abi.encode(PrecompileLib.SpotBalance({total: 150_000_000, hold: 0, entryNtl: 0}))
        );

        AppTokenBalance[] memory balances = libHarness.getHyperliquidBalances(address(libHarness));
        assertEq(balances.length, 1);
        assertEq(balances[0].token, _usdc);
        assertEq(balances[0].amount, 1_000_000, "Net balance should be 1 USDC (6 dec)");
    }

    function testGetHyperliquidBalancesDustAfterRecentAction() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);

        vm.mockCall(
            _accountMarginSummary,
            abi.encode(uint32(0), address(libHarness)),
            abi.encode(PrecompileLib.AccountMarginSummary({accountValue: 0, marginUsed: 0, ntlPos: 0, rawUsd: 0}))
        );

        vm.mockCall(
            _spotBalance,
            abi.encode(address(libHarness), uint64(0)),
            abi.encode(PrecompileLib.SpotBalance({total: 0, hold: 0, entryNtl: 0}))
        );

        // Before any action, zero account value means no balances.
        AppTokenBalance[] memory balances = libHarness.getHyperliquidBalances(address(libHarness));
        assertEq(balances.length, 0);

        // After recording an action, zero account value returns 1 wei dust to prevent purge.
        libHarness.recordAction(0);
        balances = libHarness.getHyperliquidBalances(address(libHarness));
        assertEq(balances.length, 1);
        assertEq(balances[0].token, _usdc);
        assertEq(balances[0].amount, 1);

        // After advancing one block, the dust is gone and the app can be purged.
        vm.roll(block.number + 1);
        balances = libHarness.getHyperliquidBalances(address(libHarness));
        assertEq(balances.length, 0);
    }
}
