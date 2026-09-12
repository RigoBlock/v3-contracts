import fs from "fs";
import path from "path";
import {overrideTask} from "hardhat/config";
import type {TaskDefinition} from "hardhat/types/tasks";

/**
 * solc omits the top-level `contracts` key from the standard-json output of a
 * compilation job that contains no contracts (type-only files like
 * contracts/protocol/types/*.sol or deps/Kyc.sol). Hardhat 3 stores that
 * output verbatim in build-info files, but EDR's ContractDecoder requires the
 * field and hard-fails when an edr-simulated network connection is created
 * (i.e. every `hardhat test` / `hardhat deploy` run). Until upstream tolerates
 * a missing `contracts` key, normalize the freshly written build-info outputs:
 * add an empty `contracts` object where it is absent.
 */
async function normalizeBuildInfoOutputs(artifactsPath: string): Promise<void> {
  const buildInfoDir = path.join(artifactsPath, "build-info");
  if (!fs.existsSync(buildInfoDir)) {
    return;
  }
  for (const file of fs.readdirSync(buildInfoDir)) {
    if (!file.endsWith(".output.json")) {
      continue;
    }
    const filePath = path.join(buildInfoDir, file);
    // `contracts` is the first key of `output` when present, so a head read is
    // enough to skip the (large) well-formed files.
    const handle = fs.openSync(filePath, "r");
    let head = "";
    try {
      const buffer = Buffer.alloc(2048);
      const bytesRead = fs.readSync(handle, buffer, 0, 2048, 0);
      head = buffer.subarray(0, bytesRead).toString("utf8");
    } finally {
      fs.closeSync(handle);
    }
    if (/["']output["']\s*:\s*\{\s*["']contracts["']/.test(head)) {
      continue;
    }
    const data = JSON.parse(fs.readFileSync(filePath, "utf8"));
    if (
      typeof data.output === "object" &&
      data.output !== null &&
      !("contracts" in data.output)
    ) {
      data.output.contracts = {};
      fs.writeFileSync(filePath, JSON.stringify(data));
      console.log(`normalized build-info output: ${file}`);
    }
  }
}

export const buildInfoFixTask: TaskDefinition = overrideTask("build")
  .setInlineAction(async (args: any, hre: any, runSuper: any) => {
    const result = await runSuper(args);
    await normalizeBuildInfoOutputs(hre.config.paths.artifacts);
    return result;
  })
  .build();
