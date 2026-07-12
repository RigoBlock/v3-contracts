# Solidity API

## GmxCallbackLib

Storage layout and helpers for the GMX v2 order callback extension.
 The data is stored in the pool proxy and updated by `EGmxCallback` when
 GMX keepers execute, cancel, or freeze orders.

_All state is ERC-7201 namespaced; `MixinStorage` asserts the slot._

### GMX_CALLBACK_DATA_SLOT

```solidity
bytes32 GMX_CALLBACK_DATA_SLOT
```

ERC-7201 slot for GMX callback data.

_Must stay in sync with `MixinStorage` assertion._

### CLAIMABLE_FUNDING_AMOUNT_KEY

```solidity
bytes32 CLAIMABLE_FUNDING_AMOUNT_KEY
```

GMX v2 DataStore keys used by the callback extension and NAV accounting.

### CLAIMABLE_COLLATERAL_AMOUNT_KEY

```solidity
bytes32 CLAIMABLE_COLLATERAL_AMOUNT_KEY
```

### CLAIMABLE_COLLATERAL_FACTOR_KEY

```solidity
bytes32 CLAIMABLE_COLLATERAL_FACTOR_KEY
```

### CLAIMABLE_COLLATERAL_REDUCTION_FACTOR_KEY

```solidity
bytes32 CLAIMABLE_COLLATERAL_REDUCTION_FACTOR_KEY
```

### CLAIMED_COLLATERAL_AMOUNT_KEY

```solidity
bytes32 CLAIMED_COLLATERAL_AMOUNT_KEY
```

### CLAIMABLE_COLLATERAL_TIME_DIVISOR_KEY

```solidity
bytes32 CLAIMABLE_COLLATERAL_TIME_DIVISOR_KEY
```

### CLAIMABLE_COLLATERAL_DELAY_KEY

```solidity
bytes32 CLAIMABLE_COLLATERAL_DELAY_KEY
```

### InvalidCallbackAccount

```solidity
error InvalidCallbackAccount()
```

### ClaimableCollateralInfo

Metadata for a recorded claimable-collateral DataStore key.
 The factor/reduction/claimed keys are recomputed at NAV time to minimize
 callback gas costs.

```solidity
struct ClaimableCollateralInfo {
  address token;
  address market;
  uint256 timeKey;
}
```

### GmxCallbackSlot

Storage layout for the GMX callback extension.

```solidity
struct GmxCallbackSlot {
  struct Bytes32Set trackedMarkets;
  struct Bytes32Set claimableCollateralKeys;
  mapping(bytes32 => struct GmxCallbackLib.ClaimableCollateralInfo) claimableCollateralInfo;
}
```

### gmxCallbackData

```solidity
function gmxCallbackData() internal pure returns (struct GmxCallbackLib.GmxCallbackSlot s)
```

Returns the GMX callback storage slot for the current pool.

### addTrackedMarket

```solidity
function addTrackedMarket(address market) internal
```

Adds `market` to the tracked-markets set.

### removeTrackedMarket

```solidity
function removeTrackedMarket(address market) internal
```

Removes `market` from the tracked-markets set.

### containsTrackedMarket

```solidity
function containsTrackedMarket(address market) internal view returns (bool)
```

Returns true when `market` is in the tracked-markets set.

### trackedMarketsCount

```solidity
function trackedMarketsCount() internal view returns (uint256)
```

Returns the number of tracked markets.

### trackedMarketAt

```solidity
function trackedMarketAt(uint256 index) internal view returns (address)
```

Returns the tracked market at `index`.

### removeClaimableCollateralKey

```solidity
function removeClaimableCollateralKey(bytes32 key) internal
```

Removes a fully-claimed collateral key from the tracked set and metadata map.

