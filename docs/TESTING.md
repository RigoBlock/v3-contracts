# Testing Guide

Rigoblock uses two test runners:

- **Hardhat / Mocha** (`yarn test`): runs the `.ts` specs only. Foundry owns all `.sol` tests; HH3's built-in Solidity test runner is intentionally unused.
- **Foundry** (`forge test`): runs all Solidity unit, integration, and fork tests.

Coverage follows the same split: `hardhat test mocha --coverage` for TypeScript, `forge coverage` for Solidity.

## Fork Testing Pattern

### Fork-block hygiene (required at branch creation)

Every new branch must bump all fork blocks in `contracts/test/ForkBlocks.sol` to recent values as the first task of the branch, and fix whatever surfaces. Stale pins hide fork-state-dependent regressions (oracle drift, accrued fees, new deployments, rounding edges).

- Pick blocks a few hours/days below "latest" for RPC/archive stability.
- Keep any documented ordering constraints (e.g. `MAINNET_BLOCK` must stay after the TEST_POOL `donate()` routing upgrade).
- Update the per-block comments with the new values and dates.
- `ForkBlocks.sol` is hashed into the CI cache key, so the bump also keeps fork caches fresh.
- Tests must **never** introduce their own local block pins. `git grep createSelectFork` should show only `Constants.*_BLOCK`. If a test seems to need a historical pin, make the test pin-agnostic instead.

### Test obsolescence review

A block bump is also the moment to audit which fork tests have been made obsolete by protocol upgrades landing in production:

- Tests that force-upgrade the factory implementation or Authority mappings to assert pre-upgrade behavior should assert the new production state instead once governance has executed the upgrade.
- Tests comparing states across implementation versions should collapse to the current live version once the rollout is complete.
- Replay/incident fixtures should be kept only while the replayed bytes still represent what the external protocol (0x, Across, GMX, Uniswap) actually produces.

Remember that each pool operator must approve an upgraded implementation for their pool, so live pool code always lags the factory upgrade. Fork tests must assert the state that is actually live at the pinned block, not the state the factory points to after the upgrade transaction.

### Arbitrum `block.number` semantics

On Arbitrum, `block.number` returns the L1 block number, not the L2 height. An Arbitrum fork pinned at `Constants.ARB_BLOCK` (an L2 height) is correctly pinned — the L2 state at that height is what the EVM runs against — but `block.number` inside the test reports the block's `l1BlockNumber` field, exactly as the `NUMBER` opcode behaves on Arbitrum mainnet.

- Never assert `block.number` against an L2 pin.
- Never "treat as latest".
- Use `block.timestamp` for deadlines and `vm.roll`/`vm.warp` with L1-height semantics in mind.

### Example fork test snippet

```solidity
// Create forks
uint256 ethFork = vm.createSelectFork("ethereum", Constants.MAINNET_BLOCK);
uint256 baseFork = vm.createSelectFork("base", Constants.BASE_BLOCK);

// Use existing contracts (already deployed)
IRigoblockPoolProxyFactory factory = IRigoblockPoolProxyFactory(FACTORY);

// Prank for privileged operations
vm.prank(factoryOwner);
factory.setImplementation(newImplementation);

vm.prank(poolOwner);
pool.someOperation();

// Simulate Across fill: SpokePool calls MulticallHandler.handleV3AcrossMessage()
// which executes encoded multicall instructions that call pool.donate() (ECrosschain extension)
vm.prank(address(spokePool));
IMulticallHandler(multicallHandler).handleV3AcrossMessage(
    outputToken,
    amount,
    relayer,
    abi.encode(instructions)
);
```

## Useful commands

```bash
# Compile
forge build
yarn compile

# Test
forge test -vvv
yarn test

# Test specific file
forge test --match-path test/extensions/AcrossIntegrationFork.t.sol -vvv

# Test with fork
forge test --fork-url $ARBITRUN_RPC_URL -vvv

# Coverage
yarn coverage
```

Required environment variables for fork tests:

```bash
ARBITRUM_RPC_URL=https://...
OPTIMISM_RPC_URL=https://...
BASE_RPC_URL=https://...
```
