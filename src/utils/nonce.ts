import type {EIP1193GenericRequest, EIP1193SignerProvider} from "eip-1193";
import {NETWORK_FEE_CAPS} from "./networkFees";

let isEnabled = false;
const managedCounter = new Map<string, number>();
let originalRequest:
  | ((args: {method: string; params?: any}) => Promise<any>)
  | undefined;
let activeFeeCaps: {maxFeePerGas: bigint; maxPriorityFeePerGas: bigint} | undefined;
let localEnvironment = false;

function normalizeAddress(address: string): string {
  return address.toLowerCase();
}

function toHex(value: number | bigint): string {
  return `0x${BigInt(value).toString(16)}`;
}

async function getRealTransactionCount(
  address: string,
  blockTag: string,
): Promise<number> {
  if (!originalRequest) {
    throw new Error("Nonce manager not initialized");
  }
  const result = await originalRequest({
    method: "eth_getTransactionCount",
    params: [address, blockTag],
  });
  return Number(BigInt(result as string));
}

async function ensureCounter(address: string): Promise<number> {
  const normalized = normalizeAddress(address);
  if (managedCounter.has(normalized)) {
    return managedCounter.get(normalized)!;
  }
  const count = await getRealTransactionCount(normalized, "pending");
  managedCounter.set(normalized, count);
  return count;
}

function applyFeeCapsAndNonce(
  transaction: any,
  nonce: number | undefined,
): any {
  const tx = {...transaction};
  if (nonce !== undefined) {
    tx.nonce = toHex(nonce);
  }

  if (activeFeeCaps) {
    // Network config supplies EIP-1559 caps: force a type-2 transaction and
    // drop any legacy gasPrice that may have been added by rocketh.
    delete tx.gasPrice;
    tx.type = "0x2";
    tx.maxFeePerGas = toHex(activeFeeCaps.maxFeePerGas);
    tx.maxPriorityFeePerGas = toHex(activeFeeCaps.maxPriorityFeePerGas);
  } else if (
    tx.maxFeePerGas !== undefined ||
    tx.maxPriorityFeePerGas !== undefined
  ) {
    // No hardcoded caps, but the tx already has EIP-1559 fields. Make sure we
    // don't send conflicting legacy + EIP-1559 fee parameters.
    delete tx.gasPrice;
  }

  return tx;
}

function bumpCounter(address: string, nonce: number): void {
  const normalized = normalizeAddress(address);
  managedCounter.set(
    normalized,
    Math.max(managedCounter.get(normalized) ?? nonce, nonce + 1),
  );
}

function isManagedBlockTag(blockTag?: string): boolean {
  return blockTag === "latest" || blockTag === "pending";
}

/**
 * Wraps a rocketh signer so that, at signing time, transactions get the
 * managed nonce and the network's EIP-1559 fee caps applied. rocketh signs
 * locally (signerOnly) before broadcasting, so this is the last point where
 * the transaction can still be modified.
 */
export function wrapManagedSigner(
  signer: EIP1193SignerProvider,
): EIP1193SignerProvider {
  return {
    request: async (args: EIP1193GenericRequest): Promise<any> => {
      if (
        args.method === "eth_signTransaction" ||
        args.method === "eth_sendTransaction"
      ) {
        const transaction = (args.params as any[])[0];
        const from = transaction.from as string;
        let nonce: number | undefined;
        if (transaction.nonce !== undefined && transaction.nonce !== null) {
          nonce = Number(BigInt(transaction.nonce));
        } else if (managedCounter.has(normalizeAddress(from))) {
          nonce = managedCounter.get(normalizeAddress(from))!;
        }
        const result = await signer.request({
          ...args,
          params: [applyFeeCapsAndNonce(transaction, nonce)],
        } as any);
        if (nonce !== undefined) {
          bumpCounter(from, nonce);
        }
        return result;
      }
      return signer.request(args as any);
    },
  } as EIP1193SignerProvider;
}

interface ManagedNonceNetwork {
  name: string;
  network: {provider: {request: (args: any) => Promise<any>}};
}

export async function enableManagedNonce(
  env: ManagedNonceNetwork,
  deployer: string,
): Promise<void> {
  // The nonce manager is only meant for live/forked deployments. Applying it
  // to the in-memory hardhat network breaks unit tests that rely on
  // snapshots/evm_revert, because the managed counter does not reset with the
  // chain state.
  if (
    localEnvironment ||
    ["hardhat", "localhost", "default"].includes(env.name) ||
    (env as any).network?.chain?.id === 31337
  ) {
    localEnvironment = true;
    return;
  }

  if (isEnabled) {
    return;
  }

  isEnabled = true;

  activeFeeCaps = NETWORK_FEE_CAPS[env.name];

  const networkProvider = env.network.provider as any;
  originalRequest = networkProvider.request.bind(networkProvider);

  // Intercept RPC nonce queries so rocketh's transaction preparation
  // (eth_getTransactionCount with "pending") reads from our shared counter
  // instead of the RPC, preventing two calls from grabbing the same nonce.
  networkProvider.request = async function (args: {
    method: string;
    params?: any;
  }): Promise<any> {
    if (args.method === "eth_getTransactionCount") {
      const [address, blockTag] = args.params as [string, string];
      const normalized = normalizeAddress(address);
      if (isManagedBlockTag(blockTag) && managedCounter.has(normalized)) {
        return toHex(managedCounter.get(normalized)!);
      }
    }
    return originalRequest!(args);
  };

  await ensureCounter(deployer);
}

export async function waitForNonceSync(
  env: ManagedNonceNetwork,
  deployer: string,
): Promise<void> {
  const normalized = normalizeAddress(deployer);
  const managed = managedCounter.get(normalized);
  const onChain = await getRealTransactionCount(normalized, "latest");
  if (managed !== undefined && managed > onChain) {
    console.log(
      `Waiting for nonce sync: managed ${managed}, latest ${onChain}...`,
    );
    await new Promise((resolve) => setTimeout(resolve, 3000));
    await waitForNonceSync(env, deployer);
  }
}
