import "hardhat-deploy";
import "@nomiclabs/hardhat-ethers";
import { Deployment } from "hardhat-deploy/types";
import { task, types } from "hardhat/config";

function getErrorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  return String(error);
}

/**
 * Returns the list of contract names whose deployment changed between `before`
 * and `after`. A contract is considered changed if it did not exist before or
 * if its address changed (hardhat-deploy redeploys when bytecode changes).
 */
function getChangedContracts(
  before: Record<string, Deployment>,
  after: Record<string, Deployment>,
): string[] {
  const changed: string[] = [];
  for (const [name, deployment] of Object.entries(after)) {
    const beforeDeployment = before[name];
    if (!beforeDeployment || beforeDeployment.address !== deployment.address) {
      changed.push(name);
    }
  }
  return changed;
}

task("deploy-contracts", "Deploys and verifies Rigoblock contracts")
  .addOptionalParam(
    "tags",
    "Comma-separated list of hardhat-deploy tags to run (e.g., 'implementation,adapters')",
    undefined,
    types.string,
  )
  .addFlag(
    "forceVerify",
    "Verify all known deployments, not only contracts redeployed in this run",
  )
  .setAction(async (taskArgs, hre) => {
    const deployOptions = taskArgs.tags ? { tags: taskArgs.tags } : {};

    console.log("Deploying contracts...");
    const deploymentsBefore = await hre.deployments.all();
    await hre.run("deploy", deployOptions);
    const deploymentsAfter = await hre.deployments.all();

    const contractsToVerify = taskArgs.forceVerify
      ? Object.keys(deploymentsAfter)
      : getChangedContracts(deploymentsBefore, deploymentsAfter);

    if (contractsToVerify.length === 0) {
      console.log("No contracts were redeployed; skipping verification.");
      return;
    }

    console.log(
      `Contracts to verify (${contractsToVerify.length}):`,
      contractsToVerify.join(", "),
    );

    console.log("Running local verification...");
    try {
      await hre.run("local-verify");
    } catch (error) {
      console.error("Local verification failed:", getErrorMessage(error));
    }

    // Sourcify supports Unichain (chainId 130) for verification. If a call
    // fails, it is usually a transient RPC/network issue or an outdated plugin.
    console.log("Running Sourcify verification...");
    for (const contractName of contractsToVerify) {
      try {
        await hre.run("sourcify", {
          contractName,
          writeFailingMetadata: true,
        });
        console.log(`Sourcify verification completed for ${contractName}.`);
      } catch (error) {
        console.error(
          `Sourcify verification failed for ${contractName}:`,
          getErrorMessage(error),
        );
      }
    }

    console.log("Verifying contracts on chain explorer...");
    for (const contractName of contractsToVerify) {
      const deployment = deploymentsAfter[contractName];
      if (!deployment) {
        console.warn(`No deployment found for ${contractName}, skipping.`);
        continue;
      }

      const { address, args, metadata } = deployment;
      console.log(`Verifying ${contractName} at ${address}...`);

      try {
        let contractPath: string | undefined;
        if (metadata && typeof metadata === "string") {
          try {
            const parsedMetadata = JSON.parse(metadata);
            const sourcePath = parsedMetadata?.settings?.compilationTarget?.[0];
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

        await hre.run("verify:verify", {
          address,
          constructorArguments: args || [],
          contract: contractPath,
          forceLicense: true,
          license: "Apache-2.0",
        });
        console.log(`Successfully verified ${contractName} at ${address}`);
      } catch (error) {
        console.error(
          `Failed to verify ${contractName} at ${address}:`,
          getErrorMessage(error),
        );
      }
    }
  });

export {};
