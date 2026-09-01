# Hyperliquid HIP-4 Outcome Markets

> Status: **not implemented in the current Rigoblock adapter**. The code below was removed from the production contracts and is kept here as a reference for a future integration.

## Why it was removed

1. **No support in `hyper-evm-lib`**: `CoreWriterLib` does not expose an action-17 helper for outcome operations (`splitOutcome`, `mergeOutcome`, `mergeQuestion`, `negateOutcome`).
2. **Asset ID → token index is not deterministic on-chain**: Hyperliquid encodes outcome assets as `assetId = 100_000_000 + (10 * outcome + side)`, but the HyperCore `tokenIndex` used by the spot-balance precompile is a separate registry value. Calling `tokenInfo(encoding)` or `spotBalance(..., encoding)` reverts, so the adapter cannot derive the token index from the asset ID alone.
3. **Small upside / disproportionate risk**: At the time of the integration there were only a handful of live outcome markets, while a wrong token-index assumption would silently misprice NAV.

The current adapter therefore rejects limit orders with `assetId >= 100_000_000` via `InvalidActionData`. Outcome positions, if any, will naturally settle to USDC and be captured by the regular USDC balance once they land on HyperCore.

## Asset encoding reference

```solidity
uint64 internal constant ASSET_ID_HIP4_BASE = 100_000_000;

function isOutcomeMarketAsset(uint64 assetId) internal pure returns (bool) {
    return assetId >= ASSET_ID_HIP4_BASE;
}

function getOutcomeEncoding(uint64 assetId) internal pure returns (uint64 encoding) {
    return assetId - ASSET_ID_HIP4_BASE;
}
```

From the Hyperliquid docs:

```text
encoding = 10 * outcome + side
outcome spot coin:    #<encoding>
outcome token name:   +<encoding>
outcome asset id:     100_000_000 + encoding
```

`side` is `0` (yes) or `1` (no). On mainnet, outcome markets currently quote against **USDC** (`quoteToken: "USDC"` in `outcomeMeta`).

## Token-index problem

`spotClearinghouseState` returns a `token` field per balance that is the real HyperCore token index. There is no on-chain registry that maps `(outcome, side)` or `assetId` to that index; it must be discovered off-chain (e.g. from `spotClearinghouseState` after a position exists) and then supplied to the contract.

Because of this, the removed implementation **assumed** `tokenIndex == encoding`. That assumption was wrong and would have made every outcome-token precompile call revert.

## Saved NAV tracking code

This was the logic used to value outcome tokens against their USDC-quoted spot market. It should only be restored once the correct token index can be provided or discovered on-chain.

```solidity
/// @dev Maximum number of tracked outcome tokens.
uint256 internal constant MAX_OUTCOME_TOKENS = 64;

/// @dev Stored in `HYPERLIQUID_SPOT_TOKENS_SLOT` as an `EnumerableSet.Bytes32Set`.
function getOutcomeBalance(address account) private view returns (int256 totalUsdcValue) {
    Bytes32Set storage slot = StorageLib.hyperliquidOutcomeTokensSlot();
    uint256 tokenCount = slot.values.length;

    for (uint256 i = 0; i < tokenCount; i++) {
        uint64 tokenIndex = uint64(uint256(slot.values[i]));
        uint64 balanceTotal = PrecompileLib.spotBalance(account, tokenIndex).total;

        if (balanceTotal > 0) {
            uint64 spotIndex = PrecompileLib.getSpotIndex(tokenIndex);
            uint256 normalizedPrice = PrecompileLib.normalizedSpotPx(spotIndex);
            uint8 weiDecimals = PrecompileLib.tokenInfo(tokenIndex).weiDecimals;
            uint256 tokenValue = (uint256(balanceTotal) * normalizedPrice) / (10 ** weiDecimals);
            totalUsdcValue += int256(tokenValue);
        }
    }
}

function registerOutcomeToken(uint64 assetId, uint64 tokenIndex) internal {
    if (!isOutcomeMarketAsset(assetId)) revert InvalidOutcomeAsset(assetId);

    uint64 spotIndex = PrecompileLib.getSpotIndex(tokenIndex);
    PrecompileLib.SpotInfo memory sInfo = PrecompileLib.spotInfo(spotIndex);
    PrecompileLib.TokenInfo memory token0 = PrecompileLib.tokenInfo(sInfo.tokens[0]);
    PrecompileLib.TokenInfo memory token1 = PrecompileLib.tokenInfo(sInfo.tokens[1]);

    address usdc = HLConstants.usdc();
    bool token0IsUsdc = token0.evmContract == usdc;
    bool token1IsUsdc = token1.evmContract == usdc;
    if (token0IsUsdc == token1IsUsdc) revert InvalidOutcomeAsset(assetId);
    if (tokenIndex != sInfo.tokens[0] && tokenIndex != sInfo.tokens[1]) revert InvalidOutcomeAsset(assetId);
    if ((token0IsUsdc && tokenIndex == sInfo.tokens[0]) || (token1IsUsdc && tokenIndex == sInfo.tokens[1])) {
        revert InvalidOutcomeAsset(assetId);
    }

    StorageLib.hyperliquidOutcomeTokensSlot().add(bytes32(uint256(tokenIndex)));
}

function purgeInactiveOutcomeTokens() internal {
    Bytes32Set storage slot = StorageLib.hyperliquidOutcomeTokensSlot();
    uint256 i = slot.values.length;
    while (i > 0) {
        i--;
        uint64 tokenIndex = uint64(uint256(slot.values[i]));
        if (PrecompileLib.spotBalance(address(this), tokenIndex).total == 0) {
            slot.remove(bytes32(uint256(tokenIndex)));
        }
    }
}
```

