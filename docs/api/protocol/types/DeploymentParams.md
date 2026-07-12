# Solidity API

## EAppsParams

_Typed parameters for EApps and ENavView constructors.
 Both extensions share identical chain-specific address requirements._

```solidity
struct EAppsParams {
  address grgStakingProxy;
  address univ4Posm;
}
```

## Extensions

```solidity
struct Extensions {
  address eApps;
  address eOracle;
  address eUpgrade;
  address eCrosschain;
  address eNavView;
  address eGmxCallback;
}
```

## DeploymentParams

```solidity
struct DeploymentParams {
  struct Extensions extensions;
  address wrappedNative;
}
```

