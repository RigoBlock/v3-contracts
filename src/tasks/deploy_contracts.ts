import { ethers } from "ethers";
import fs from "fs";
import os from "os";
import path from "path";
import { task } from "hardhat/config";
import { ArgumentType } from "hardhat/types/arguments";
import type { NewTaskDefinition } from "hardhat/types/tasks";
import { loadEnvironmentFromHardhat } from "../../rocketh/environment.js";
import {
  checkEtherscanBatch,
  checkSourcifyBatch,
  isVendorVerified,
  verifySourcifyV2,
  loadVerificationStatus,
  markVendorUnverified,
  markVendorVerified,
  resetStatusForChangedContracts,
  saveVerificationStatus,
  type MinimalDeployment,
} from "../utils/verification";

function getErrorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  return String(error);
}

function decodeConstructorArgs(
  deployment: MinimalDeployment & { abi: any[]; argsData: string },
): unknown[] {
  // ethers decodes tuple components as Result objects (Array subclasses). They
  // must stay arrays: stringifying them flattens "0xaddr1,0xaddr2" and the
  // verifier's ABI encoder rejects that with "invalid tuple value" (HHE80017).
  const toPlainValue = (value: unknown): unknown => {
    if (typeof value === "bigint") return value.toString();
    if (Array.isArray(value)) return value.map(toPlainValue);
    return value;
  };
  try {
    const iface = new ethers.Interface(deployment.abi as any);
    const args = ethers.AbiCoder.defaultAbiCoder().decode(
      iface.deploy.inputs,
      deployment.argsData,
    );
    return args.map(toPlainValue);
  } catch (error) {
    console.warn(
      `Failed to decode constructor args for ${deployment.address}:`,
      getErrorMessage(error),
    );
    return [];
  }
}

/**
 * The verify task's `constructorArgs` variadic argument only accepts strings,
 * which cannot express tuple params. `constructorArgsPath` loads an ESM module
 * whose default export is passed through verbatim, preserving nested arrays.
 */
async function writeConstructorArgsModule(args: unknown[]): Promise<string> {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "rb-verify-args-"));
  const file = path.join(dir, "constructor-args.mjs");
  fs.writeFileSync(file, `export default ${JSON.stringify(args)};\n`);
  return file;
}

