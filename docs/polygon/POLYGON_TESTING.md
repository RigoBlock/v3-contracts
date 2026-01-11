# Polygon PoS Testing

## Overview

This directory contains tests for Rigoblock v3-contracts on Polygon PoS chain, specifically testing compatibility with POL as the native currency (post-MATIC migration).

## Background

Polygon migrated from MATIC to POL token. The POL token behaves as the native currency (similar to ETH on Ethereum), using `address(0)` as the token address. These tests verify that our protocol works correctly with this new native token model.

## Test Structure

### Files

- `test/fixtures/PolygonDeploymentFixture.sol` - Deployment fixture specifically for Polygon chain
- `test/extensions/PolygonFork.t.sol` - Fork tests for basic pool operations

### Test Coverage

The tests cover basic pool operations:

1. **Native POL Mint** - Minting pool tokens with native POL
2. **Native POL Burn** - Burning pool tokens and receiving POL back
3. **Update Unitary Value** - Updating NAV with POL as base currency
4. **Complete Flow** - Full lifecycle: mint → update NAV → burn
5. **Base Token Verification** - Confirm address(0) is correctly set as base token
6. **Sequential Mints** - Multiple consecutive mints
7. **Pool Receives Native** - Verify pool correctly handles POL transfers

## Running Tests

### Manual Test Execution

Run Polygon-specific tests manually:

```bash
npm run test:polygon
```

Or with yarn:

```bash
yarn test:polygon
```

This runs:
```bash
forge test --match-path test/extensions/PolygonFork.t.sol -vvv --fork-url $POLYGON_MAINNET_RPC_URL
```

### Requirements

- Set `POLYGON_MAINNET_RPC_URL` in your `.env` file
- Polygon RPC endpoint with archive node support (for forking)

### Not Included in CI

These tests are **NOT** run in CI pipelines or standard test scripts. They must be executed manually to verify Polygon compatibility.

## Fixture Design

The `PolygonDeploymentFixture` follows the same pattern as `RealDeploymentFixture` but is simplified for single-chain (Polygon only) testing:

1. Deploys all extensions (EApps, EOracle, EUpgrade, ENavView, EAcrossHandler)
2. Deploys ExtensionsMap with Polygon-specific configuration
3. Deploys new SmartPool implementation
4. Updates factory and creates test pool
5. Funds test accounts with POL and USDC

### Key Differences from Ethereum

- Base token: `address(0)` (POL) instead of WETH or USDC
- Native currency operations use `.mint{value: amount}`
- Wrapped native: WPOL (`Constants.POLY_WPOL`)
- No Across SpokePool (not yet deployed on Polygon)

## Expected Behavior

POL should behave identically to ETH on Ethereum:

- `address(0)` represents the native currency
- Mint operations accept `msg.value`
- Burn operations send native currency back
- Pool can hold and manage native POL
- NAV calculations work correctly with native currency

## Future Work

- Add more complex scenarios (cross-asset pools, rebalancing)
- Test edge cases (large amounts, dust amounts)
- Integration with Polygon-specific protocols
- Test with Across Protocol when deployed on Polygon

## References

- [Polygon POL Migration](https://polygon.technology/blog/polygon-2-0-the-value-layer-of-the-internet-is-now-live)
- [Polygon PoS Documentation](https://docs.polygon.technology/)
- Rigoblock deployment on Polygon: See `deployments/polygon/`
