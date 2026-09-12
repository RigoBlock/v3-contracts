// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AHyperliquid} from "../../contracts/protocol/extensions/adapters/AHyperliquid.sol";
import {IAHyperliquid} from "../../contracts/protocol/extensions/adapters/interfaces/IAHyperliquid.sol";
import {HyperliquidLib} from "../../contracts/protocol/libraries/HyperliquidLib.sol";
import {StorageLib} from "../../contracts/protocol/libraries/StorageLib.sol";
import {NavView} from "../../contracts/protocol/libraries/NavView.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";
import {HLConstants} from "hyper-evm-lib/common/HLConstants.sol";
import {PrecompileLib} from "hyper-evm-lib/PrecompileLib.sol";
import {CoreWriterLib} from "hyper-evm-lib/CoreWriterLib.sol";
import {Applications} from "../../contracts/protocol/types/Applications.sol";
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

    function assertNavUnlocked() external view {
        HyperliquidLib.assertNavUnlocked();
    }

    function recordAction(int256 amount) external {
        HyperliquidLib.recordAction(amount, false);
    }

    function recordSpotSend(uint64 amount) external returns (uint64 pendingBefore) {
        return HyperliquidLib.recordAction(int256(uint256(amount)), true);
    }

    /// @notice Returns the raw lastActionCompositeBlock to assert the composite packing.
    function lastActionCompositeBlock() external view returns (uint256) {
        return uint256(StorageLib.hyperliquidData().lastActionCompositeBlock);
    }
}

