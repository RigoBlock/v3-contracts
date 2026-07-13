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
const SOURCIFY_RATE_LIMIT_MS = 210;
const SOURCIFY_POLL_INTERVAL_MS = 3000;
const SOURCIFY_POLL_MAX_ATTEMPTS = 40;

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

function httpsPost(
  url: string,
  body: unknown,
): Promise<{ statusCode: number; data: string }> {
  return new Promise((resolve, reject) => {
    const payload = JSON.stringify(body);
    const parsedUrl = new URL(url);
    const options = {
      hostname: parsedUrl.hostname,
      port: parsedUrl.port || 443,
      path: parsedUrl.pathname + parsedUrl.search,
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Content-Length": Buffer.byteLength(payload),
      },
    };

    const req = https.request(options, (res) => {
      let data = "";
      res.on("data", (chunk) => {
        data += chunk;
      });
      res.on("end", () => {
        resolve({ statusCode: res.statusCode || 0, data });
      });
    });

    req.on("error", reject);
    req.write(payload);
    req.end();
  });
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Checks Sourcify v2 verification status for an array of addresses.
 * Returns a map address -> verified.
 */
export async function checkSourcifyBatch(
  hre: HardhatRuntimeEnvironment,
  addresses: string[],
): Promise<Record<string, boolean>> {
  const result: Record<string, boolean> = {};
  if (addresses.length === 0) return result;

  const chainId = await hre.getChainId();

  for (const address of addresses) {
    const url = `${SOURCIFY_ENDPOINT}/v2/contract/${chainId}/${address.toLowerCase()}`;
    try {
      const { statusCode, data } = await httpsGet(url);
      if (statusCode === 200) {
        const parsed = JSON.parse(data) as { match: string | null };
        result[address.toLowerCase()] =
          parsed.match === "exact_match" || parsed.match === "match";
      } else {
        result[address.toLowerCase()] = false;
      }
    } catch (error) {
      console.error(`Sourcify status check failed for ${address}:`, error);
      result[address.toLowerCase()] = false;
    }
    await sleep(SOURCIFY_RATE_LIMIT_MS);
  }

  return result;
}

interface SourcifyVerifyJob {
  verificationId: string;
}

interface SourcifyVerifyStatus {
  isJobCompleted: boolean;
  verificationId: string;
  error?: {
    customCode: string;
    message: string;
  };
  contract?: {
    match: string | null;
  };
}

/**
 * Submits a contract to Sourcify v2 for verification.
 * Constructs the standard JSON input from the deployment metadata and polls
 * until the verification job completes.
 */
export async function verifySourcifyV2(
  hre: HardhatRuntimeEnvironment,
  contractName: string,
  address: string,
  metadataString: string,
): Promise<boolean> {
  const chainId = await hre.getChainId();
  const metadata = JSON.parse(metadataString) as {
    language: string;
    compiler: { version: string };
    settings: {
      compilationTarget: Record<string, string>;
      [key: string]: unknown;
    };
    sources: Record<string, { content: string; [key: string]: unknown }>;
  };

  const sourcePath = Object.keys(metadata.settings.compilationTarget)[0];
  const contractIdentifier = `${sourcePath}:${metadata.settings.compilationTarget[sourcePath]}`;

  // Sourcify's standard JSON input rejects the `license` field that Solidity
  // includes in metadata sources, so we strip it before submission.
  const sources: Record<string, { content: string; [key: string]: unknown }> =
    {};
  for (const [path, source] of Object.entries(metadata.sources)) {
    const { license: _license, ...rest } = source;
    sources[path] = rest;
  }

  // `compilationTarget` is metadata, not a valid compiler settings field, so
  // Sourcify's standard JSON compilation rejects it.
  const { compilationTarget: _compilationTarget, ...settings } =
    metadata.settings;

  const stdJsonInput = {
    language: metadata.language,
    sources,
    settings,
  };

  const body = {
    stdJsonInput,
    compilerVersion: metadata.compiler.version,
    contractIdentifier,
  };

  const submitUrl = `${SOURCIFY_ENDPOINT}/v2/verify/${chainId}/${address.toLowerCase()}`;
  let verificationId: string;

  try {
    const { statusCode, data } = await httpsPost(submitUrl, body);
    if (statusCode === 409) {
      console.log(`${contractName} is already verified on Sourcify.`);
      return true;
    }
    if (statusCode !== 202) {
      throw new Error(`Unexpected Sourcify response ${statusCode}: ${data}`);
    }
    const job = JSON.parse(data) as SourcifyVerifyJob;
    verificationId = job.verificationId;
  } catch (error) {
    console.error(
      `Sourcify submission failed for ${contractName}:`,
      error instanceof Error ? error.message : String(error),
    );
    return false;
  }

  const statusUrl = `${SOURCIFY_ENDPOINT}/v2/verify/${verificationId}`;
  for (let attempt = 0; attempt < SOURCIFY_POLL_MAX_ATTEMPTS; attempt++) {
    await sleep(SOURCIFY_POLL_INTERVAL_MS);
    try {
      const { statusCode, data } = await httpsGet(statusUrl);
      if (statusCode !== 200) {
        console.warn(
          `Sourcify poll returned ${statusCode} for ${contractName}: ${data}`,
        );
        continue;
      }
      const status = JSON.parse(data) as SourcifyVerifyStatus;
      if (!status.isJobCompleted) continue;

      if (status.error) {
        throw new Error(`${status.error.customCode}: ${status.error.message}`);
      }

      const match = status.contract?.match;
      return match === "exact_match" || match === "match";
    } catch (error) {
      console.warn(
        `Sourcify poll failed for ${contractName} (attempt ${attempt + 1}):`,
        error instanceof Error ? error.message : String(error),
      );
    }
  }

  console.error(`Sourcify verification timed out for ${contractName}.`);
  return false;
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
