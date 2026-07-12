# Solidity API

## IAcrossSpokePool

Interface for Across Protocol V3 SpokePool contract

_Used for cross-chain token transfers via Across Protocol_

### fillDeadlineBuffer

```solidity
function fillDeadlineBuffer() external view returns (uint32)
```

### depositV3

```solidity
function depositV3(address depositor, address recipient, address inputToken, address outputToken, uint256 inputAmount, uint256 outputAmount, uint256 destinationChainId, address exclusiveRelayer, uint32 quoteTimestamp, uint32 fillDeadline, uint32 exclusivityDeadline, bytes message) external payable
```

