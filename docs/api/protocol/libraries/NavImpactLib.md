# Solidity API

## NavImpactLib

Provides percentage-based NAV impact validation for cross-chain transfers

_Used by both AIntents (source) and ECrosschain (destination) for consistent validation_

### EffectiveSupplyTooLow

```solidity
error EffectiveSupplyTooLow()
```

### NavImpactTooHigh

```solidity
error NavImpactTooHigh()
```

Thrown when transfer amount exceeds maximum allowed NAV impact

_Impact is calculated as (transferValue * 10000) / totalAssetsValue in basis points_

### MINIMUM_SUPPLY_RATIO

```solidity
uint256 MINIMUM_SUPPLY_RATIO
```

Minimum ratio of effective supply to total supply (1/20 = 5%)

_When virtual supply is negative, effective supply must be at least totalSupply / MINIMUM_SUPPLY_RATIO_

### validateNavImpact

```solidity
function validateNavImpact(address token, uint256 amount, uint256 toleranceBps) internal view
```

Validates that transfer amount doesn't exceed NAV impact tolerance

_Calculates percentage impact: (transferValue * 10000) / totalAssetsValue vs toleranceBps_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| token | address | Token being transferred |
| amount | uint256 | Amount being transferred |
| toleranceBps | uint256 | Maximum allowed NAV impact in basis points (e.g., 1000 = 10%) |

### validateSupply

```solidity
function validateSupply(uint256 totalSupply, int256 virtualSupply) internal pure
```

Validates that effective supply meets minimum threshold when virtual supply is negative

