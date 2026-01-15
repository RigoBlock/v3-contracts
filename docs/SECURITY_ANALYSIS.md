# Security Analysis Tools

This document describes the security analysis tools integrated into the v3-contracts project.

## Overview

Security analysis runs automatically on PRs and pushes to `main`/`development` branches. Results appear in:
- **GitHub Security Tab**: [Security Alerts](https://github.com/RigoBlock/v3-contracts/security/code-scanning)
- **PR Comments**: Summary with link to detailed results

## Tools

### 1. Slither Static Analysis

**What it does**: Analyzes Solidity code for vulnerabilities, code quality issues, and best practice violations.

**When it runs**:
- On PR to `main` or `development`
- On push to `main` or `development`
- Only when contracts change (`contracts/protocol/`, `contracts/governance/`, `contracts/staking/`)

**Current scope**: `contracts/protocol/` (core protocol contracts)

**Excluded checks**:
- `naming-convention` - We have our own naming standards
- `solc-version` - Version managed via foundry.toml
- Test files and mocks - Not production code

**How to view results**:
1. Go to [Security Tab](https://github.com/RigoBlock/v3-contracts/security/code-scanning)
2. Filter by "Slither"
3. Click on any alert for details and remediation advice

**Severity levels**:
- 🔴 **High**: Critical vulnerabilities (reentrancy, access control, arithmetic)
- 🟡 **Medium**: Important issues (unchecked returns, dangerous operations)
- 🔵 **Low**: Code quality and optimization suggestions
- ℹ️ **Informational**: Best practices and recommendations

### 2. Foundry Fuzz Testing (Coming Soon)

**What it does**: Generates random inputs to test function behavior under unexpected conditions.

**RPC costs**:
- Non-fork tests: 0 RPC calls
- Fork tests: 1 RPC call per iteration (default 256 runs)
- Configure via `FOUNDRY_FUZZ_RUNS` environment variable

**Example fuzz test**:
```solidity
function testFuzz_Deposit(uint256 amount) public {
    // Foundry will call this 256 times with random amounts
    vm.assume(amount > 0 && amount < type(uint128).max);
    
    deal(token, user, amount);
    vm.prank(user);
    pool.deposit(amount);
    
    assertEq(pool.balanceOf(user), amount);
}
```

**When to use**:
- Input validation edge cases
- Arithmetic overflow/underflow scenarios
- State transition consistency
- Invariant testing

### 3. Formal Verification (Future Consideration)

**Tools available**:
- **Certora Prover**: Industry standard, expensive (~$50k-200k/audit)
- **Halmos**: Symbolic execution, free, limited scope
- **K Framework**: Academic tool, steep learning curve

**Best for**:
- Critical invariants: "total supply = sum of balances"
- Complex mathematical properties
- High-value contracts (e.g., core pool logic)

**Current status**: Not implemented. Cost vs. benefit needs evaluation.

## Running Locally

### Slither (Manual)

```bash
# Install (one-time)
pip3 install --user slither-analyzer

# Add to PATH if needed
export PATH="$HOME/.local/bin:$PATH"

# Run on protocol
slither contracts/protocol/ \
  --filter-paths "contracts/test|contracts/mocks" \
  --exclude naming-convention,solc-version

# Generate markdown report
slither contracts/protocol/ \
  --checklist \
  --filter-paths "contracts/test|contracts/mocks" \
  --exclude naming-convention,solc-version \
  --markdown-root https://github.com/RigoBlock/v3-contracts/blob/$(git rev-parse HEAD)/

# Run on specific contract
slither contracts/protocol/SmartPool.sol

# Focus on high/medium severity only
slither contracts/protocol/ --exclude-low --exclude-informational
```

### Foundry Fuzz Tests

```bash
# Run existing tests with fuzz (default 256 runs)
forge test

# Increase fuzz runs for deeper testing
FOUNDRY_FUZZ_RUNS=10000 forge test

# Run specific fuzz test
forge test --match-test testFuzz_

# Show fuzz run details
forge test --match-test testFuzz_ -vvv
```

## Configuration

### Slither Configuration

Slither reads from `slither.config.json` (if present) or uses CLI args:

```json
{
  "filter_paths": "contracts/test|contracts/mocks",
  "exclude_dependencies": true,
  "exclude_informational": false,
  "exclude_low": false,
  "exclude_medium": false,
  "exclude_high": false,
  "json": "-",
  "sarif": "slither-results.sarif"
}
```

### Foundry Fuzz Configuration

In `foundry.toml`:

```toml
[fuzz]
runs = 256
max_test_rejects = 65536
seed = '0x1'
dictionary_weight = 40
include_storage = true
include_push_bytes = true
```

## Interpreting Results

### Slither Detectors

Common findings and how to handle:

**Reentrancy** (High):
- Use `nonReentrant` modifier
- Follow checks-effects-interactions pattern
- Use `ReentrancyGuard` from OpenZeppelin

**Uninitialized state** (High):
- Initialize all state variables
- Use constructors or initializers properly

**Unchecked return values** (Medium):
- Check return values from external calls
- Use SafeERC20 for token operations

**Unused return values** (Medium):
- Either use the return value or remove it

**Dangerous strict equality** (Medium):
- Avoid `== block.timestamp` or `== balance`
- Use ranges or tolerances

**Shadowing** (Low):
- Rename local variables that shadow state variables

### False Positives

Slither may flag issues that are not problems in context:
1. Review the code path
2. Add inline comments explaining why it's safe:
   ```solidity
   // slither-disable-next-line reentrancy-eth
   (bool success, ) = recipient.call{value: amount}("");
   ```
3. Document in this file if it's a known false positive

## Integration with Development Workflow

1. **Before committing**:
   - Run tests: `forge test`
   - Check compilation: `forge build`
   - Optional: Run slither locally on modified files

2. **In PR**:
   - CI runs slither automatically
   - Review security alerts in PR comments
   - Address high/medium severity findings before merge

3. **After merge**:
   - Security alerts tracked in GitHub Security tab
   - Create issues for findings that need attention
   - Prioritize based on severity and exploitability

## Best Practices

### Writing Secure Code

1. **Input validation**: Always validate external inputs
2. **Access control**: Use appropriate modifiers (`onlyOwner`, `onlyDelegateCall`)
3. **Reentrancy**: Follow checks-effects-interactions, use guards
4. **Integer overflow**: Use Solidity 0.8+ built-in checks
5. **External calls**: Check return values, handle failures
6. **Gas optimization vs security**: Security first, then optimize
7. **Code complexity**: Keep functions simple and auditable

### Testing for Security

1. **Edge cases**: Test boundaries (0, max, min)
2. **Access control**: Test unauthorized access attempts
3. **State transitions**: Verify state consistency
4. **Failure modes**: Test what happens when things fail
5. **Integration**: Test interactions between contracts
6. **Fuzz testing**: Use for input validation
7. **Invariants**: Assert key properties always hold

## Resources

### Documentation
- [Slither Documentation](https://github.com/crytic/slither/wiki)
- [Foundry Book - Fuzz Testing](https://book.getfoundry.sh/forge/fuzz-testing)
- [Smart Contract Security Best Practices](https://consensys.github.io/smart-contract-best-practices/)

### Tools
- [Slither GitHub](https://github.com/crytic/slither)
- [Slither Action](https://github.com/marketplace/actions/slither-action)
- [Foundry](https://github.com/foundry-rs/foundry)

### Learning
- [Ethernaut](https://ethernaut.openzeppelin.com/) - Security challenges
- [Damn Vulnerable DeFi](https://www.damnvulnerabledefi.xyz/) - DeFi security
- [Trail of Bits Blog](https://blog.trailofbits.com/) - Security research

## Troubleshooting

### Slither fails to run

```bash
# Update slither
pip3 install --user --upgrade slither-analyzer

# Clear forge cache
forge clean

# Ensure compilation works
forge build
```

### Too many false positives

Tune exclusions in workflow:
```yaml
slither-args: '--exclude naming-convention,solc-version,similar-names'
```

### CI timeout

Reduce scope or split into multiple jobs:
```yaml
- name: Run Slither on Core
  with:
    target: 'contracts/protocol/core/'
    
- name: Run Slither on Extensions
  with:
    target: 'contracts/protocol/extensions/'
```

## Roadmap

- [x] Slither integration in CI
- [ ] Foundry fuzz tests for critical functions
- [ ] Mutation testing (check test quality)
- [ ] Formal verification for invariants (evaluate cost/benefit)
- [ ] Extend slither to governance and staking contracts
- [ ] Pre-commit hooks for local security checks
- [ ] Continuous monitoring dashboard
