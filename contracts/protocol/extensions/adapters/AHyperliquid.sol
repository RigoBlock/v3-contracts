// SPDX-License-Identifier: Apache-2.0-or-later
// solhint-disable-next-line
pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin-legacy/contracts/utils/math/SafeCast.sol";
import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";
import {ReentrancyGuardTransient} from "../../libraries/ReentrancyGuardTransient.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {ApplicationsLib, ApplicationsSlot} from "../../libraries/ApplicationsLib.sol";
import {StorageLib} from "../../libraries/StorageLib.sol";
import {HyperliquidLib} from "../../libraries/HyperliquidLib.sol";
import {Applications} from "../../types/Applications.sol";
import {HLConstants} from "hyper-evm-lib/common/HLConstants.sol";
import {HLConversions} from "hyper-evm-lib/common/HLConversions.sol";
import {CoreWriterLib} from "hyper-evm-lib/CoreWriterLib.sol";
import {PrecompileLib} from "hyper-evm-lib/PrecompileLib.sol";
import {ICoreWriter} from "hyper-evm-lib/interfaces/ICoreWriter.sol";
import {ICoreDepositWallet} from "hyper-evm-lib/interfaces/ICoreDepositWallet.sol";
import {IAHyperliquid} from "./interfaces/IAHyperliquid.sol";
import {IMinimumVersion} from "./interfaces/IMinimumVersion.sol";

