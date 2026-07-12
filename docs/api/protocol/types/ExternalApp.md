# Solidity API

## AppTokenBalance

```solidity
struct AppTokenBalance {
  address token;
  int256 amount;
}
```

## ExternalApp

```solidity
struct ExternalApp {
  struct AppTokenBalance[] balances;
  uint256 appType;
}
```

