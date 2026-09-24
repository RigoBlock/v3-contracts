# Contract Code Size Tracking

The EVM caps contract deployed bytecode at **24576 bytes** (EIP-170). Any contract at or
above the limit cannot be deployed — the deployment transaction reverts. Several Rigoblock
contracts run close to the edge, so every PR must verify that the contracts it touches
still fit.

## Rules for AI agents and contributors

1. **Measure after any change to `contracts/`** that can alter deployed bytecode of a
   contract in the table below — this includes edits to libraries, since a library is
   compiled into the bytecode of every contract that imports it (see AGENTS.md,
   "ExtensionsMap Salt" for the same reasoning applied to salt bumps).
2. **Use the production compiler settings.** Sizes are only meaningful when measured with
   the same settings used for deployment and CI:
   - solc 0.8.28, evmVersion `cancun`
   - optimizer enabled, **200 runs** (NOT Foundry's `optimizer_runs = 1_000_000` — that
     profile produces different bytecode and different sizes)
   - **no viaIR** (except the `MockAcrossSpokePool` override, which is not deployed)
3. **Update the table in the same PR.** Copy the measured sizes into the table below,
   update the "Last measured" date, and mention the change in the PR description. A PR
   that changes deployed bytecode without updating the table fails review.
4. **Never merge with zero headroom.** If any contract reaches the limit, the change must
   be refactored (move logic to a library already compiled in, split the contract, or
   reduce bytecode) before merging.
5. **Flag tight contracts.** `SmartPool`, `ENavView`, and `EApps` have the least
   headroom. If a PR reduces their headroom by more than ~500 bytes, call it out in the
   PR description so the shrink can be planned deliberately rather than discovered at
   deploy time.

## How to measure

```bash
SOLIDITY_SETTINGS='{"optimizer":{"enabled":true,"runs":200}}' npx hardhat compile
npx hardhat codesize --skipcompile true
```

The second command prints every contract's deployed size. Alternatively, to check a
single contract:

```bash
npx hardhat codesize --skipcompile true --contractname SmartPool
```

## Deployed bytecode sizes

Production settings: optimizer 200 runs, no viaIR, evmVersion cancun.
Limit: 24576 bytes per contract. Last measured: 2026-09-24 (branch `fix/uniswap-router-adapter`).

### Implementation and factory

| Contract                  | Size (bytes) | Headroom | % of limit |
| ------------------------- | -----------: | -------: | ---------: |
| SmartPool                 |        24321 |      255 |     98.96% |
| RigoblockPoolProxyFactory |         4796 |    19780 |     19.52% |

### Extensions (stored in ExtensionsMap — a size change forces a salt bump)

| Contract     | Size (bytes) | Headroom | % of limit |
| ------------ | -----------: | -------: | ---------: |
| ENavView     |        24320 |      256 |     98.96% |
| EApps        |        22668 |     1908 |     92.24% |
| EGmxCallback |         6227 |    18349 |     25.34% |
| ECrosschain  |         5175 |    19401 |     21.06% |
| EOracle      |         4609 |    19967 |     18.75% |
| EUpgrade     |          697 |    23879 |      2.84% |
| EERC20       |          421 |    24155 |      1.71% |

### Deps

| Contract      | Size (bytes) | Headroom | % of limit |
| ------------- | -----------: | -------: | ---------: |
| Authority     |         3408 |    21168 |     13.87% |
| ExtensionsMap |         1497 |    23079 |      6.09% |

### Adapters (stored in Authority — no salt bump needed on change)

| Contract        | Size (bytes) | Headroom | % of limit |
| --------------- | -----------: | -------: | ---------: |
| AGmxV2          |        17580 |     6996 |     71.53% |
| AUniswapRouter  |        12772 |    11804 |     51.97% |
| AIntents        |        11466 |    13110 |     46.66% |
| AHyperliquid    |         8091 |    16485 |     32.92% |
| A0xRouter       |         5069 |    19507 |     20.63% |
| AStaking        |         2151 |    22425 |      8.75% |
| AUniswap        |         1359 |    23217 |      5.53% |
| AMulticall      |         1168 |    23408 |      4.75% |
| AGovernance     |         1550 |    23026 |      6.31% |
| AUniswapDecoder |            0 |    24576 |      0.00% |

`AUniswapDecoder` is a library — its code is compiled into consumers, so it has no
deployed instance of its own.

### Staking and governance

| Contract            | Size (bytes) | Headroom | % of limit |
| ------------------- | -----------: | -------: | ---------: |
| Staking             |        22820 |     1756 |     92.85% |
| GrgVault            |         4392 |    20184 |     17.87% |
| RigoblockGovernance |        11253 |    13323 |     45.79% |

## Notes

- Sizes above are Hardhat's `deployedBytecode` length (metadata hash included), which is
  exactly what lands on-chain.
- Foundry test builds use `optimizer_runs = 1_000_000` and report different sizes. Never
  copy numbers from `forge build` output into this table.
- The proxy contracts (`RigoblockPoolProxy`, ~135 bytes) are excluded — they are tiny and
  pinned at solc 0.8.17.