/// @title AHyperliquid - Facilitates smart pool interaction with Hyperliquid Core.
/// @custom:security-contact security@rigoblock.com
/// @notice Exposes the canonical Hyperliquid CoreWriter and CoreDepositWallet interfaces
///  to Rigoblock smart pools. The adapter runs via delegatecall in the pool context.
/// @dev The pool interacts with Hyperliquid as a USDC-only perps account. Deposits are routed
///  straight to the Core perp dex. Withdrawals are operator-driven and necessarily touch the
///  Core spot account: funds must first be moved from perp margin to spot via
///  `USD_CLASS_TRANSFER(toPerp=false)`, then bridged to HyperEVM via `SPOT_SEND`. The adapter
///  rejects non-core-perp assets and any action that would introduce tokens other than USDC.
contract AHyperliquid is IAHyperliquid, IMinimumVersion, ReentrancyGuardTransient {
    using SafeTransferLib for address;
    using ApplicationsLib for ApplicationsSlot;
    using SafeCast for uint256;

    string private constant _REQUIRED_VERSION = "4.8.0";

    /// @dev Asset IDs below this threshold are core perp assets.
    uint64 private constant _ASSET_ID_CORE_SPOT_BASE = 10_000;

    /// @dev USDC left in the Core spot account to pay the spot->EVM bridge fee.
    ///  Mirrors dHEDGE's 0.1 USDC reserve (Core wei, 8 decimals for USDC).
    uint64 private constant _BRIDGE_GAS_RESERVE = 1e7;

    address private immutable _adapter;

    constructor() {
        require(block.chainid == HyperliquidLib.HYPEREVM_CHAIN_ID, NotHyperEVM());
        _adapter = address(this);
    }

    modifier onlyDelegateCall() {
        require(address(this) != _adapter, DirectCallNotAllowed());
        _;
    }

    /// @inheritdoc IMinimumVersion
    function requiredVersion() external pure override returns (string memory) {
        return _REQUIRED_VERSION;
    }

    /// @inheritdoc ICoreDepositWallet
    /// @notice Bridges USDC from the pool's HyperEVM balance into HyperCore.
    /// @param amount Amount of USDC to deposit (EVM 6 decimals).
    /// @param destinationDex Must be the core perp dex (0). Spot deposits are not supported.
    function deposit(uint256 amount, uint32 destinationDex) external override nonReentrant onlyDelegateCall {
        _bridgeUsdcToCore(address(this), amount, destinationDex);
    }

    /// @inheritdoc ICoreDepositWallet
    /// @notice Bridges USDC from the pool's HyperEVM balance into HyperCore on behalf of the pool.
    /// @param recipient Must be the pool itself, since the pool is the vault and the actor on HyperCore.
    /// @param amount Amount of USDC to deposit (EVM 6 decimals).
    /// @param destinationDex Must be the core perp dex (0). Spot deposits are not supported.
    function depositFor(
        address recipient,
        uint256 amount,
        uint32 destinationDex
    ) external override nonReentrant onlyDelegateCall {
        require(recipient == address(this), InvalidActionData());
        _bridgeUsdcToCore(recipient, amount, destinationDex);
    }

    /// @dev Common USDC bridging logic via CoreWriterLib.
    function _bridgeUsdcToCore(address recipient, uint256 amount, uint32 destinationDex) private {
        require(amount > 0, InvalidAmount());
        require(destinationDex == HLConstants.DEFAULT_PERP_DEX, InvalidDex());

        CoreWriterLib.bridgeUsdcToCoreFor(recipient, amount, destinationDex);

        // CoreWriterLib approves the exact amount. Reset to 1 to keep the ERC20 allowance slot warm.
        address usdc = HLConstants.usdc();
        address depositWallet = HLConstants.coreDepositWallet();
        if (IERC20(usdc).allowance(address(this), depositWallet) > 1) {
            usdc.safeApprove(depositWallet, 1);
        }

        StorageLib.activeApplications().storeApplication(uint256(Applications.HYPERLIQUID));
        HyperliquidLib.recordAction(amount.toInt256());
    }

    /// @inheritdoc ICoreWriter
    /// @notice Submits a raw HyperCore action after validation.
    /// @dev The raw bytes are decoded and routed through hyper-evm-lib typed helpers, which encode
    ///  the action exactly as CoreWriter expects. This keeps the canonical `sendRawAction(bytes)`
    ///  entry point while avoiding manual re-implementation of the wire format.
    /// @param data Raw action bytes: `<1-byte version=1><3-byte actionId><abi-encoded params>`.
    function sendRawAction(bytes calldata data) external override nonReentrant onlyDelegateCall {
        require(data.length >= 4, InvalidActionData());
        require(uint8(data[0]) == 1, InvalidActionData());

        // CoreWriter silently drops actions when the pool's HyperCore account does not yet exist.
        // Deposits are exempt because they create the account; all other actions require it.
        require(PrecompileLib.coreUserExists(address(this)), AccountNotActivated());

        uint24 actionId = uint24(bytes3(data[1:4]));

        if (actionId == HLConstants.LIMIT_ORDER_ACTION) {
            _placeLimitOrder(data);
        } else if (actionId == HLConstants.SPOT_SEND_ACTION) {
            _spotSend(data);
        } else if (actionId == HLConstants.USD_CLASS_TRANSFER_ACTION) {
            _transferUsdClass(data);
        } else if (actionId == HLConstants.CANCEL_ORDER_BY_OID_ACTION) {
            _cancelOrderByOid(data);
        } else if (actionId == HLConstants.CANCEL_ORDER_BY_CLOID_ACTION) {
            _cancelOrderByCloid(data);
        } else {
            revert UnsupportedAction(actionId);
        }

        // Record the action so the application is not purged during the one-block settlement gap.
        HyperliquidLib.recordAction(0);
    }

    /// @dev Decodes a LIMIT_ORDER action and routes through CoreWriterLib.placeLimitOrder.
    function _placeLimitOrder(bytes calldata data) private {
        (uint32 asset, bool isBuy, uint64 limitPx, uint64 sz, bool reduceOnly, uint8 encodedTif, uint128 cloid) = abi
            .decode(data[4:], (uint32, bool, uint64, uint64, bool, uint8, uint128));

        require(sz > 0, InvalidAmount());
        _requireCorePerpAsset(asset);

        CoreWriterLib.placeLimitOrder(asset, isBuy, limitPx, sz, reduceOnly, encodedTif, cloid);
    }

    /// @dev Decodes a SPOT_SEND action, restricts it to USDC bridging from Core spot back to the
    ///  pool's HyperEVM balance, and routes through CoreWriterLib.spotSend. This is the second step
    ///  of a withdrawal: funds must already be in the Core spot account (moved there by a prior
    ///  USD_CLASS_TRANSFER with toPerp=false), because CoreWriter has no direct perp-to-EVM bridge.
    function _spotSend(bytes calldata data) private {
        (address destinationAddress, uint64 token, uint64 amount) = abi.decode(data[4:], (address, uint64, uint64));

        require(amount > 0, InvalidAmount());
        require(token == HLConstants.USDC_TOKEN_INDEX, InvalidActionData());
        require(destinationAddress == CoreWriterLib.getSystemAddress(token), InvalidActionData());

        // Keep a USDC buffer in the Core spot account for the bridge fee. HyperCore silently drops
        // spot->EVM bridges that leave the account unable to pay the fee.
        uint64 spotTotal = PrecompileLib.spotBalance(address(this), token).total;
        require(spotTotal >= amount + _BRIDGE_GAS_RESERVE, InsufficientBridgeReserve());

        // Track USDC withdrawals from HyperCore so NAV is not understated during the settlement gap.
        HyperliquidLib.recordAction(-SafeCast.toInt256(HLConversions.weiToEvm(token, amount)));

        CoreWriterLib.spotSend(destinationAddress, token, amount);
    }

    /// @dev Decodes a USD_CLASS_TRANSFER action and routes through CoreWriterLib.transferUsdClass.
    ///  This is the first step of a withdrawal: move USDC from Core perp margin to Core spot
    ///  (toPerp=false) before calling SPOT_SEND. Deposits do not need this step.
    function _transferUsdClass(bytes calldata data) private {
        (uint64 ntl, bool toPerp) = abi.decode(data[4:], (uint64, bool));
        require(ntl > 0, InvalidAmount());
        CoreWriterLib.transferUsdClass(ntl, toPerp);
    }

    /// @dev Decodes an OID cancel action and routes through CoreWriterLib.cancelOrderByOrderId.
    function _cancelOrderByOid(bytes calldata data) private {
        (uint32 asset, uint64 orderId) = abi.decode(data[4:], (uint32, uint64));
        _requireCorePerpAsset(asset);
        CoreWriterLib.cancelOrderByOrderId(asset, orderId);
    }

    /// @dev Decodes a CLOID cancel action and routes through CoreWriterLib.cancelOrderByCloid.
    function _cancelOrderByCloid(bytes calldata data) private {
        (uint32 asset, uint128 cloid) = abi.decode(data[4:], (uint32, uint128));
        _requireCorePerpAsset(asset);
        CoreWriterLib.cancelOrderByCloid(asset, cloid);
    }

    /// @dev Rejects spot and any non-core-perp asset IDs.
    ///  Only core perp assets (< 10_000) are supported because the pool is USDC-only and has no
    ///  on-chain price feed for spot markets.
    function _requireCorePerpAsset(uint32 asset) private pure {
        require(asset < _ASSET_ID_CORE_SPOT_BASE, InvalidActionData());
    }
}
