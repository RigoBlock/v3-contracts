import fs from "fs";
import https from "https";
import path from "path";

export interface MinimalDeployment {
  address: string;
  metadata?: string;
}

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
const ETHERSCAN_POLL_INTERVAL_MS = Number(
  process.env.RB_VERIFY_POLL_INTERVAL_MS ?? 5000,
);
const ETHERSCAN_POLL_MAX_ATTEMPTS = Number(
  process.env.RB_VERIFY_POLL_MAX_ATTEMPTS ?? 40,
);
const ETHERSCAN_POST_TIMEOUT_MS = 60_000;
const ETHERSCAN_POST_MAX_ATTEMPTS = 3;
const SOURCIFY_RATE_LIMIT_MS = 210;
const SOURCIFY_POLL_INTERVAL_MS = 3000;
const SOURCIFY_POLL_MAX_ATTEMPTS = 20;

function getStatusFilePath(networkName: string): string {
  return path.join(".rigo", "verification-status", `${networkName}.json`);
}

export function loadVerificationStatus(
  networkName: string,
  chainId: string | number,
): VerificationStatusFile {
  const filePath = getStatusFilePath(networkName);
  if (!fs.existsSync(filePath)) {
    return {
      network: networkName,
      chainId: chainId.toString(),
      contracts: {},
    };
  }
  try {
    return JSON.parse(
      fs.readFileSync(filePath, "utf8"),
    ) as VerificationStatusFile;
  } catch {
    return {
      network: networkName,
      chainId: chainId.toString(),
      contracts: {},
    };
  }
}

export function saveVerificationStatus(
  networkName: string,
  status: VerificationStatusFile,
): void {
  const filePath = getStatusFilePath(networkName);
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, JSON.stringify(status, null, 2));
}

/**
 * Resets verification status for contracts whose deployed address has changed.
 * This ensures redeployed contracts are re-verified.
 */
export function resetStatusForChangedContracts(
  status: VerificationStatusFile,
  deployments: Record<string, MinimalDeployment>,
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
    const req = https
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
    req.setTimeout(30_000, () => {
      req.destroy(new Error("Request timed out after 30000ms"));
    });
  });
}

