# Solidity API

## Int256

## TransientStorage

### _TRANSIENT_BALANCE_SLOT

```solidity
bytes32 _TRANSIENT_BALANCE_SLOT
```

### _TRANSIENT_TWAP_TICK_SLOT

```solidity
bytes32 _TRANSIENT_TWAP_TICK_SLOT
```

### _STORED_NAV_SLOT

```solidity
bytes32 _STORED_NAV_SLOT
```

### _STORED_ASSETS_SLOT

```solidity
bytes32 _STORED_ASSETS_SLOT
```

### _TEMP_BALANCE_SLOT

```solidity
bytes32 _TEMP_BALANCE_SLOT
```

### _DONATION_LOCK_SLOT

```solidity
bytes32 _DONATION_LOCK_SLOT
```

### store

```solidity
function store(Int256 slot, address token, int256 value) internal
```

Stores a mapping of token addresses to int256 values

### get

```solidity
function get(Int256 slot, address token) internal view returns (int256)
```

### storeBalance

```solidity
function storeBalance(address token, int256 balance) internal
```

### getBalance

```solidity
function getBalance(address token) internal view returns (int256)
```

### storeTwap

```solidity
function storeTwap(address token, int24 twap) internal
```

### getTwap

```solidity
function getTwap(address token) internal view returns (int24)
```

### setDonationLock

```solidity
function setDonationLock(address token, uint256 balance) internal
```

### getDonationLock

```solidity
function getDonationLock() internal view returns (bool)
```

### getTemporaryBalance

```solidity
function getTemporaryBalance(address token) internal view returns (uint256, bool)
```

### storeNav

```solidity
function storeNav(uint256 nav) internal
```

### storeAssets

```solidity
function storeAssets(uint256 assets) internal
```

### getStoredNav

```solidity
function getStoredNav() internal view returns (uint256)
```

### getStoredAssets

```solidity
function getStoredAssets() internal view returns (uint256)
```

