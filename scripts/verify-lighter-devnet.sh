#!/usr/bin/env bash
# Batch-verify the LighterEVM devnet deployment (chainId 19529) on the devnet
# Blockscout explorer via `npx hardhat verify blockscout` (the `blockscout`
# subcommand scopes the run to the keyless Blockscout provider — see
# hardhat.config.ts `chainDescriptors`).
#
# Requirements:
#   - LIGHTER_DEVNET_API_URL (and LIGHTER_DEVNET_BROWSER_URL) in .env
#   - LIGHTER_RPC_URL or LIGHTER_DEVNET_EXPLORER_URL in .env
#   - the build/ artifacts produced by the deploy (same build-info the deploy used)
#
# Note: SOLIDITY_SETTINGS is unset for every call because the value committed
# in .env is a JS-literal, not JSON, and crashes hardhat's config loader.
#
# Usage: ./scripts/verify-lighter-devnet.sh [deployments-dir]
set -uo pipefail
cd "$(dirname "$0")/.."
DEPLOYMENTS_DIR="${1:-deployments/lighter}"

failures=0
for f in "$DEPLOYMENTS_DIR"/*.json; do
  name=$(basename "$f" .json)
  addr=$(jq -r .address "$f")
  args=$(node -e '
    const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const a = d.argsData || "0x";
    const out = [];
    for (let i = 2; i < a.length; i += 64) out.push("0x" + a.slice(i, i + 64));
    console.log(out.join(" "));
  ' "$f")
  echo "=== $name @ $addr"
  # shellcheck disable=SC2086
  if ! env -u SOLIDITY_SETTINGS npx hardhat verify blockscout --network lighterevm-devnet "$addr" $args; then
    failures=$((failures + 1))
  fi
done

echo
if [ "$failures" -eq 0 ]; then
  echo "All contracts verified."
else
  echo "$failures contract(s) failed verification — see output above."
  exit 1
fi
