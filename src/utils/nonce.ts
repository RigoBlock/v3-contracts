import { BigNumber, Wallet } from "ethers";
import { JsonRpcSigner } from "@ethersproject/providers";
import { HardhatRuntimeEnvironment } from "hardhat/types";

let isEnabled = false;
const managedCounter = new Map<string, number>();
let originalNetworkSend:
  | ((method: string, params: any[]) => Promise<any>)
  | undefined;

function normalizeAddress(address: string): string {
  return address.toLowerCase();
}

async function getRealTransactionCount(
  address: string,
  blockTag: string,
): Promise<number> {
  if (!originalNetworkSend) {
    throw new Error("Nonce manager not initialized");
  }
  const result = await originalNetworkSend("eth_getTransactionCount", [
    address,
    blockTag,
  ]);
  return BigNumber.from(result).toNumber();
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

function applyTransactionOverrides(
  transaction: any,
  nonce: number,
  maxFeePerGas: number | undefined,
  maxPriorityFeePerGas: number | undefined,
): any {
  const tx = { ...transaction, nonce };

  if (maxFeePerGas !== undefined || maxPriorityFeePerGas !== undefined) {
    // Network config supplies EIP-1559 caps: force a type-2 transaction and
    // drop any legacy gasPrice that may have been added by Hardhat.
    delete tx.gasPrice;
    if (maxFeePerGas !== undefined) {
      tx.maxFeePerGas = maxFeePerGas;
    }
    if (maxPriorityFeePerGas !== undefined) {
      tx.maxPriorityFeePerGas = maxPriorityFeePerGas;
    }
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

function isManagedBlockTag(blockTag?: string): boolean {
  return blockTag === "latest" || blockTag === "pending";
}

export async function enableManagedNonce(
  hre: HardhatRuntimeEnvironment,
  deployer: string,
): Promise<void> {
  if (isEnabled) {
    return;
  }
  isEnabled = true;

  const networkProvider = hre.network.provider;
  originalNetworkSend = networkProvider.send.bind(networkProvider);

  const networkConfig = hre.network.config as {
    maxFeePerGas?: number;
    maxPriorityFeePerGas?: number;
  };
  const configMaxFee = networkConfig.maxFeePerGas;
  const configPriorityFee = networkConfig.maxPriorityFeePerGas;

  // Intercept RPC nonce queries so hardhat-deploy's internal nonce resolution
  // (deploy/execute use "latest") reads from our shared counter instead of
  // the RPC, preventing two calls from grabbing the same nonce.
  (networkProvider as any).send = async function (
    method: string,
    params: any[],
  ): Promise<any> {
    if (method === "eth_getTransactionCount") {
      const [address, blockTag] = params;
      const normalized = normalizeAddress(address);
      if (isManagedBlockTag(blockTag) && managedCounter.has(normalized)) {
        return BigNumber.from(managedCounter.get(normalized)!).toHexString();
      }
    }
    return originalNetworkSend!(method, params);
  };

  const originalJsonRpcSend = JsonRpcSigner.prototype.sendTransaction;
  JsonRpcSigner.prototype.sendTransaction = async function (
    transaction: any,
  ): Promise<any> {
    const address = normalizeAddress(await this.getAddress());
    let nonce: number;
    if (transaction.nonce !== undefined && transaction.nonce !== null) {
      nonce = BigNumber.from(transaction.nonce).toNumber();
    } else {
      nonce = await ensureCounter(address);
    }
    const response = await originalJsonRpcSend.call(
      this,
      applyTransactionOverrides(transaction, nonce, configMaxFee, configPriorityFee),
    );
    managedCounter.set(
      address,
      Math.max(managedCounter.get(address) ?? nonce, nonce + 1),
    );
    return response;
  };

  const originalWalletSend = Wallet.prototype.sendTransaction;
  Wallet.prototype.sendTransaction = async function (
    transaction: any,
  ): Promise<any> {
    const address = normalizeAddress(await this.getAddress());
    let nonce: number;
    if (transaction.nonce !== undefined && transaction.nonce !== null) {
      nonce = BigNumber.from(transaction.nonce).toNumber();
    } else {
      nonce = await ensureCounter(address);
    }
    const response = await originalWalletSend.call(
      this,
      applyTransactionOverrides(transaction, nonce, configMaxFee, configPriorityFee),
    );
    managedCounter.set(
      address,
      Math.max(managedCounter.get(address) ?? nonce, nonce + 1),
    );
    return response;
  };

  await ensureCounter(deployer);
}

export async function waitForNonceSync(
  hre: HardhatRuntimeEnvironment,
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
    await waitForNonceSync(hre, deployer);
  }
}
