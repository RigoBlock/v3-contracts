// EIP-1559 fee caps per live network. Hardhat 3's network config has no fields for
// these, so they live here and are applied to every transaction by the managed-nonce
// helper (src/utils/nonce.ts) at signing time.
export const NETWORK_FEE_CAPS: Record<
  string,
  {maxFeePerGas: bigint; maxPriorityFeePerGas: bigint}
> = {
  mainnet: {maxFeePerGas: 500_000_000n, maxPriorityFeePerGas: 10_000_000n}, // 0.5 / 0.01 gwei
  sepolia: {maxFeePerGas: 5_000_000_000n, maxPriorityFeePerGas: 100_000_000n}, // 5 / 0.1 gwei
  polygon: {maxFeePerGas: 600_000_000_000n, maxPriorityFeePerGas: 50_000_000_000n}, // 600 / 50 gwei
  hyperliquid: {maxFeePerGas: 1_000_000_000n, maxPriorityFeePerGas: 10_000_000n}, // 1 / 0.01 gwei
};
