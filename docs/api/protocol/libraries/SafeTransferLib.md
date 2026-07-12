# Solidity API

## Currency

## SafeTransferLib

_This library allows for safe transfer of tokens without using assembly_

### ApprovalFailed

```solidity
error ApprovalFailed(address token)
```

### NativeTransferFailed

```solidity
error NativeTransferFailed()
```

### TokenTransferFailed

```solidity
error TokenTransferFailed()
```

### TokenTransferFromFailed

```solidity
error TokenTransferFromFailed()
```

### ApprovalTargetIsNotContract

```solidity
error ApprovalTargetIsNotContract(address token)
```

### safeTransferNative

```solidity
function safeTransferNative(address to, uint256 amount) internal
```

### safeTransfer

```solidity
function safeTransfer(address token, address to, uint256 amount) internal
```

### safeTransferFrom

```solidity
function safeTransferFrom(address token, address from, address to, uint256 amount) internal
```

### safeApprove

```solidity
function safeApprove(address token, address spender, uint256 amount) internal
```

_Allows approving all ERC20 tokens, forcing approvals when needed._

### isAddressZero

```solidity
function isAddressZero(address target) internal pure returns (bool)
```