export const deployContractsTask: NewTaskDefinition = task(
  "deploy-contracts",
  "Deploys and verifies Rigoblock contracts",
)
  .addOption({
    name: "tags",
    type: ArgumentType.STRING_WITHOUT_DEFAULT,
    description:
      "Comma-separated list of hardhat-deploy tags to run (e.g., 'implementation,adapters')",
    defaultValue: undefined,
  })
  .addFlag({
    name: "forceVerify",
    description:
      "Re-check and re-verify all known deployments, ignoring cached status",
  })
  .addFlag({
    name: "skipLocalVerify",
    description: "Skip hardhat-deploy local verification",
  })
  .addFlag({
    name: "skipEtherscan",
    description: "Skip Etherscan verification",
  })
  .addFlag({ name: "skipSourcify", description: "Skip Sourcify verification" })
  .setInlineAction(async (taskArgs, hre) => {
    const connection = await hre.network.getOrCreate();
    const loadEnv = () => loadEnvironmentFromHardhat({ hre, connection });

    console.log("Deploying contracts...");
    const envBefore = await loadEnv();
    const deploymentsBefore = { ...envBefore.deployments };
    await hre.tasks
      .getTask("deploy")
      .run(taskArgs.tags ? { tags: taskArgs.tags } : {});
    const env = await loadEnv();
    const deployments = env.deployments;
    const deploymentNames = Object.keys(deployments);

    if (deploymentNames.length === 0) {
      console.log("No deployments found; nothing to verify.");
      return;
    }

    const changedContracts = deploymentNames.filter((name) => {
      const before = deploymentsBefore[name];
      const after = deployments[name];
      return (
        !before || before.address.toLowerCase() !== after.address.toLowerCase()
      );
    });

    const networkName = connection.networkName;
    const chainId =
      connection.networkConfig.chainId ??
      Number(
        BigInt(
          (await connection.provider.request({
            method: "eth_chainId",
          })) as string,
        ),
      );

    const status = loadVerificationStatus(networkName, chainId);
    resetStatusForChangedContracts(status, deployments);

    const contractsToVerify = taskArgs.forceVerify
      ? deploymentNames
      : deploymentNames.filter((name) => {
          const deployment = deployments[name];
          const isChanged = changedContracts.includes(name);
          const needsSourcify =
            !taskArgs.skipSourcify &&
            !isVendorVerified(status, name, "sourcify", deployment.address);
          const needsEtherscan =
            !taskArgs.skipEtherscan &&
            !isVendorVerified(status, name, "etherscan", deployment.address);
          return isChanged || needsSourcify || needsEtherscan;
        });

    if (contractsToVerify.length === 0) {
      console.log("All contracts are already verified; skipping verification.");
      return;
    }

    console.log(
      `Verifying ${contractsToVerify.length} contract(s): ${contractsToVerify.join(", ")}`,
    );

    if (!taskArgs.skipLocalVerify) {
      console.log("Running local verification...");
      try {
        await hre.tasks.getTask("local-verify").run({});
      } catch (error) {
        console.error("Local verification failed:", getErrorMessage(error));
      }
    }

    // Determine which vendors each contract still needs.
    const needsSourcify: string[] = [];
    const needsEtherscan: string[] = [];

    for (const contractName of contractsToVerify) {
      const deployment = deployments[contractName];
      if (!deployment) continue;

      if (
        !taskArgs.skipSourcify &&
        (taskArgs.forceVerify ||
          !isVendorVerified(
            status,
            contractName,
            "sourcify",
            deployment.address,
          ))
      ) {
        needsSourcify.push(contractName);
      }

      if (
        !taskArgs.skipEtherscan &&
        (taskArgs.forceVerify ||
          !isVendorVerified(
            status,
            contractName,
            "etherscan",
            deployment.address,
          ))
      ) {
        needsEtherscan.push(contractName);
      }
    }

    // Batch-check Sourcify status and verify missing contracts.
    if (!taskArgs.skipSourcify && needsSourcify.length > 0) {
      console.log(
        `Checking Sourcify status for ${needsSourcify.length} contract(s)...`,
      );
      const sourcifyStatuses = await checkSourcifyBatch(
        chainId,
        needsSourcify.map((name) => deployments[name].address),
      );

      for (const contractName of needsSourcify) {
        const deployment = deployments[contractName];
        const address = deployment.address.toLowerCase();

        if (sourcifyStatuses[address]) {
          console.log(`${contractName} is already verified on Sourcify.`);
          markVendorVerified(
            status,
            contractName,
            "sourcify",
            deployment.address,
          );
          continue;
        }

        console.log(`Verifying ${contractName} on Sourcify...`);
        if (!deployment.metadata || typeof deployment.metadata !== "string") {
          console.warn(
            `Skipping Sourcify for ${contractName}: no metadata available.`,
          );
          markVendorUnverified(
            status,
            contractName,
            "sourcify",
            deployment.address,
          );
          continue;
        }

        try {
          const verified = await verifySourcifyV2(
            chainId,
            contractName,
            deployment.address,
            deployment.metadata,
          );
          if (verified) {
            markVendorVerified(
              status,
              contractName,
              "sourcify",
              deployment.address,
            );
            console.log(`Sourcify verification completed for ${contractName}.`);
          } else {
            throw new Error("Sourcify returned non-match status");
          }
        } catch (error) {
          console.error(
            `Sourcify verification failed for ${contractName}:`,
            getErrorMessage(error),
          );
          markVendorUnverified(
            status,
            contractName,
            "sourcify",
            deployment.address,
          );
        }
      }
    }

    // Check Etherscan status and verify missing contracts (rate-limited).
    if (!taskArgs.skipEtherscan && needsEtherscan.length > 0) {
      console.log(
        `Checking Etherscan status for ${needsEtherscan.length} contract(s)...`,
      );
      const etherscanStatuses = await checkEtherscanBatch(
        chainId,
        needsEtherscan.map((name) => deployments[name].address),
      );

      for (const contractName of needsEtherscan) {
        const deployment = deployments[contractName];
        const address = deployment.address.toLowerCase();

        if (etherscanStatuses[address]) {
          console.log(`${contractName} is already verified on Etherscan.`);
          markVendorVerified(
            status,
            contractName,
            "etherscan",
            deployment.address,
          );
          continue;
        }

        console.log(`Verifying ${contractName} on Etherscan...`);
        try {
          let contractPath: string | undefined;
          if (deployment.metadata && typeof deployment.metadata === "string") {
            try {
              const parsedMetadata = JSON.parse(deployment.metadata);
              const compilationTarget =
                parsedMetadata?.settings?.compilationTarget;
              const sourcePath =
                compilationTarget &&
                typeof compilationTarget === "object" &&
                Object.keys(compilationTarget)[0];
              if (sourcePath) {
                contractPath = `${sourcePath}:${contractName}`;
              }
            } catch (parseError) {
              console.warn(
                `Failed to parse metadata for ${contractName}:`,
                getErrorMessage(parseError),
              );
            }
          }

          const constructorArgs = decodeConstructorArgs(deployment as any);
          // The task's variadic constructorArgs only accepts strings; tuple
          // params go through a temp module instead (see writeConstructorArgsModule).
          const viaModule = constructorArgs.some(
            (arg) => typeof arg !== "string",
          );
          await hre.tasks.getTask(["verify", "etherscan"]).run({
            address: deployment.address,
            constructorArgs: viaModule ? [] : constructorArgs,
            constructorArgsPath: viaModule
              ? await writeConstructorArgsModule(constructorArgs)
              : undefined,
            contract: contractPath,
          });
          markVendorVerified(
            status,
            contractName,
            "etherscan",
            deployment.address,
          );
          console.log(
            `Successfully verified ${contractName} on Etherscan at ${deployment.address}`,
          );
        } catch (error) {
          console.error(
            `Failed to verify ${contractName} on Etherscan at ${deployment.address}:`,
            getErrorMessage(error),
          );
          markVendorUnverified(
            status,
            contractName,
            "etherscan",
            deployment.address,
          );
        }
      }
    }

    saveVerificationStatus(networkName, status);
    console.log("Verification status saved.");
  })
  .build();
