// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

import {AppTokenBalance} from "../types/ExternalApp.sol";

/// @title HyperliquidLib
/// @notice Shared helpers for the Rigoblock Hyperliquid integration.
/// @dev Supports core perps (dex 0) and HIP-4 outcome markets on HyperEVM.
///  Perps NAV is derived from `accountMarginSummary.accountValue`.
///  Prediction/outcome markets are spot assets; NAV is derived by enumerating tracked
///  outcome tokens and pricing them through the Hyperliquid `spotPx` precompile.
/// @custom:security-contact security@rigoblock.com
library HyperliquidLib {
    // =========================================================================
    // Chain & contract addresses (Hyperliquid mainnet HyperEVM)
    // =========================================================================

    uint256 internal constant HYPEREVM_CHAIN_ID = 999;

    /// @dev Hyperliquid CoreWriter contract. All Core actions are sent here as raw bytes.
    address internal constant CORE_WRITER = 0x3333333333333333333333333333333333333333;

    /// @dev Circle CoreDepositWallet. Used to bridge USDC from HyperEVM to HyperCore.
    address internal constant CORE_DEPOSIT_WALLET = 0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24;

    /// @dev USDC on HyperEVM. Hyperliquid core perps and HIP-4 outcome markets are collateralized and settled in USDC.
    address internal constant USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;

    /// @dev USDC token index on Hyperliquid mainnet.
    uint64 internal constant USDC_TOKEN_INDEX = 0;

    /// @dev Hyperliquid system address for USDC (token index 0). Used as the destination for
    ///  HyperCore -> HyperEVM bridging via `sendAsset`/`spotSend`.
    address internal constant USDC_SYSTEM_ADDRESS = 0x2000000000000000000000000000000000000000;

    // =========================================================================
    // Dex / action IDs
    // =========================================================================

    uint32 internal constant DEX_ID_CORE_PERP = 0;
    uint32 internal constant DEX_ID_CORE_SPOT = type(uint32).max;

    uint24 internal constant ACTION_LIMIT_ORDER = 1;
    uint24 internal constant ACTION_SPOT_SEND = 6;
    uint24 internal constant ACTION_USD_CLASS_TRANSFER = 7;
    uint24 internal constant ACTION_OID_CANCEL = 10;
    uint24 internal constant ACTION_CLOID_CANCEL = 11;
    uint24 internal constant ACTION_SEND_ASSET = 13;

    // =========================================================================
    // Asset ID boundaries
    // =========================================================================

    /// @dev Asset IDs below this threshold are core perpetuals.
    uint32 internal constant ASSET_ID_CORE_PERP_MAX = 10_000;

    /// @dev Asset IDs at or above this threshold are HIP-4 outcome markets.
    uint64 internal constant ASSET_ID_HIP4_BASE = 100_000_000;

    // =========================================================================
    // Precompile addresses
    // =========================================================================

    address private constant _POSITION_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000800;
    address private constant _SPOT_BALANCE_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000801;
    address private constant _ORACLE_PX_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000807;
    address private constant _SPOT_PX_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000808;
    address private constant _SPOT_INFO_PRECOMPILE_ADDRESS = 0x000000000000000000000000000000000000080b;
    address private constant _PERP_ASSET_INFO_PRECOMPILE_ADDRESS = 0x000000000000000000000000000000000000080a;
    address private constant _TOKEN_INFO_PRECOMPILE_ADDRESS = 0x000000000000000000000000000000000000080C;
    address private constant _ACCOUNT_MARGIN_SUMMARY_PRECOMPILE_ADDRESS = 0x000000000000000000000000000000000000080F;
    address private constant _L1_BLOCK_NUMBER_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000809;
    address private constant _CORE_USER_EXISTS_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000810;

    // =========================================================================
    // Storage
    // =========================================================================

    bytes32 internal constant HYPERLIQUID_DATA_SLOT = bytes32(uint256(keccak256("pool.proxy.hyperliquid.data")) - 1);

    bytes32 internal constant HYPERLIQUID_SPOT_TOKENS_SLOT =
        bytes32(uint256(keccak256("pool.proxy.hyperliquid.spot.tokens")) - 1);

    /// @dev Number of blocks over which a recorded action is considered "recent". A value of 0 means
    ///  the in-flight adjustment is applied only in the same block as the action.
    uint256 private constant _ACTION_BLOCK_WINDOW = 0;

    /// @dev Maximum number of tracked prediction/outcome tokens. Mirrors the GMX position cap but uses
    ///  a higher value because spot/prediction reads are cheaper than GMX position reads. Kept comfortably
    ///  below HyperEVM's 3M fast-block gas limit (a full 64-token NAV read is well under 1M gas).
    uint256 internal constant MAX_PREDICTION_TOKENS = 64;

    struct AccountMarginSummary {
        int64 accountValue;
        uint64 marginUsed;
        uint64 ntlPos;
        int64 rawUsd;
    }

    struct PerpAssetInfo {
        string coin;
        uint32 marginTableId;
        uint8 szDecimals;
        uint8 maxLeverage;
        bool onlyIsolated;
    }

    struct SpotBalance {
        uint64 total;
        uint64 hold;
        uint64 entryNtl;
    }

    struct TokenInfo {
        string name;
        uint64[] spots;
        uint64 deployerTradingFeeShare;
        address deployer;
        address evmContract;
        uint8 szDecimals;
        uint8 weiDecimals;
        int8 evmExtraWeiDecimals;
    }

    struct SpotInfo {
        string name;
        uint64[2] tokens;
    }

    struct LimitOrderParams {
        uint32 asset;
        bool isBuy;
        uint64 limitPx;
        uint64 sz;
        bool reduceOnly;
        uint8 encodedTif;
        uint128 cloid;
    }

    struct SpotSendParams {
        address destinationAddress;
        uint64 token;
        uint64 amount;
    }

    struct SendAssetParams {
        address destinationAddress;
        address subAccountAddress;
        uint32 sourceDexId;
        uint32 destinationDexId;
        uint64 token;
        uint64 amount;
    }

    struct UsdClassTransferParams {
        uint64 ntl;
        bool toPerp;
    }

    struct TrackedPredictionToken {
        uint64 assetId;
        uint64 spotIndex;
        uint64 tokenIndex;
        uint8 weiDecimals;
    }

    struct HyperliquidSpotTokensSlot {
        TrackedPredictionToken[] tokens;
        mapping(uint64 tokenIndex => uint256 indexPlusOne) positions;
    }

    struct HyperliquidData {
        uint256 lastActionBlock;
        int256 inFlightAmount;
        uint256 lastSpotActionBlock;
        int256 spotInFlightAmount;
    }

    // =========================================================================
    // Errors
    // =========================================================================

    error HyperliquidSummaryFetchFailed(address account, uint32 dexId);
    error HyperliquidOracleFetchFailed(uint32 perpIndex);
    error HyperliquidPerpAssetInfoFetchFailed(uint32 perpIndex);
    error HyperliquidTokenInfoFetchFailed(uint64 token);
    error HyperliquidSpotInfoFetchFailed(uint64 spotIndex);
    error HyperliquidSpotPxFetchFailed(uint64 spotIndex);
    error HyperliquidSpotBalanceFetchFailed(address account, uint64 token);
    error HyperliquidPositionFetchFailed(address account, uint32 asset);
    error HyperliquidPredictionTokenNotRegistered(uint64 assetId);
    error HyperliquidPredictionTokenAlreadyRegistered(uint64 assetId);
    error HyperliquidPredictionTokenLimitReached();
    error HyperliquidPredictionTokenValidationFailed(uint64 assetId, uint64 spotIndex, uint64 tokenIndex);
    error HyperliquidInvalidPredictionAsset();
    error HyperliquidPredictionTokenBalanceNotZero(uint64 tokenIndex);

    // =========================================================================
    // Perps NAV helpers
    // =========================================================================

    /// @notice Returns the net Hyperliquid perp account value as a single USDC balance.
    /// @dev If the account value is zero and a recent CoreWriter/CoreDepositWallet action was recorded,
    ///  returns a 1-wei dust balance to prevent `purgeInactiveTokensAndApps` from removing the application
    ///  during the one-block HyperCore settlement window (H-01/H-02/H-03 analogue).
    function getHyperliquidBalances(address account) internal view returns (AppTokenBalance[] memory balances) {
        int256 hyperliquidValue = int256(accountMarginSummary(account, DEX_ID_CORE_PERP).accountValue);

        if (hasRecentPerpAction(account)) {
            hyperliquidValue += hyperliquidData().inFlightAmount;
        }

        if (hyperliquidValue <= 0) {
            if (hasRecentPerpAction(account)) {
                balances = new AppTokenBalance[](1);
                balances[0] = AppTokenBalance({token: USDC, amount: 1});
            }
            return balances;
        }

        balances = new AppTokenBalance[](1);
        balances[0] = AppTokenBalance({token: USDC, amount: hyperliquidValue});
    }

    /// @notice Fetches the account margin summary for a single Hyperliquid dex.
    function accountMarginSummary(
        address account,
        uint32 dexId
    ) internal view returns (AccountMarginSummary memory summary) {
        (bool success, bytes memory result) = _ACCOUNT_MARGIN_SUMMARY_PRECOMPILE_ADDRESS.staticcall(
            abi.encode(dexId, account)
        );
        if (!success) revert HyperliquidSummaryFetchFailed(account, dexId);
        summary = abi.decode(result, (AccountMarginSummary));
    }

    /// @notice Fetches the oracle price for a core perp asset.
    /// @return price Hyperliquid oracle price. For core perps this is in USD with 6 decimals.
    function oraclePx(uint32 perpIndex) internal view returns (uint64 price) {
        (bool success, bytes memory result) = _ORACLE_PX_PRECOMPILE_ADDRESS.staticcall(abi.encode(perpIndex));
        if (!success) revert HyperliquidOracleFetchFailed(perpIndex);
        price = abi.decode(result, (uint64));
    }

    /// @notice Fetches perp asset metadata, mainly for `szDecimals`.
    function perpAssetInfo(uint32 perpIndex) internal view returns (PerpAssetInfo memory info) {
        (bool success, bytes memory result) = _PERP_ASSET_INFO_PRECOMPILE_ADDRESS.staticcall(abi.encode(perpIndex));
        if (!success) revert HyperliquidPerpAssetInfoFetchFailed(perpIndex);
        info = abi.decode(result, (PerpAssetInfo));
    }

    // =========================================================================
    // Spot / prediction market precompiles
    // =========================================================================

    /// @notice Fetches the spot balance for a single token index.
    /// @dev Amounts are returned in the token's `weiDecimals` format.
    function spotBalance(address account, uint64 tokenIndex) internal view returns (SpotBalance memory balance) {
        (bool success, bytes memory result) = _SPOT_BALANCE_PRECOMPILE_ADDRESS.staticcall(
            abi.encode(account, tokenIndex)
        );
        if (!success) revert HyperliquidSpotBalanceFetchFailed(account, tokenIndex);
        balance = abi.decode(result, (SpotBalance));
    }

    /// @notice Fetches the spot price for a given spot index.
    /// @return price Spot price as a fixed-point integer with 8 decimals.
    function spotPx(uint64 spotIndex) internal view returns (uint64 price) {
        (bool success, bytes memory result) = _SPOT_PX_PRECOMPILE_ADDRESS.staticcall(abi.encode(spotIndex));
        if (!success) revert HyperliquidSpotPxFetchFailed(spotIndex);
        price = abi.decode(result, (uint64));
    }

    /// @notice Fetches spot market metadata.
    function spotInfo(uint64 spotIndex) internal view returns (SpotInfo memory info) {
        (bool success, bytes memory result) = _SPOT_INFO_PRECOMPILE_ADDRESS.staticcall(abi.encode(spotIndex));
        if (!success) revert HyperliquidSpotInfoFetchFailed(spotIndex);
        info = abi.decode(result, (SpotInfo));
    }

    /// @notice Fetches token metadata.
    function tokenInfo(uint64 tokenIndex) internal view returns (TokenInfo memory info) {
        (bool success, bytes memory result) = _TOKEN_INFO_PRECOMPILE_ADDRESS.staticcall(abi.encode(tokenIndex));
        if (!success) revert HyperliquidTokenInfoFetchFailed(tokenIndex);
        info = abi.decode(result, (TokenInfo));
    }

    /// @notice Returns the spot price normalized by the base token's `szDecimals`.
    /// @dev For HIP-4 outcome markets the base token is USDC and `szDecimals` is 0, so this equals `spotPx`.
    function normalizedSpotPx(uint64 spotIndex) internal view returns (uint256 price) {
        SpotInfo memory info = spotInfo(spotIndex);
        uint8 baseSzDecimals = tokenInfo(info.tokens[0]).szDecimals;
        price = uint256(spotPx(spotIndex)) * 10 ** baseSzDecimals;
    }

    // =========================================================================
    // Prediction market asset helpers
    // =========================================================================

    /// @notice Returns true if `assetId` is in the HIP-4 outcome market range.
    function isPredictionMarketAsset(uint64 assetId) internal pure returns (bool) {
        return assetId >= ASSET_ID_HIP4_BASE;
    }

    /// @notice Validates that a manager-supplied `(assetId, spotIndex, tokenIndex)` triple is consistent
    ///  with on-chain `spotInfo`/`tokenInfo`. Restricted to USDC-quoted HIP-4 markets.
    /// @dev The manager must register each outcome token because the token index cannot be derived from the asset ID alone.
    function validatePredictionToken(uint64 assetId, uint64 spotIndex, uint64 tokenIndex) internal view returns (bool) {
        if (!isPredictionMarketAsset(assetId)) return false;

        SpotInfo memory sInfo = spotInfo(spotIndex);
        TokenInfo memory token0 = tokenInfo(sInfo.tokens[0]);
        TokenInfo memory token1 = tokenInfo(sInfo.tokens[1]);

        // One token must be USDC (the quote asset) and the other must be the outcome token.
        bool token0IsUsdc = token0.evmContract == USDC;
        bool token1IsUsdc = token1.evmContract == USDC;
        if (token0IsUsdc == token1IsUsdc) return false;

        // The supplied tokenIndex must be one of the two spot tokens.
        if (tokenIndex != sInfo.tokens[0] && tokenIndex != sInfo.tokens[1]) return false;

        // The supplied tokenIndex must NOT be the USDC quote token.
        if (token0IsUsdc && tokenIndex == sInfo.tokens[0]) return false;
        if (token1IsUsdc && tokenIndex == sInfo.tokens[1]) return false;

        return true;
    }

    // =========================================================================
    // Prediction market token tracking
    // =========================================================================

    /// @notice Records a new HIP-4 outcome token for NAV tracking.
    /// @dev Reverts if the token is already tracked or if the cap is reached.
    function recordPredictionToken(uint64 assetId, uint64 spotIndex, uint64 tokenIndex) internal {
        if (!isPredictionMarketAsset(assetId)) revert HyperliquidInvalidPredictionAsset();

        HyperliquidSpotTokensSlot storage slot = hyperliquidSpotTokensSlot();
        if (slot.positions[tokenIndex] != 0) revert HyperliquidPredictionTokenAlreadyRegistered(assetId);

        if (!validatePredictionToken(assetId, spotIndex, tokenIndex)) {
            revert HyperliquidPredictionTokenValidationFailed(assetId, spotIndex, tokenIndex);
        }

        if (slot.tokens.length >= MAX_PREDICTION_TOKENS) revert HyperliquidPredictionTokenLimitReached();

        uint8 weiDecimals = tokenInfo(tokenIndex).weiDecimals;
        slot.tokens.push(
            TrackedPredictionToken({
                assetId: assetId,
                spotIndex: spotIndex,
                tokenIndex: tokenIndex,
                weiDecimals: weiDecimals
            })
        );
        slot.positions[tokenIndex] = slot.tokens.length;
    }

    /// @notice Removes a tracked HIP-4 outcome token. Reverts if still held or not registered.
    function removePredictionToken(address account, uint64 tokenIndex) internal {
        HyperliquidSpotTokensSlot storage slot = hyperliquidSpotTokensSlot();
        uint256 indexPlusOne = slot.positions[tokenIndex];
        if (indexPlusOne == 0) revert HyperliquidPredictionTokenNotRegistered(tokenIndex);

        // Prevent removing a token that still has a non-zero balance, which would understate NAV.
        if (spotBalance(account, tokenIndex).total != 0) revert HyperliquidPredictionTokenBalanceNotZero(tokenIndex);

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = slot.tokens.length - 1;

        if (index != lastIndex) {
            TrackedPredictionToken memory lastToken = slot.tokens[lastIndex];
            slot.tokens[index] = lastToken;
            slot.positions[lastToken.tokenIndex] = indexPlusOne;
        }

        slot.tokens.pop();
        delete slot.positions[tokenIndex];
    }

    /// @notice Returns the number of currently tracked prediction tokens.
    function getPredictionTokenCount() internal view returns (uint256) {
        return hyperliquidSpotTokensSlot().tokens.length;
    }

    /// @notice Returns the USDC value of all tracked HIP-4 outcome tokens plus the USDC spot balance.
    /// @dev Outcome tokens have no EVM contract, so the returned token is always USDC. The value is computed as
    ///  `balance * spotPrice / 10^tokenWeiDecimals` and then converted from HyperCore 8-decimal USDC to EVM 6-decimal USDC.
    function getPredictionBalances(address account) internal view returns (AppTokenBalance[] memory balances) {
        HyperliquidSpotTokensSlot storage slot = hyperliquidSpotTokensSlot();
        uint256 tokenCount = slot.tokens.length;

        // Always include the USDC spot balance (token index 0) so idle deposits are counted.
        int256 totalUsdcValue = _spotUsdcBalance(account, USDC_TOKEN_INDEX);

        for (uint256 i = 0; i < tokenCount; i++) {
            TrackedPredictionToken memory token = slot.tokens[i];
            SpotBalance memory balance = spotBalance(account, token.tokenIndex);
            if (balance.total == 0) continue;

            uint256 normalizedPrice = normalizedSpotPx(token.spotIndex);
            uint256 tokenValue = (uint256(balance.total) * normalizedPrice) / (10 ** token.weiDecimals);

            // Convert from HyperCore 8-decimal USDC to EVM 6-decimal USDC.
            totalUsdcValue += int256(tokenValue / 1e2);
        }

        if (hasRecentSpotAction(account)) {
            totalUsdcValue += hyperliquidData().spotInFlightAmount;
        }

        if (totalUsdcValue <= 0) {
            if (hasRecentSpotAction(account)) {
                balances = new AppTokenBalance[](1);
                balances[0] = AppTokenBalance({token: USDC, amount: 1});
            }
            return balances;
        }

        balances = new AppTokenBalance[](1);
        balances[0] = AppTokenBalance({token: USDC, amount: totalUsdcValue});
    }

    /// @notice Returns the USDC spot balance for an account in EVM 6-decimal units.
    function _spotUsdcBalance(address account, uint64 tokenIndex) private view returns (int256) {
        SpotBalance memory balance = spotBalance(account, tokenIndex);
        // HyperCore USDC weiDecimals = 8, EVM USDC decimals = 6.
        return int256(uint256(balance.total) / 1e2);
    }

    // =========================================================================
    // Action encoding
    // =========================================================================

    /// @notice Encodes a core perp limit order for `ICoreWriter.sendRawAction`.
    /// @dev Hyperliquid action format: `<1-byte version=1><3-byte actionId><abi-encoded params>`.
    function encodeLimitOrder(LimitOrderParams memory params) internal pure returns (bytes memory actionData) {
        actionData = bytes.concat(abi.encodePacked(uint8(1), uint24(ACTION_LIMIT_ORDER)), abi.encode(params));
    }

    /// @notice Encodes a `spotSend` action for `ICoreWriter.sendRawAction`.
    /// @dev Used to bridge USDC from HyperCore spot to HyperEVM. Destination must be the token's system address.
    function encodeSpotSend(SpotSendParams memory params) internal pure returns (bytes memory actionData) {
        actionData = bytes.concat(abi.encodePacked(uint8(1), uint24(ACTION_SPOT_SEND)), abi.encode(params));
    }

    /// @notice Encodes a `sendAsset` action for `ICoreWriter.sendRawAction`.
    /// @dev Used to move USDC between HyperCore dexes. For Core->EVM bridging use `encodeSpotSend` instead.
    function encodeSendAsset(SendAssetParams memory params) internal pure returns (bytes memory actionData) {
        actionData = bytes.concat(abi.encodePacked(uint8(1), uint24(ACTION_SEND_ASSET)), abi.encode(params));
    }

    /// @notice Encodes a `usdClassTransfer` action for `ICoreWriter.sendRawAction`.
    /// @dev Moves USDC between the perp and spot margin classes on HyperCore.
    function encodeUsdClassTransfer(
        UsdClassTransferParams memory params
    ) internal pure returns (bytes memory actionData) {
        actionData = bytes.concat(abi.encodePacked(uint8(1), uint24(ACTION_USD_CLASS_TRANSFER)), abi.encode(params));
    }

    /// @notice Encodes a cancel-by-CLOID action for `ICoreWriter.sendRawAction`.
    function encodeCloidCancel(uint128[] memory cloids) internal pure returns (bytes memory actionData) {
        actionData = bytes.concat(abi.encodePacked(uint8(1), uint24(ACTION_CLOID_CANCEL)), abi.encode(cloids));
    }

    /// @notice Encodes a cancel-by-OID action for `ICoreWriter.sendRawAction`.
    function encodeOidCancel(uint32[] memory oids) internal pure returns (bytes memory actionData) {
        actionData = bytes.concat(abi.encodePacked(uint8(1), uint24(ACTION_OID_CANCEL)), abi.encode(oids));
    }

    // =========================================================================
    // Base-token / price-feed carve-out helpers
    // =========================================================================

    /// @notice Returns true if `token` is the USDC collateral token used by Hyperliquid core perps and HIP-4 markets.
    function isCollateralToken(address token) internal pure returns (bool) {
        return token == USDC;
    }

    /// @notice Returns true when the pool is on HyperEVM and its base token is the Hyperliquid collateral token.
    /// @dev Used by `MixinPoolValue` to skip the `EOracle.hasPriceFeed` requirement for this token on HyperEVM,
    ///  where Uniswap V4 is not deployed. This restricts the pool to holding only USDC-denominated assets.
    function isHyperliquidBaseToken(address token) internal view returns (bool) {
        return block.chainid == HYPEREVM_CHAIN_ID && isCollateralToken(token);
    }

    // =========================================================================
    // Action-block tracking (prevents inter-block purge abuse)
    // =========================================================================

    /// @notice Records the current block number and an in-flight amount for a perps action.
    /// @dev Must be called by `AHyperliquid` on every state-affecting perps action.
    ///  In-flight amounts are added to perps NAV for one block to cover the HyperCore settlement gap.
    function recordAction(address /* account */, int256 amount) internal {
        HyperliquidData storage data = hyperliquidData();
        if (data.lastActionBlock != block.number) {
            data.inFlightAmount = 0;
        }
        data.lastActionBlock = block.number;
        data.inFlightAmount += amount;
    }

    /// @notice Returns true if a perps action was recorded within the last `_ACTION_BLOCK_WINDOW` blocks.
    function hasRecentPerpAction(address /* account */) internal view returns (bool) {
        uint256 lastBlock = hyperliquidData().lastActionBlock;
        return lastBlock != 0 && block.number <= lastBlock + _ACTION_BLOCK_WINDOW;
    }

    /// @notice Records the current block number and an in-flight amount for a spot action.
    /// @dev Positive `amount` is added to the prediction NAV (deposits); negative `amount` is subtracted
    ///  (withdrawals) during the one-block HyperCore settlement gap.
    function recordSpotAction(address /* account */, int256 amount) internal {
        HyperliquidData storage data = hyperliquidData();
        if (data.lastSpotActionBlock != block.number) {
            data.spotInFlightAmount = 0;
        }
        data.lastSpotActionBlock = block.number;
        data.spotInFlightAmount += amount;
    }

    /// @notice Returns true if a spot action was recorded within the last `_ACTION_BLOCK_WINDOW` blocks.
    function hasRecentSpotAction(address /* account */) internal view returns (bool) {
        uint256 lastBlock = hyperliquidData().lastSpotActionBlock;
        return lastBlock != 0 && block.number <= lastBlock + _ACTION_BLOCK_WINDOW;
    }

    function hyperliquidData() internal pure returns (HyperliquidData storage s) {
        bytes32 slot = HYPERLIQUID_DATA_SLOT;
        assembly {
            s.slot := slot
        }
    }

    function hyperliquidSpotTokensSlot() internal pure returns (HyperliquidSpotTokensSlot storage s) {
        bytes32 slot = HYPERLIQUID_SPOT_TOKENS_SLOT;
        assembly {
            s.slot := slot
        }
    }
}
