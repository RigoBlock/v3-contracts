import fs from "fs";
import https from "https";
import path from "path";
import { Deployment, HardhatRuntimeEnvironment } from "hardhat-deploy/types";

export interface VendorStatus {
  verified: boolean;
  address: string;
  lastChecked: number;
}

export interface ContractVerificationStatus {
  etherscan?: VendorStatus;
  sourcify?: VendorStatus;
}

export interface VerificationStatusFile {
  network: string;
  chainId: string;
  contracts: Record<string, ContractVerificationStatus>;
}

const SOURCIFY_ENDPOINT = "https://sourcify.dev/server";
const ETHERSCAN_V2_ENDPOINT = "https://api.etherscan.io/v2/api";
const ETHERSCAN_RATE_LIMIT_MS = 210; // ~5 requests/sec for free API keys

function getStatusFilePath(hre: HardhatRuntimeEnvironment): string {
  return path.join(
    ".rigo",
    "verification-status",
    `${hre.network.name}.json`,
  );
}

export function loadVerificationStatus(
  hre: HardhatRuntimeEnvironment,
): VerificationStatusFile {
  const filePath = getStatusFilePath(hre);
  if (!fs.existsSync(filePath)) {
    return {
      network: hre.network.name,
      chainId: hre.network.config.chainId?.toString() || "",
      contracts: {},
    };
  }
  try {
    return JSON.parse(
      fs.readFileSync(filePath, "utf8"),
    ) as VerificationStatusFile;
  } catch {
    return {
      network: hre.network.name,
      chainId: hre.network.config.chainId?.toString() || "",
      contracts: {},
    };
  }
}

export function saveVerificationStatus(
  hre: HardhatRuntimeEnvironment,
  status: VerificationStatusFile,
): void {
  const filePath = getStatusFilePath(hre);
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, JSON.stringify(status, null, 2));
}

/**
 * Resets verification status for contracts whose deployed address has changed.
 * This ensures redeployed contracts are re-verified.
 */
export function resetStatusForChangedContracts(
  status: VerificationStatusFile,
  deployments: Record<string, Deployment>,
): void {
  for (const [name, contractStatus] of Object.entries(status.contracts)) {
    const deployment = deployments[name];
    if (!deployment) {
      // Contract no longer tracked; keep status for reference or delete it.
      continue;
    }

    const currentAddress = deployment.address.toLowerCase();
    if (
      contractStatus.etherscan &&
      contractStatus.etherscan.address.toLowerCase() !== currentAddress
    ) {
      delete contractStatus.etherscan;
    }
    if (
      contractStatus.sourcify &&
      contractStatus.sourcify.address.toLowerCase() !== currentAddress
    ) {
      delete contractStatus.sourcify;
    }
  }
}

export function isVendorVerified(
  status: VerificationStatusFile,
  contractName: string,
  vendor: "etherscan" | "sourcify",
  currentAddress: string,
): boolean {
  const vendorStatus = status.contracts[contractName]?.[vendor];
  if (!vendorStatus) return false;
  return (
    vendorStatus.verified &&
    vendorStatus.address.toLowerCase() === currentAddress.toLowerCase()
  );
}

export function markVendorVerified(
  status: VerificationStatusFile,
  contractName: string,
  vendor: "etherscan" | "sourcify",
  address: string,
): void {
  if (!status.contracts[contractName]) {
    status.contracts[contractName] = {};
  }
  status.contracts[contractName][vendor] = {
    verified: true,
    address,
    lastChecked: Date.now(),
  };
}

export function markVendorUnverified(
  status: VerificationStatusFile,
  contractName: string,
  vendor: "etherscan" | "sourcify",
  address: string,
): void {
  if (!status.contracts[contractName]) {
    status.contracts[contractName] = {};
  }
  status.contracts[contractName][vendor] = {
    verified: false,
    address,
    lastChecked: Date.now(),
  };
}

function httpsGet(url: string): Promise<{ statusCode: number; data: string }> {
  return new Promise((resolve, reject) => {
    https
      .get(url, (res) => {
        let data = "";
        res.on("data", (chunk) => {
          data += chunk;
        });
        res.on("end", () => {
          resolve({ statusCode: res.statusCode || 0, data });
        });
      })
      .on("error", reject);
  });
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Checks Sourcify verification status for an array of addresses in one request.
 * Returns a map address -> verified.
 */
export async function checkSourcifyBatch(
  hre: HardhatRuntimeEnvironment,
  addresses: string[],
): Promise<Record<string, boolean>> {
  const result: Record<string, boolean> = {};
  if (addresses.length === 0) return result;

  const chainId = await hre.getChainId();
  const url = `${SOURCIFY_ENDPOINT}/checkByAddresses?addresses=${addresses.join(",")}&chainIds=${chainId}`;

  try {
    const { data } = await httpsGet(url);
    const parsed = JSON.parse(data) as Array<{
      address: string;
      status: string;
      chainIds: string[];
    }>;
    for (const item of parsed) {
      result[item.address.toLowerCase()] =
        item.status === "perfect" || item.status === "partial";
    }
  } catch (error) {
    console.error("Sourcify batch check failed:", error);
  }

  return result;
}

/**
 * Checks Etherscan verification status for a single address.
 * Uses Etherscan v2 API (chainid parameter).
 */
export async function checkEtherscan(
  hre: HardhatRuntimeEnvironment,
  address: string,
): Promise<boolean> {
  const chainId = await hre.getChainId();
  const apiKey = process.env.ETHERSCAN_API_KEY;
  if (!apiKey) {
    console.warn("ETHERSCAN_API_KEY not set; skipping Etherscan status check.");
    return false;
  }

  const url = `${ETHERSCAN_V2_ENDPOINT}?chainid=${chainId}&module=contract&action=getabi&address=${address}&apikey=${apiKey}`;

  try {
    const { data } = await httpsGet(url);
    const parsed = JSON.parse(data) as { status: string; message: string };
    return parsed.status === "1";
  } catch (error) {
    console.error(`Etherscan check failed for ${address}:`, error);
    return false;
  }
}

/**
 * Throttles Etherscan checks to respect rate limits.
 */
export async function checkEtherscanBatch(
  hre: HardhatRuntimeEnvironment,
  addresses: string[],
): Promise<Record<string, boolean>> {
  const result: Record<string, boolean> = {};
  for (const address of addresses) {
    result[address.toLowerCase()] = await checkEtherscan(hre, address);
    await sleep(ETHERSCAN_RATE_LIMIT_MS);
  }
  return result;
}
