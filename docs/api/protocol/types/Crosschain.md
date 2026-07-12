# Solidity API

## OpType

```solidity
enum OpType {
  Transfer,
  Sync,
  Unknown
}
```

## SourceMessageParams

```solidity
struct SourceMessageParams {
  enum OpType opType;
  uint256 navTolerance;
  uint256 sourceNativeAmount;
  bool shouldUnwrapOnDestination;
}
```

## DestinationMessageParams

```solidity
struct DestinationMessageParams {
  enum OpType opType;
  bool shouldUnwrapNative;
}
```

## Call

Single call to be executed by Across MulticallHandler

_Matches Across protocol Call struct exactly_

```solidity
struct Call {
  address target;
  bytes callData;
  uint256 value;
}
```

## Instructions

Complete instructions for MulticallHandler execution

_Matches Across protocol Instructions struct exactly_

```solidity
struct Instructions {
  struct Call[] calls;
  address fallbackRecipient;
}
```