The corresponding storage slot was:

```solidity
bytes32 public constant HYPERLIQUID_SPOT_TOKENS_SLOT =
    0x03aa2efad223f8d0a3bf9825e8fef3da818f65e1faabdd0b5d92bd49cd60ba95;

function hyperliquidOutcomeTokensSlot() internal pure returns (Bytes32Set storage s) {
    bytes32 slot = HYPERLIQUID_SPOT_TOKENS_SLOT;
    assembly { s.slot := slot }
}
```

## Saved adapter-level validation

When reintroducing outcome support, `_placeLimitOrder` should validate the order and register the token. The registration either needs the token index passed by the manager, or must happen after the first fill has created a `spotClearinghouseState` entry that can be read off-chain.

```solidity
uint256 private constant _MIN_HIP4_NOTIONAL = 10 * 1e8;

function _placeLimitOrder(bytes calldata data) private {
    (uint32 asset, bool isBuy, uint64 limitPx, uint64 sz, bool reduceOnly, uint8 encodedTif, uint128 cloid) =
        abi.decode(data[4:], (uint32, bool, uint64, uint64, bool, uint8, uint128));

    // ... existing TIF/size validation ...

    uint64 assetId = uint64(asset);
    if (isOutcomeMarketAsset(assetId)) {
        require(uint256(sz) * uint256(limitPx) >= _MIN_HIP4_NOTIONAL, OutcomeOrderTooSmall());

        // CRITICAL: do not use assetId - 100_000_000 as the token index.
        // The correct tokenIndex must be supplied or discovered from spotClearinghouseState.
        uint64 tokenIndex = ...;
        HyperliquidLib.registerOutcomeToken(assetId, tokenIndex);
    }

    // ... slippage / forwarding ...
}
```

## Action 17 (Outcome operation)

When `hyper-evm-lib` adds it, action 17 should be forwarded like any other `sendRawAction`:

```solidity
function _outcomeOperation(bytes calldata data) private {
    (uint8 encodedOperation, uint32 question, uint32 outcome, uint64 wei) =
        abi.decode(data[4:], (uint8, uint32, uint32, uint64));

    CoreWriterLib.coreWriter.sendRawAction(
        abi.encodePacked(uint8(1), uint24(17), abi.encode(encodedOperation, question, outcome, wei))
    );
}
```

`encodedOperation`: `0 = SplitOutcome`, `1 = MergeOutcome`, `2 = MergeQuestion`, `3 = NegateOutcome`.

## Suggested re-implementation path

1. Wait for `hyper-evm-lib` (or another audited library) to ship typed outcome helpers and confirm the token-index mapping.
2. Add a small **off-chain step** that reads `spotClearinghouseState` for the pool, extracts outcome token indices, and supplies them in the registration data.
3. Restore the `HYPERLIQUID_SPOT_TOKENS_SLOT`, `registerOutcomeToken`, `purgeInactiveOutcomeTokens`, and the action-17 branch.
4. Add fork tests that use a real Hyperliquid mainnet pool with an actual outcome position, rather than mocked token indices.

## References

- [Hyperliquid asset IDs](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/asset-ids)
- [HIP-4 outcome markets](https://hyperliquid.gitbook.io/hyperliquid-docs/hyperliquid-improvement-proposals-hips/hip-4-outcome-markets)
- [Chainstack HIP-4 trading guide](https://docs.chainstack.com/docs/hyperliquid-hip4-outcome-markets-trading)
- [Hyperliquid CoreWriter](https://docs.chainstack.com/docs/hyperliquid-corewriter)