function httpsPostForm(
  url: string,
  params: Record<string, string>,
): Promise<{ statusCode: number; data: string }> {
  return new Promise((resolve, reject) => {
    const payload = new URLSearchParams(params).toString();
    const parsedUrl = new URL(url);
    const options = {
      hostname: parsedUrl.hostname,
      port: parsedUrl.port || 443,
      path: parsedUrl.pathname + parsedUrl.search,
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
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

    req.setTimeout(ETHERSCAN_POST_TIMEOUT_MS, () => {
      req.destroy(
        new Error(`Request timed out after ${ETHERSCAN_POST_TIMEOUT_MS}ms`),
      );
    });
    req.on("error", reject);
    req.write(payload);
    req.end();
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
  chainId: string | number,
  addresses: string[],
): Promise<Record<string, boolean>> {
  const result: Record<string, boolean> = {};
  if (addresses.length === 0) return result;

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

class NonRetryableSourcifyError extends Error {}

function formatSourcifyError(contractName: string, customCode: string): string {
  if (customCode === "extra_file_input_bug") {
    return `Sourcify cannot verify ${contractName}: known metadata issue (Sourcify #618).`;
  }
  return `Sourcify cannot verify ${contractName}: ${customCode}.`;
}

/**
 * Submits a contract to Sourcify v2 for verification.
 * Constructs the standard JSON input from the deployment metadata and polls
 * until the verification job completes.
 */
export async function verifySourcifyV2(
  chainId: string | number,
  contractName: string,
  address: string,
  metadataString: string,
): Promise<boolean> {
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
  const nonRetryableCodes = new Set([
    "no_match",
    "extra_file_input_bug",
    "compiler_error",
    "invalid_constructor_arguments",
  ]);

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
        if (status.error.customCode === "already_verified") {
          console.log(`${contractName} is already verified on Sourcify.`);
          return true;
        }
        if (nonRetryableCodes.has(status.error.customCode)) {
          throw new NonRetryableSourcifyError(
            formatSourcifyError(contractName, status.error.customCode),
          );
        }
        console.warn(
          `Sourcify poll retryable error for ${contractName}: ${status.error.customCode}`,
        );
        continue;
      }

      const match = status.contract?.match;
      return match === "exact_match" || match === "match";
    } catch (error) {
      if (error instanceof NonRetryableSourcifyError) {
        throw error;
      }
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
  chainId: string | number,
  address: string,
): Promise<boolean> {
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
  chainId: string | number,
  addresses: string[],
): Promise<Record<string, boolean>> {
  const result: Record<string, boolean> = {};
  for (const address of addresses) {
    result[address.toLowerCase()] = await checkEtherscan(chainId, address);
    await sleep(ETHERSCAN_RATE_LIMIT_MS);
  }
  return result;
}

export interface EtherscanStdJsonDeployment {
  address: string;
  contractName: string;
  sourceName?: string;
  inputSourceName?: string;
  argsData?: string;
  buildInfoId?: string;
}

interface BuildInfoFile {
  solcLongVersion: string;
  input: {
    language: string;
    sources: Record<string, { content?: string; [key: string]: unknown }>;
    settings: {
      remappings?: string[];
      [key: string]: unknown;
    };
  };
  userSourceNameMap?: Record<string, string>;
}

const IMPORT_STATEMENT_RE = /import\s+(?:[^'";]*?\s+from\s+)?["']([^"']+)["']/g;

function normalizeSourcePath(p: string): string {
  return path.posix.normalize(p);
}

function resolveImport(
  importingFile: string,
  specifier: string,
  sourceKeys: Set<string>,
  remappings: string[],
): string | undefined {
  if (specifier.startsWith("./") || specifier.startsWith("../")) {
    const resolved = normalizeSourcePath(
      path.posix.join(path.posix.dirname(importingFile), specifier),
    );
    return sourceKeys.has(resolved) ? resolved : undefined;
  }

  // Remappings follow solc's `<context>:<prefix>=<target>` format; the
  // context restricts which importing files a remapping applies to. Longest
  // matching prefix wins.
  let best: { prefix: string; target: string } | undefined;
  for (const remapping of remappings) {
    const eq = remapping.indexOf("=");
    if (eq === -1) continue;
    const lhs = remapping.slice(0, eq);
    const target = remapping.slice(eq + 1);
    const ctxEnd = lhs.indexOf(":");
    const context = ctxEnd === -1 ? "" : lhs.slice(0, ctxEnd);
    const prefix = ctxEnd === -1 ? lhs : lhs.slice(ctxEnd + 1);
    if (context && !importingFile.startsWith(context)) continue;
    if (!specifier.startsWith(prefix)) continue;
    if (!best || prefix.length > best.prefix.length) {
      best = { prefix, target };
    }
  }
  if (best) {
    const resolved = best.target + specifier.slice(best.prefix.length);
    return sourceKeys.has(resolved) ? resolved : undefined;
  }
  return sourceKeys.has(specifier) ? specifier : undefined;
}

function computeImportClosure(
  rootKey: string,
  sources: Record<string, { content?: string }>,
  remappings: string[],
): Set<string> {
  const sourceKeys = new Set(Object.keys(sources));
  const closure = new Set<string>();
  const queue = [rootKey];
  while (queue.length > 0) {
    const key = queue.pop() as string;
    if (closure.has(key)) continue;
    closure.add(key);
    const content = sources[key]?.content;
    if (typeof content !== "string") continue;
    for (const match of content.matchAll(IMPORT_STATEMENT_RE)) {
      const dep = resolveImport(key, match[1], sourceKeys, remappings);
      if (dep && !closure.has(dep)) queue.push(dep);
    }
  }
  return closure;
}

interface LocatedBuildInfo {
  buildInfo: BuildInfoFile;
  rootKey: string;
}

function tryRootSourceKey(
  deployment: EtherscanStdJsonDeployment,
  sources: Record<string, unknown>,
  userSourceNameMap: Record<string, string>,
): string | undefined {
  if (deployment.inputSourceName && sources[deployment.inputSourceName]) {
    return deployment.inputSourceName;
  }
  if (deployment.sourceName) {
    const mapped = userSourceNameMap[deployment.sourceName];
    if (mapped && sources[mapped]) return mapped;
    if (sources[deployment.sourceName]) return deployment.sourceName;
    const suffix = `/${deployment.sourceName}`;
    return Object.keys(sources).find((k) => k.endsWith(suffix));
  }
  return undefined;
}

/**
 * Locates the build-info unit that compiled the contract. Prefers the unit
 * recorded at deployment time; if that file is missing (e.g. verifying old
 * deployments after a rebuild on another branch), falls back to the smallest
 * unit in the current build that contains the contract source.
 */
function locateBuildInfo(
  deployment: EtherscanStdJsonDeployment,
  buildInfoDir: string,
): LocatedBuildInfo {
  const recordedPath = deployment.buildInfoId
    ? path.join(buildInfoDir, `${deployment.buildInfoId}.json`)
    : undefined;
  if (recordedPath && fs.existsSync(recordedPath)) {
    const buildInfo = JSON.parse(
      fs.readFileSync(recordedPath, "utf8"),
    ) as BuildInfoFile;
    const rootKey = tryRootSourceKey(
      deployment,
      buildInfo.input.sources,
      buildInfo.userSourceNameMap ?? {},
    );
    if (rootKey) return { buildInfo, rootKey };
  }

  if (!deployment.sourceName) {
    throw new Error(
      `No build-info found for ${deployment.contractName} and no sourceName recorded`,
    );
  }

  let best: { filePath: string; sourceCount: number } | undefined;
  for (const fileName of fs.readdirSync(buildInfoDir)) {
    if (
      !fileName.startsWith("solc-") ||
      !fileName.endsWith(".json") ||
      fileName.endsWith(".output.json")
    ) {
      continue;
    }
    const filePath = path.join(buildInfoDir, fileName);
    // Cheap pre-filter before paying for a full JSON parse.
    if (!fs.readFileSync(filePath, "utf8").includes(deployment.sourceName)) {
      continue;
    }
    const buildInfo = JSON.parse(
      fs.readFileSync(filePath, "utf8"),
    ) as BuildInfoFile;
    const rootKey = tryRootSourceKey(
      deployment,
      buildInfo.input.sources,
      buildInfo.userSourceNameMap ?? {},
    );
    if (!rootKey) continue;
    const sourceCount = Object.keys(buildInfo.input.sources).length;
    if (!best || sourceCount < best.sourceCount) {
      best = { filePath, sourceCount };
    }
  }

  if (!best) {
    throw new Error(
      `Cannot find a build-info unit containing ${deployment.sourceName} in ${buildInfoDir}`,
    );
  }
  console.warn(
    `Build-info ${deployment.buildInfoId ?? "unknown"} for ${deployment.contractName} not found; ` +
      `falling back to ${path.basename(best.filePath)} (${best.sourceCount} sources)`,
  );
  const buildInfo = JSON.parse(
    fs.readFileSync(best.filePath, "utf8"),
  ) as BuildInfoFile;
  const rootKey = tryRootSourceKey(
    deployment,
    buildInfo.input.sources,
    buildInfo.userSourceNameMap ?? {},
  ) as string;
  return { buildInfo, rootKey };
}

/**
 * Submits a contract to Etherscan (v2 API) using a standard-json input built
 * from the deployment's own build-info unit, trimmed to the contract's import
 * closure. Identical source content + identical settings + the same compiler
 * reproduce the deployed executable code; hardhat-verify cannot be used here
 * because it re-derives the full compilation job (hundreds of unrelated
 * sources), which Etherscan rejects or leaves pending indefinitely.
 */
export async function verifyEtherscanStdJson(
  chainId: string | number,
  deployment: EtherscanStdJsonDeployment,
  buildInfoDir: string,
): Promise<void> {
  const apiKey = process.env.ETHERSCAN_API_KEY;
  if (!apiKey) {
    throw new Error("ETHERSCAN_API_KEY not set");
  }
  if (!deployment.buildInfoId && !deployment.sourceName) {
    throw new Error(
      `Neither buildInfoId nor sourceName recorded for ${deployment.contractName}; cannot rebuild the compiler input`,
    );
  }

  const { buildInfo, rootKey } = locateBuildInfo(deployment, buildInfoDir);

  const { sources } = buildInfo.input;
  const remappings = buildInfo.input.settings.remappings ?? [];
  const closure = computeImportClosure(rootKey, sources, remappings);

  const trimmedSources: Record<string, { content: string }> = {};
  for (const key of closure) {
    const content = sources[key]?.content;
    if (typeof content !== "string") {
      throw new Error(`Source ${key} has no inline content in build-info`);
    }
    trimmedSources[key] = { content };
  }

  const stdJsonInput = {
    language: buildInfo.input.language,
    sources: trimmedSources,
    settings: buildInfo.input.settings,
  };

  await submitEtherscanVerification(chainId, {
    contractName: deployment.contractName,
    address: deployment.address,
    sourceCode: JSON.stringify(stdJsonInput),
    contractNamePath: `${rootKey}:${deployment.contractName}`,
    compilerVersion: `v${buildInfo.solcLongVersion}`,
    constructorArguments: (deployment.argsData ?? "").replace(/^0x/, ""),
  });
}

export interface EtherscanSubmission {
  contractName: string;
  address: string;
  sourceCode: string;
  contractNamePath: string;
  compilerVersion: string;
  constructorArguments: string;
}

/**
 * Submits a standard-json input to Etherscan (v2 API) and polls until the
 * verification job settles. The v2 API expects chainid and apikey in the query
 * string (same as hardhat-verify); sending them in the POST body is rejected.
 */
export async function submitEtherscanVerification(
  chainId: string | number,
  submission: EtherscanSubmission,
): Promise<void> {
  const apiKey = process.env.ETHERSCAN_API_KEY;
  if (!apiKey) {
    throw new Error("ETHERSCAN_API_KEY not set");
  }

  const query = new URLSearchParams({
    chainid: chainId.toString(),
    apikey: apiKey,
  }).toString();
  const submitUrl = `${ETHERSCAN_V2_ENDPOINT}?${query}`;
  const submitParams: Record<string, string> = {
    module: "contract",
    action: "verifysourcecode",
    contractaddress: submission.address,
    sourceCode: submission.sourceCode,
    codeformat: "solidity-standard-json-input",
    contractname: submission.contractNamePath,
    compilerversion: submission.compilerVersion,
    constructorArguements: submission.constructorArguments,
  };

  let guid: string | undefined;
  let lastError: unknown;
  for (
    let attempt = 0;
    attempt < ETHERSCAN_POST_MAX_ATTEMPTS && !guid;
    attempt++
  ) {
    try {
      const { statusCode, data } = await httpsPostForm(submitUrl, submitParams);
      const parsed = JSON.parse(data) as {
        status: string;
        message: string;
        result: string;
      };
      if (parsed.status === "1") {
        guid = parsed.result;
      } else if (
        `${parsed.message} ${parsed.result}`.match(/already verified/i)
      ) {
        console.log(`${submission.contractName} is already verified.`);
        return;
      } else {
        throw new Error(
          `Etherscan rejected the submission (HTTP ${statusCode}): ${parsed.message} - ${parsed.result}`,
        );
      }
    } catch (error) {
      lastError = error;
      if (attempt + 1 < ETHERSCAN_POST_MAX_ATTEMPTS) {
        console.warn(
          `Etherscan submission failed for ${submission.contractName} (attempt ${attempt + 1}); retrying...`,
        );
        await sleep(ETHERSCAN_RATE_LIMIT_MS);
      }
    }
  }
  if (!guid) {
    throw lastError instanceof Error
      ? lastError
      : new Error("Etherscan submission failed");
  }

  for (let attempt = 0; attempt < ETHERSCAN_POLL_MAX_ATTEMPTS; attempt++) {
    await sleep(ETHERSCAN_POLL_INTERVAL_MS);
    const statusUrl =
      `${ETHERSCAN_V2_ENDPOINT}?chainid=${chainId}&module=contract` +
      `&action=checkverifystatus&guid=${guid}&apikey=${apiKey}`;
    let resultText = "";
    try {
      const { data } = await httpsGet(statusUrl);
      resultText = (JSON.parse(data) as { result: string }).result;
    } catch (error) {
      console.warn(
        `Etherscan status poll failed for ${submission.contractName} (attempt ${attempt + 1}):`,
        error instanceof Error ? error.message : String(error),
      );
      continue;
    }
    if (
      resultText.startsWith("Pass") ||
      resultText.match(/already verified/i)
    ) {
      return;
    }
    if (resultText.includes("Pending")) {
      continue;
    }
    throw new Error(`Etherscan verification failed: ${resultText}`);
  }

  throw new Error(
    `Etherscan verification timed out for ${submission.contractName} after ${ETHERSCAN_POLL_MAX_ATTEMPTS} status polls`,
  );
}
