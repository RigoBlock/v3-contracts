// SPDX-License-Identifier: Apache-2.0-or-later
// solhint-disable-next-line
pragma solidity 0.8.28;

import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";
import {ReentrancyGuardTransient} from "../../libraries/ReentrancyGuardTransient.sol";
import {ApplicationsLib, ApplicationsSlot} from "../../libraries/ApplicationsLib.sol";
import {StorageLib} from "../../libraries/StorageLib.sol";
import {HyperliquidLib} from "../../libraries/HyperliquidLib.sol";
import {Applications} from "../../types/Applications.sol";
import {ICoreWriter} from "../../../utils/exchanges/hyperliquid/ICoreWriter.sol";
import {ICoreDepositWallet} from "../../../utils/exchanges/hyperliquid/ICoreDepositWallet.sol";
import {IAHyperliquid} from "./interfaces/IAHyperliquid.sol";
import {IMinimumVersion} from "./interfaces/IMinimumVersion.sol";

/// @title AHyperliquid - Facilitates smart pool interaction with Hyperliquid Core perps and HIP-4 outcome markets.
/// @custom:security-contact security@rigoblock.com
/// @notice Perps and HIP-4 prediction-market integration on HyperEVM. The adapter runs via delegatecall in the pool context.
/// @dev Guard-style validations (slippage, allowed dex, allowed assets) live here because Rigoblock has no
///  dHEDGE-style contract-guard registry.
contract AHyperliquid is IAHyperliquid, IMinimumVersion, ReentrancyGuardTransient {
    using SafeTransferLib for address;
    using ApplicationsLib for ApplicationsSlot;

    string private constant _REQUIRED_VERSION = "4.5.0";

    uint256 private constant _BPS_BASE = 10_000;
    /// @notice Maximum 1% slippage for IOC orders against the Hyperliquid oracle/spot precompile.
    uint256 private constant _MAX_SLIPPAGE_BPS = 100;

    /// @notice Minimum notional for a HIP-4 order: 10 USDC in HyperCore 8-decimal units.
    uint256 private constant _MIN_HIP4_NOTIONAL = 10 * 1e8;

    /// @notice USDC is 6 decimals on HyperEVM but 8 decimals on HyperCore. Encoding a `spotSend`
    ///  action back to HyperEVM requires scaling the amount by 100 to match the HyperCore `wei` format.
    uint256 private constant _USDC_HYPERCORE_DECIMALS = 1e2;

    uint8 private constant _TIF_GTC = 2;
    uint8 private constant _TIF_IOC = 3;

    address private immutable _aHyperliquid;

    constructor() {
        require(block.chainid == HyperliquidLib.HYPEREVM_CHAIN_ID, NotHyperEVM());
        _aHyperliquid = address(this);
    }

    modifier onlyDelegateCall() {
        require(address(this) != _aHyperliquid, DirectCallNotAllowed());
        _;
    }

    /// @inheritdoc IMinimumVersion
    function requiredVersion() external pure override returns (string memory) {
        return _REQUIRED_VERSION;
    }

    /// @inheritdoc IAHyperliquid
    function depositToCore(
        address token,
        uint32 destinationDex,
        uint256 amount
    ) external override nonReentrant onlyDelegateCall {
        require(token == HyperliquidLib.USDC, InvalidToken());
        require(amount > 0, InvalidAmount());
        require(destinationDex == HyperliquidLib.DEX_ID_CORE_PERP, InvalidDex());

        address depositWallet = HyperliquidLib.CORE_DEPOSIT_WALLET;

        token.safeApprove(depositWallet, amount);
        ICoreDepositWallet(depositWallet).deposit(amount, destinationDex);
        token.safeApprove(depositWallet, 1);

        StorageLib.activeApplications().storeApplication(uint256(Applications.HYPERLIQUID_PERPS));
        HyperliquidLib.recordAction(address(this), int256(amount));
        emit HyperliquidDepositToCore(token, destinationDex, amount);
    }

    /// @inheritdoc IAHyperliquid
    function withdrawFromCore(uint256 amount) external override nonReentrant onlyDelegateCall {
        require(amount > 0, InvalidAmount());
        require(amount <= type(uint64).max / _USDC_HYPERCORE_DECIMALS, InvalidAmount());

        uint256 hyperCoreAmount = amount * _USDC_HYPERCORE_DECIMALS;

        HyperliquidLib.SpotSendParams memory params = HyperliquidLib.SpotSendParams({
            destinationAddress: HyperliquidLib.USDC_SYSTEM_ADDRESS,
            token: HyperliquidLib.USDC_TOKEN_INDEX,
            amount: uint64(hyperCoreAmount)
        });

        ICoreWriter(HyperliquidLib.CORE_WRITER).sendRawAction(HyperliquidLib.encodeSpotSend(params));

        // Subtract the withdrawn amount from perps NAV for one block to cover the HyperCore settlement gap.
        HyperliquidLib.recordAction(address(this), -int256(amount));
        emit HyperliquidWithdrawFromCore(amount);
    }

    /// @inheritdoc IAHyperliquid
    function transferUsdClass(uint256 amount, bool toPerp) external override nonReentrant onlyDelegateCall {
        require(amount > 0, InvalidAmount());
        require(amount <= type(uint64).max, InvalidAmount());

        HyperliquidLib.UsdClassTransferParams memory params = HyperliquidLib.UsdClassTransferParams({
            ntl: uint64(amount),
            toPerp: toPerp
        });

        ICoreWriter(HyperliquidLib.CORE_WRITER).sendRawAction(HyperliquidLib.encodeUsdClassTransfer(params));

        // No in-flight NAV adjustment: this is a HyperCore-internal reallocation. NAV is correct once
        // USDC is consolidated into the same margin class used by the NAV read (core perp).
        HyperliquidLib.recordAction(address(this), 0);
        emit HyperliquidUsdClassTransfer(amount, toPerp);
    }

    /// @inheritdoc IAHyperliquid
    function submitPerpOrder(
        HyperliquidLib.LimitOrderParams calldata params
    ) external override nonReentrant onlyDelegateCall {
        // Perps-only: asset IDs below 10_000 are core perps. Spot and HIP-3/4 are disallowed.
        require(params.asset < HyperliquidLib.ASSET_ID_CORE_PERP_MAX, OnlyCorePerp());
        require(params.sz > 0, InvalidAmount());
        require(params.encodedTif == _TIF_GTC || params.encodedTif == _TIF_IOC, InvalidTif());

        if (params.encodedTif == _TIF_GTC) {
            // GTC is only allowed for reduce-only stop-loss / take-profit orders.
            require(params.reduceOnly, ReduceOnlyGtcOnly());
        } else {
            // IOC orders must pass slippage validation against the Hyperliquid oracle.
            _validatePerpSlippage(params);
        }

        ICoreWriter(HyperliquidLib.CORE_WRITER).sendRawAction(HyperliquidLib.encodeLimitOrder(params));

        HyperliquidLib.recordAction(address(this), 0);
        emit HyperliquidPerpOrderSubmitted(
            params.asset,
            params.isBuy,
            params.limitPx,
            params.sz,
            params.reduceOnly,
            params.encodedTif,
            params.cloid
        );
    }

    /// @inheritdoc IAHyperliquid
    function cancelPerpOrderByOids(uint32[] calldata oids) external override nonReentrant onlyDelegateCall {
        require(oids.length > 0, InvalidAmount());
        ICoreWriter(HyperliquidLib.CORE_WRITER).sendRawAction(HyperliquidLib.encodeOidCancel(oids));
        HyperliquidLib.recordAction(address(this), 0);
        emit HyperliquidOrderCancelled(false, keccak256(abi.encode(oids)));
    }

    /// @inheritdoc IAHyperliquid
    function cancelPerpOrderByCloids(uint128[] calldata cloids) external override nonReentrant onlyDelegateCall {
        require(cloids.length > 0, InvalidAmount());
        ICoreWriter(HyperliquidLib.CORE_WRITER).sendRawAction(HyperliquidLib.encodeCloidCancel(cloids));
        HyperliquidLib.recordAction(address(this), 0);
        emit HyperliquidOrderCancelled(true, keccak256(abi.encode(cloids)));
    }

    /// @inheritdoc IAHyperliquid
    function depositToSpot(address token, uint256 amount) external override nonReentrant onlyDelegateCall {
        require(token == HyperliquidLib.USDC, InvalidToken());
        require(amount > 0, InvalidAmount());

        address depositWallet = HyperliquidLib.CORE_DEPOSIT_WALLET;

        token.safeApprove(depositWallet, amount);
        ICoreDepositWallet(depositWallet).deposit(amount, HyperliquidLib.DEX_ID_CORE_SPOT);
        token.safeApprove(depositWallet, 1);

        StorageLib.activeApplications().storeApplication(uint256(Applications.HYPERLIQUID_PREDICTIONS));
        HyperliquidLib.recordSpotAction(address(this), int256(amount));
        emit HyperliquidSpotDeposit(token, amount);
    }

    /// @inheritdoc IAHyperliquid
    function withdrawFromSpot(uint256 amount) external override nonReentrant onlyDelegateCall {
        require(amount > 0, InvalidAmount());
        require(amount <= type(uint64).max / _USDC_HYPERCORE_DECIMALS, InvalidAmount());

        uint256 hyperCoreAmount = amount * _USDC_HYPERCORE_DECIMALS;

        HyperliquidLib.SpotSendParams memory params = HyperliquidLib.SpotSendParams({
            destinationAddress: HyperliquidLib.USDC_SYSTEM_ADDRESS,
            token: HyperliquidLib.USDC_TOKEN_INDEX,
            amount: uint64(hyperCoreAmount)
        });

        ICoreWriter(HyperliquidLib.CORE_WRITER).sendRawAction(HyperliquidLib.encodeSpotSend(params));

        // Subtract the withdrawn amount from predictions NAV for one block to cover the HyperCore settlement gap.
        HyperliquidLib.recordSpotAction(address(this), -int256(amount));
        emit HyperliquidSpotWithdrawal(HyperliquidLib.USDC, amount);
    }

    /// @inheritdoc IAHyperliquid
    function registerPredictionToken(
        uint64 assetId,
        uint64 spotIndex,
        uint64 tokenIndex
    ) external override nonReentrant onlyDelegateCall {
        require(HyperliquidLib.isPredictionMarketAsset(assetId), OnlyPredictionMarket());

        if (!HyperliquidLib.validatePredictionToken(assetId, spotIndex, tokenIndex)) {
            revert PredictionTokenValidationFailed();
        }

        HyperliquidLib.recordPredictionToken(assetId, spotIndex, tokenIndex);
        emit HyperliquidPredictionTokenRegistered(assetId, spotIndex, tokenIndex);
    }

    /// @inheritdoc IAHyperliquid
    function deregisterPredictionToken(
        uint64 assetId,
        uint64 tokenIndex
    ) external override nonReentrant onlyDelegateCall {
        require(HyperliquidLib.isPredictionMarketAsset(assetId), OnlyPredictionMarket());
        assetId;

        HyperliquidLib.removePredictionToken(address(this), tokenIndex);
        emit HyperliquidPredictionTokenDeregistered(assetId, tokenIndex);
    }

    /// @inheritdoc IAHyperliquid
    function submitPredictionOrder(
        HyperliquidLib.LimitOrderParams calldata params
    ) external override nonReentrant onlyDelegateCall {
        require(HyperliquidLib.isPredictionMarketAsset(params.asset), OnlyPredictionMarket());
        require(params.sz > 0, InvalidAmount());
        require(params.encodedTif == _TIF_GTC || params.encodedTif == _TIF_IOC, InvalidTif());

        // Minimum order notional: size * price >= 10 USDC (HyperCore 8 decimals).
        require(uint256(params.sz) * uint256(params.limitPx) >= _MIN_HIP4_NOTIONAL, PredictionOrderTooSmall());

        if (params.encodedTif == _TIF_GTC) {
            // GTC is only allowed for reduce-only stop-loss / take-profit orders on HIP-4.
            require(params.reduceOnly, ReduceOnlyGtcOnly());
        } else {
            _validatePredictionSlippage(params);
        }

        ICoreWriter(HyperliquidLib.CORE_WRITER).sendRawAction(HyperliquidLib.encodeLimitOrder(params));

        HyperliquidLib.recordSpotAction(address(this), 0);
        emit HyperliquidPerpOrderSubmitted(
            params.asset,
            params.isBuy,
            params.limitPx,
            params.sz,
            params.reduceOnly,
            params.encodedTif,
            params.cloid
        );
    }

    /// @dev Compares the manager's limit price against the Hyperliquid oracle price.
    /// @dev `limitPx` is assumed to be in the same 8-decimal format used by Hyperliquid core perps.
    ///  `expectedLimitPx` is computed as `oraclePx * 10**szDecimals * 1e2` to match that scale.
    function _validatePerpSlippage(HyperliquidLib.LimitOrderParams calldata params) private view {
        HyperliquidLib.PerpAssetInfo memory info = HyperliquidLib.perpAssetInfo(uint32(params.asset));
        uint256 expectedPx = uint256(HyperliquidLib.oraclePx(uint32(params.asset))) * 10 ** info.szDecimals * 1e2;
        uint256 slippage = (expectedPx * _MAX_SLIPPAGE_BPS) / _BPS_BASE;

        if (params.isBuy) {
            require(params.limitPx <= expectedPx + slippage, SlippageExceeded());
        } else {
            require(params.limitPx >= expectedPx - slippage, SlippageExceeded());
        }
    }

    /// @dev Compares the manager's limit price against the Hyperliquid spot price for HIP-4 markets.
    /// @dev For HIP-4 outcome markets `szDecimals` is 0, so `expectedLimitPx` equals `spotPx` in 8 decimals.
    function _validatePredictionSlippage(HyperliquidLib.LimitOrderParams calldata params) private view {
        (uint64 spotIndex, ) = _findPredictionToken(params.asset);
        uint256 expectedPx = HyperliquidLib.normalizedSpotPx(spotIndex);
        uint256 slippage = (expectedPx * _MAX_SLIPPAGE_BPS) / _BPS_BASE;

        if (params.isBuy) {
            require(params.limitPx <= expectedPx + slippage, SlippageExceeded());
        } else {
            require(params.limitPx >= expectedPx - slippage, SlippageExceeded());
        }
    }

    /// @dev Finds the registered prediction token for a given HIP-4 asset ID.
    /// @return spotIndex The spot market index.
    /// @return tokenIndex The Hyperliquid token index.
    function _findPredictionToken(uint64 assetId) private view returns (uint64 spotIndex, uint64 tokenIndex) {
        HyperliquidLib.HyperliquidSpotTokensSlot storage slot = HyperliquidLib.hyperliquidSpotTokensSlot();
        uint256 count = slot.tokens.length;
        for (uint256 i = 0; i < count; i++) {
            if (slot.tokens[i].assetId == assetId) {
                return (slot.tokens[i].spotIndex, slot.tokens[i].tokenIndex);
            }
        }
        revert PredictionTokenNotRegistered();
    }
}
