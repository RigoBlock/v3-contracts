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
contract AHyperliquid is IAHyperliquid, IMinimumVersion, ReentrancyGuardTransient {
    using SafeTransferLib for address;
    using ApplicationsLib for ApplicationsSlot;
    using SafeCast for uint256;

    string private constant _REQUIRED_VERSION = "4.4.0";

    /// @dev Offset of the action-specific params within the raw `sendRawAction` payload.
    uint256 private constant _ACTION_PARAMS_OFFSET = 4;

    /// @dev Asset IDs below this threshold are core perp assets.
    uint64 private constant _ASSET_ID_CORE_SPOT_BASE = 10_000;

    /// @dev USDC left in the Core spot account to pay the spot->EVM bridge fee (Core wei).
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
    function deposit(uint256 amount, uint32 destinationDex) external override nonReentrant onlyDelegateCall {
        _bridgeUsdcToCore(address(this), amount, destinationDex);
    }

    /// @inheritdoc ICoreDepositWallet
    function depositFor(
        address recipient,
        uint256 amount,
        uint32 destinationDex
    ) external override nonReentrant onlyDelegateCall {
        require(recipient == address(this), InvalidActionData());
        _bridgeUsdcToCore(recipient, amount, destinationDex);
    }

    /// @inheritdoc ICoreWriter
    function sendRawAction(bytes calldata data) external override nonReentrant onlyDelegateCall {
        require(data.length >= 4, InvalidActionData());
        require(uint8(data[0]) == 1, InvalidActionData());
        require(PrecompileLib.coreUserExists(address(this)), AccountNotActivated());

        uint24 actionId = uint24(bytes3(data[1:4]));
        bytes calldata params = data[_ACTION_PARAMS_OFFSET:];

        if (actionId == HLConstants.LIMIT_ORDER_ACTION) {
            _placeLimitOrder(params);
        } else if (actionId == HLConstants.SPOT_SEND_ACTION) {
            _spotSend(params);
        } else if (actionId == HLConstants.USD_CLASS_TRANSFER_ACTION) {
            _transferUsdClass(params);
        } else if (actionId == HLConstants.CANCEL_ORDER_BY_OID_ACTION) {
            _cancelOrderByOid(params);
        } else if (actionId == HLConstants.CANCEL_ORDER_BY_CLOID_ACTION) {
            _cancelOrderByCloid(params);
        } else {
            revert UnsupportedAction(actionId);
        }

        HyperliquidLib.recordAction(0);
        emit ActionSent(actionId);
    }

    function _bridgeUsdcToCore(address recipient, uint256 amount, uint32 destinationDex) private {
        require(amount > 0, InvalidAmount());
        require(destinationDex == HLConstants.DEFAULT_PERP_DEX, InvalidDex());

        CoreWriterLib.bridgeUsdcToCoreFor(recipient, amount, destinationDex);

        address usdc = HLConstants.usdc();
        address depositWallet = HLConstants.coreDepositWallet();
        if (IERC20(usdc).allowance(address(this), depositWallet) > 1) {
            usdc.safeApprove(depositWallet, 1);
        }

        StorageLib.activeApplications().storeApplication(uint256(Applications.HYPERLIQUID));
        HyperliquidLib.recordAction(amount.toInt256());
    }

    function _placeLimitOrder(bytes calldata params) private {
        (uint32 asset, bool isBuy, uint64 limitPx, uint64 sz, bool reduceOnly, uint8 encodedTif, uint128 cloid) = abi
            .decode(params, (uint32, bool, uint64, uint64, bool, uint8, uint128));

        require(sz > 0, InvalidAmount());
        _requireCorePerpAsset(asset);

        CoreWriterLib.placeLimitOrder(asset, isBuy, limitPx, sz, reduceOnly, encodedTif, cloid);
    }

    function _spotSend(bytes calldata params) private {
        (address destinationAddress, uint64 token, uint64 amount) = abi.decode(params, (address, uint64, uint64));

        require(amount > 0, InvalidAmount());
        require(token == HLConstants.USDC_TOKEN_INDEX, InvalidActionData());
        require(destinationAddress == CoreWriterLib.getSystemAddress(token), InvalidActionData());

        uint64 pendingSpotSend = HyperliquidLib.recordSpotSend(amount);
        uint64 spotTotal = PrecompileLib.spotBalance(address(this), token).total;
        require(spotTotal >= amount + pendingSpotSend + _BRIDGE_GAS_RESERVE, InsufficientBridgeReserve());

        HyperliquidLib.recordAction(-SafeCast.toInt256(HLConversions.weiToEvm(token, amount)));
        CoreWriterLib.spotSend(destinationAddress, token, amount);
    }

    function _transferUsdClass(bytes calldata params) private {
        (uint64 ntl, bool toPerp) = abi.decode(params, (uint64, bool));
        require(ntl > 0, InvalidAmount());
        CoreWriterLib.transferUsdClass(ntl, toPerp);
    }

    function _cancelOrderByOid(bytes calldata params) private {
        (uint32 asset, uint64 orderId) = abi.decode(params, (uint32, uint64));
        _requireCorePerpAsset(asset);
        CoreWriterLib.cancelOrderByOrderId(asset, orderId);
    }

    function _cancelOrderByCloid(bytes calldata params) private {
        (uint32 asset, uint128 cloid) = abi.decode(params, (uint32, uint128));
        _requireCorePerpAsset(asset);
        CoreWriterLib.cancelOrderByCloid(asset, cloid);
    }

    function _requireCorePerpAsset(uint32 asset) private pure {
        require(asset < _ASSET_ID_CORE_SPOT_BASE, InvalidActionData());
    }
}
