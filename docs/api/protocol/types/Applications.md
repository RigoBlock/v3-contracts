# Solidity API

## Applications

Supported Applications.

_Preserve order when adding new applications, last one is the counter._

```solidity
enum Applications {
  GRG_STAKING,
  UNIV4_LIQUIDITY,
  GMX_V2_POSITIONS,
  COUNT
}
```

## TokenIdsSlot

```solidity
struct TokenIdsSlot {
  uint256[] tokenIds;
  mapping(uint256 => uint256) positions;
}
```

