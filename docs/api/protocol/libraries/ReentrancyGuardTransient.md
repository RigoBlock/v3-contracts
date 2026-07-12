# Solidity API

## ReentrancyGuardTransient

_Variant of {ReentrancyGuard} that uses transient storage.

NOTE: This variant only works on networks where EIP-1153 is available.

_Available since v5.1.__

### ReentrancyGuardReentrantCall

```solidity
error ReentrancyGuardReentrantCall()
```

_Unauthorized reentrant call._

### nonReentrant

```solidity
modifier nonReentrant()
```

_Prevents a contract from calling itself, directly or indirectly.
Calling a `nonReentrant` function from another `nonReentrant`
function is not supported. It is possible to prevent this from happening
by making the `nonReentrant` function external, and making it call a
`private` function that does the actual work._

### _reentrancyGuardEntered

```solidity
function _reentrancyGuardEntered() internal view returns (bool)
```

_Returns true if the reentrancy guard is currently set to "entered", which indicates there is a
`nonReentrant` function in the call stack._