/// @notice Exposes NavView internal library function for coverage testing.
contract NavViewHarness {
    function getAppTokenBalances(
        address pool,
        address grgStakingProxy,
        address uniV4Posm
    ) external view returns (AppTokenBalance[] memory) {
        return NavView.getAppTokenBalances(pool, grgStakingProxy, uniV4Posm);
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

    // Current value mocked for the HyperCore L1 block number precompile. In-flight tracking and the
    // settlement lock are keyed to the L1 block, so tests advance this value to simulate a new
    // HyperCore block (HyperEVM learns about HyperCore state changes only when the L1 block advances).
    uint64 private _l1Block;

    // Hyperliquid system and precompile addresses are sourced from hyper-evm-lib and Constants.
    address private immutable _usdc = Constants.HYPER_USDC;
    address private immutable _coreWriter = address(CoreWriterLib.coreWriter);
    address private immutable _coreDepositWallet = HLConstants.CORE_DEPOSIT_WALLET;
    address private immutable _tokenInfo = HLConstants.TOKEN_INFO_PRECOMPILE_ADDRESS;
    address private immutable _spotBalance = HLConstants.SPOT_BALANCE_PRECOMPILE_ADDRESS;
    address private immutable _accountMarginSummary = HLConstants.ACCOUNT_MARGIN_SUMMARY_PRECOMPILE_ADDRESS;
    address private immutable _coreUserExists = HLConstants.CORE_USER_EXISTS_PRECOMPILE_ADDRESS;
    address private immutable _l1BlockNumber = HLConstants.L1_BLOCK_NUMBER_PRECOMPILE_ADDRESS;

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

        // Mock the L1 block number precompile so L1-keyed in-flight tracking can run.
        _l1Block = uint64(block.number);
        _mockL1BlockNumber(_l1Block);
    }

    function _mockL1BlockNumber(uint64 l1Block) private {
        vm.mockCall(_l1BlockNumber, abi.encode(), abi.encode(l1Block));
    }

    /// @dev Simulates a new HyperCore block: the L1 block number precompile advances and the EVM
    ///  block rolls forward. State precompiles only reflect HyperCore state from this point on.
    function _advanceL1Block() private {
        unchecked {
            _l1Block += 1;
        }
        vm.roll(block.number + 1);
        _mockL1BlockNumber(_l1Block);
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

    function _mockAccountMarginSummary(address account, int64 accountValue) private {
        vm.mockCall(
            _accountMarginSummary,
            abi.encode(uint32(0), account),
            abi.encode(
                PrecompileLib.AccountMarginSummary({accountValue: accountValue, marginUsed: 0, ntlPos: 0, rawUsd: 0})
            )
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
            abi.encode(uint64(100e6), false)
        );
        IAHyperliquid(address(pool)).sendRawAction(data);

        MockCoreWriter coreWriter = MockCoreWriter(_coreWriter);
        bytes memory actionData = coreWriter.lastActionData();

        assertEq(uint8(actionData[0]), 1);
        assertEq(uint24(bytes3(BytesSlice.slice(actionData, 1, 3))), HLConstants.USD_CLASS_TRANSFER_ACTION);

        (uint64 ntl, bool toPerp) = abi.decode(BytesSlice.slice(actionData, 4, actionData.length - 4), (uint64, bool));
        assertEq(ntl, 100e6);
        assertFalse(toPerp);
    }

    function testSendRawActionUsdClassTransferToPerpReverts() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);

        bytes memory data = abi.encodePacked(
            uint8(1),
            uint24(HLConstants.USD_CLASS_TRANSFER_ACTION),
            abi.encode(uint64(100e6), true)
        );
        vm.expectRevert(IAHyperliquid.InvalidActionData.selector);
        IAHyperliquid(address(pool)).sendRawAction(data);
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

        // Perp account value is already in 6-decimal USDC: 1_000_000 = 1 USDC.
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
        assertEq(balances[0].amount, 1_000_000); // 1 USDC (6 dec)
    }

    function testGetHyperliquidBalancesReturnsNegativeNet() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);

        // Perp account value -1 USDC (6 dec), zero spot -> return -1 USDC.
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
        assertEq(balances[0].amount, -1_000_000, "Negative net balance should be returned as-is");
    }

    function testGetHyperliquidBalancesNegativePerpOffsetBySpot() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);

        // Perp -0.5 USDC (6 dec), spot +1.5 USDC (8-dec wei) -> net 1 USDC (6 dec).
        vm.mockCall(
            _accountMarginSummary,
            abi.encode(uint32(0), address(libHarness)),
            abi.encode(
                PrecompileLib.AccountMarginSummary({accountValue: -500_000, marginUsed: 0, ntlPos: 0, rawUsd: 0})
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

        // Mock no HyperCore account for the harness so a zero balance is treated as inactive.
        _mockCoreUserExists(address(libHarness), false);

        // Before any action, zero account value means no balances.
        AppTokenBalance[] memory balances = libHarness.getHyperliquidBalances(address(libHarness));
        assertEq(balances.length, 0);

        // Recording an action in the same EVM block keeps the lock open: the in-flight dust keeps the
        // app active and share issuance is not blocked while the Core-side view is unchanged.
        libHarness.recordAction(0);
        libHarness.assertNavUnlocked();
        balances = libHarness.getHyperliquidBalances(address(libHarness));
        assertEq(balances.length, 1);
        assertEq(balances[0].amount, 1);

        // From the next EVM block on, the 16-second settlement lock applies until the window elapses,
        // even if the L1 block is unchanged.
        _advanceL1Block();
        vm.expectRevert(HyperliquidLib.NavLocked.selector);
        libHarness.assertNavUnlocked();

        // After the window elapses, the in-flight dust is reset and the app can be purged because
        // the HyperCore account does not exist.
        vm.warp(block.timestamp + 17 seconds);
        libHarness.assertNavUnlocked();
        balances = libHarness.getHyperliquidBalances(address(libHarness));
        assertEq(balances.length, 0);
    }

    function testGetHyperliquidBalancesDustWhenAccountExists() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);

        _mockAccountMarginSummary(address(libHarness), 0);
        _mockSpotBalance(address(libHarness), HLConstants.USDC_TOKEN_INDEX, 0);
        _mockCoreUserExists(address(libHarness), true);

        // Even with zero net value and no recent action, an existing HyperCore account keeps the
        // app active so that live positions/funding are not dropped from NAV.
        AppTokenBalance[] memory balances = libHarness.getHyperliquidBalances(address(libHarness));
        assertEq(balances.length, 1);
        assertEq(balances[0].token, _usdc);
        assertEq(balances[0].amount, 1);
    }

    function testSendRawActionCancelOrderByOid() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);

        bytes memory data = abi.encodePacked(
            uint8(1),
            uint24(HLConstants.CANCEL_ORDER_BY_OID_ACTION),
            abi.encode(uint32(1), uint64(123))
        );

        vm.expectEmit(true, false, false, false, address(pool));
        emit IAHyperliquid.ActionSent(HLConstants.CANCEL_ORDER_BY_OID_ACTION);
        IAHyperliquid(address(pool)).sendRawAction(data);

        MockCoreWriter coreWriter = MockCoreWriter(_coreWriter);
        bytes memory actionData = coreWriter.lastActionData();
        assertEq(uint8(actionData[0]), 1);
        assertEq(uint24(bytes3(BytesSlice.slice(actionData, 1, 3))), HLConstants.CANCEL_ORDER_BY_OID_ACTION);

        (uint32 asset, uint64 orderId) = abi.decode(
            BytesSlice.slice(actionData, 4, actionData.length - 4),
            (uint32, uint64)
        );
        assertEq(asset, 1);
        assertEq(orderId, 123);
    }

    function testSendRawActionCancelOrderByCloid() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);

        bytes memory data = abi.encodePacked(
            uint8(1),
            uint24(HLConstants.CANCEL_ORDER_BY_CLOID_ACTION),
            abi.encode(uint32(2), uint128(456))
        );

        vm.expectEmit(true, false, false, false, address(pool));
        emit IAHyperliquid.ActionSent(HLConstants.CANCEL_ORDER_BY_CLOID_ACTION);
        IAHyperliquid(address(pool)).sendRawAction(data);

        MockCoreWriter coreWriter = MockCoreWriter(_coreWriter);
        bytes memory actionData = coreWriter.lastActionData();
        assertEq(uint24(bytes3(BytesSlice.slice(actionData, 1, 3))), HLConstants.CANCEL_ORDER_BY_CLOID_ACTION);

        (uint32 asset, uint128 cloid) = abi.decode(
            BytesSlice.slice(actionData, 4, actionData.length - 4),
            (uint32, uint128)
        );
        assertEq(asset, 2);
        assertEq(cloid, 456);
    }

    function testSendRawActionSpotSendCumulativeBoundsSameBlock() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);

        uint64 amountWei = 100e6 * 1e2; // 6-decimal USDC scaled to 8-decimal Core wei
        address systemAddress = CoreWriterLib.getSystemAddress(HLConstants.USDC_TOKEN_INDEX);

        // Mock a spot balance that can cover two full sends plus the bridge reserve, but not three.
        _mockSpotBalance(address(pool), HLConstants.USDC_TOKEN_INDEX, 2 * amountWei + _BRIDGE_GAS_RESERVE());

        bytes memory data = abi.encodePacked(
            uint8(1),
            uint24(HLConstants.SPOT_SEND_ACTION),
            abi.encode(systemAddress, HLConstants.USDC_TOKEN_INDEX, amountWei)
        );

        IAHyperliquid(address(pool)).sendRawAction(data);
        IAHyperliquid(address(pool)).sendRawAction(data);

        // Third send in the same EVM block must revert because the cumulative pending amount exceeds the
        // available spot balance once the reserve is accounted for.
        vm.expectRevert(IAHyperliquid.InsufficientBridgeReserve.selector);
        IAHyperliquid(address(pool)).sendRawAction(data);

        // The cumulative counter resets at the next EVM block (HyperCore processes the queued sends
        // and the precompile view catches up), so a fresh send succeeds.
        _advanceL1Block();
        _mockSpotBalance(address(pool), HLConstants.USDC_TOKEN_INDEX, amountWei + _BRIDGE_GAS_RESERVE());
        IAHyperliquid(address(pool)).sendRawAction(data);
    }

    function testNavViewHyperliquidBranch() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);

        NavViewHarness navHarness = new NavViewHarness();

        // Mock the pool to report Hyperliquid as the only active application.
        uint256 packedApps = 1 << uint256(Applications.HYPERLIQUID);
        vm.mockCall(
            address(pool),
            abi.encodeWithSelector(ISmartPoolState.getActiveApplications.selector),
            abi.encode(packedApps)
        );

        // NavView always queries GRG_STAKING; mock a zero stake to avoid reverting on address(0).
        address grgStakingProxy = address(0x123);
        vm.mockCall(
            grgStakingProxy,
            abi.encodeWithSelector(IStaking.getTotalStake.selector, address(pool)),
            abi.encode(uint256(0))
        );

        // Mock a non-zero HyperCore perp account value (6-dec USDC) so the Hyperliquid branch produces a balance.
        _mockAccountMarginSummary(address(pool), 1_000_000);
        _mockSpotBalance(address(pool), HLConstants.USDC_TOKEN_INDEX, 0);
        _mockCoreUserExists(address(pool), true);

        AppTokenBalance[] memory balances = navHarness.getAppTokenBalances(address(pool), grgStakingProxy, address(0));
        assertEq(balances.length, 1);
        assertEq(balances[0].token, _usdc);
        assertEq(balances[0].amount, 1_000_000);
    }

    /// @notice A spot-send withdrawal request does not deflate the Hyperliquid balance: no in-flight
    ///  subtraction is applied, because the request only queues the action and its destination is the
    ///  pool's own address (NAV-neutral at every stage). Within the same EVM block the lock stays open;
    ///  from the next L1 block the settlement time lock applies until the Core debit and EVM credit
    ///  have both landed; balance views keep working throughout.
    function testSpotSendWithdrawalDoesNotChangeNavAfterWindow() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);

        HyperliquidLibHarness harness = new HyperliquidLibHarness();
        uint64 spotAmountWei = 200e6 * 1e2;

        // HyperCore holds 200 USDC for the pool; zero perp account value.
        _mockAccountMarginSummary(address(harness), 0);
        _mockSpotBalance(address(harness), HLConstants.USDC_TOKEN_INDEX, spotAmountWei);
        _mockCoreUserExists(address(harness), true);

        AppTokenBalance[] memory balances = harness.getHyperliquidBalances(address(harness));
        assertEq(balances.length, 1);
        int256 appBalanceBefore = balances[0].amount;
        assertEq(appBalanceBefore, 200e6);

        // Record the spot-send action: the same EVM block stays unlocked (nothing has moved yet and
        // the transfer is NAV-neutral), and the balance view does not subtract the pending send.
        harness.recordSpotSend(50e6 * 1e2);
        harness.assertNavUnlocked();

        // The balance view still reports the raw Core balance, which does not subtract the pending send.
        balances = harness.getHyperliquidBalances(address(harness));
        assertEq(balances.length, 1);
        assertEq(balances[0].amount, appBalanceBefore, "Spot-send request must not deflate NAV");

        // From the next L1 block on, the time lock keeps share issuance/redemption reverting.
        _advanceL1Block();
        vm.expectRevert(HyperliquidLib.NavLocked.selector);
        harness.assertNavUnlocked();

        // After the window elapses the balance is still the unchanged Core balance.
        vm.warp(block.timestamp + 17 seconds);
        harness.assertNavUnlocked();
        balances = harness.getHyperliquidBalances(address(harness));
        assertEq(balances.length, 1);
        assertEq(balances[0].amount, appBalanceBefore, "Spot-send request must not deflate NAV");
    }

    /// @notice `assertNavUnlocked` allows same-EVM-block actions after a recorded deposit and reverts
    ///  with `NavLocked()` from the next EVM block until the 16-second window has elapsed.
    function testAssertNavUnlockedSettlementWindow() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);
        HyperliquidLibHarness harness = new HyperliquidLibHarness();

        _mockAccountMarginSummary(address(harness), 0);
        _mockSpotBalance(address(harness), HLConstants.USDC_TOKEN_INDEX, 0);
        _mockCoreUserExists(address(harness), true);

        // No action recorded yet: unlocked.
        harness.assertNavUnlocked();

        // Record a deposit: the same EVM block stays unlocked (in-flight applies).
        harness.recordAction(100e6);
        harness.assertNavUnlocked();

        // From the next EVM block on, within the window, share issuance/redemption must revert.
        _advanceL1Block();
        vm.expectRevert(HyperliquidLib.NavLocked.selector);
        harness.assertNavUnlocked();

        // Warp just past the 16-second window; unlocked again.
        vm.warp(block.timestamp + 17 seconds);
        harness.assertNavUnlocked();
    }

    /// @notice The in-flight amount applies only within the same EVM block as the recorded action and
    ///  is dropped at the next EVM block — HyperCore processes EVM->Core transfers and CoreWriter
    ///  actions right after each EVM block is built, so the precompile view can already reflect the
    ///  deposit in the next block; keeping the add-back any longer would double-count.
    function testInFlightAppliesOnlyInSameEvmBlock() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);

        HyperliquidLibHarness harness = new HyperliquidLibHarness();

        // HyperCore does not reflect the deposit yet.
        _mockAccountMarginSummary(address(harness), 0);
        _mockSpotBalance(address(harness), HLConstants.USDC_TOKEN_INDEX, 0);
        _mockCoreUserExists(address(harness), true);

        int256 depositAmount = 100e6;
        harness.recordAction(depositAmount);

        // Same EVM block: in-flight applies, lock stays open.
        harness.assertNavUnlocked();
        AppTokenBalance[] memory balances = harness.getHyperliquidBalances(address(harness));
        assertEq(balances[0].amount, depositAmount, "In-flight amount must apply in the same EVM block");

        // Next EVM block (same L1 block): in-flight is dropped — the precompile is expected to
        // reflect the deposit by now — and the time lock takes over.
        vm.roll(block.number + 1);
        vm.expectRevert(HyperliquidLib.NavLocked.selector);
        harness.assertNavUnlocked();
        balances = harness.getHyperliquidBalances(address(harness));
        assertEq(balances[0].amount, 1, "In-flight amount must be dropped at the next EVM block");
    }

    /// @notice The composite block packing identifies the current EVM block and HyperCore block
    ///  together: high 128 bits = HyperCore L1 block number, low 128 bits = EVM block number. The
    ///  full composite is the comparison key for in-flight expiry.
    function testCompositeBlockPacking() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);

        HyperliquidLibHarness harness = new HyperliquidLibHarness();

        harness.recordAction(100e6);
        uint256 composite = harness.lastActionCompositeBlock();
        assertEq(composite >> 128, uint256(_l1Block), "High bits must hold the L1 block number");
        assertEq(uint128(composite), uint128(block.number), "Low bits must hold the EVM block number");

        // The L1 block advances: a new action repacks the composite with the new L1 block and the
        // current EVM block.
        _advanceL1Block();
        harness.recordAction(50e6);
        composite = harness.lastActionCompositeBlock();
        assertEq(composite >> 128, uint256(_l1Block), "High bits must track the advanced L1 block");
        assertEq(uint128(composite), uint128(block.number), "Low bits must track the current EVM block");
    }

    /// @notice Recording a new action within the window re-arms the 16-second settlement lock.
    function testRecordActionReArmsSettlementWindow() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);

        libHarness.recordAction(0);
        _advanceL1Block();
        vm.warp(block.timestamp + 10 seconds);

        // Still locked 10 seconds in; a new action re-arms the window from the new timestamp.
        vm.expectRevert(HyperliquidLib.NavLocked.selector);
        libHarness.assertNavUnlocked();
        libHarness.recordAction(0);

        // Same EVM block as the new action: unlocked. Next EVM block within 16s of the new action: locked again.
        libHarness.assertNavUnlocked();
        _advanceL1Block();
        vm.expectRevert(HyperliquidLib.NavLocked.selector);
        libHarness.assertNavUnlocked();

        vm.warp(block.timestamp + 17 seconds);
        libHarness.assertNavUnlocked();
    }

    /// @notice `recordAction` with `isSpotSend=true` accumulates pending amounts within the same EVM
    ///  block, and resets them at the next EVM block (HyperCore processes actions right after each
    ///  EVM block is built, so the precompile view catches up).
    function testRecordSpotSendCumulativeSameBlock() public {
        vm.chainId(Constants.HYPEREVM_CHAIN_ID);

        uint64 amount = 100e6 * 1e2;
        uint64 pending1 = libHarness.recordSpotSend(amount);
        assertEq(pending1, 0, "First spot-send should have zero prior pending amount");

        // A second request in the SAME EVM block still sees the pending amount.
        uint64 pending2 = libHarness.recordSpotSend(amount);
        assertEq(pending2, amount, "Second spot-send in the same block should see the first amount as pending");

        // The pending counter resets at the next EVM block.
        _advanceL1Block();
        uint64 pending3 = libHarness.recordSpotSend(amount);
        assertEq(pending3, 0, "Pending amount must reset at the next EVM block");
    }

    function _BRIDGE_GAS_RESERVE() private pure returns (uint64) {
        return 1e7;
    }
}
