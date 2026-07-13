import "hardhat-deploy";
import "@nomiclabs/hardhat-ethers";
import { task, types } from "hardhat/config";

function getErrorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  return String(error);
}

task("deploy-contracts", "Deploys and verifies Rigoblock contracts")
  .addOptionalParam(
    "tags",
    "Comma-separated list of hardhat-deploy tags to run (e.g., 'implementation,adapters')",
    undefined,
    types.string,
  )
  .setAction(async (taskArgs, hre) => {
    const deployOptions = taskArgs.tags ? { tags: taskArgs.tags } : {};

    console.log("Deploying contracts...");
    await hre.run("deploy", deployOptions);

    console.log("Running local verification...");
    await hre.run("local-verify");

    // Sourcify supports Unichain (chainId 130) for verification. If this fails,
    // it is usually a transient RPC/network issue or an outdated verification plugin.
    console.log("Running Sourcify verification...");
    try {
      await hre.run("sourcify", { writeFailingMetadata: true });
      console.log("Sourcify verification completed.");
    } catch (error) {
      console.error("Sourcify verification failed:", getErrorMessage(error));
    }

    console.log("Verifying contracts on chain explorer...");
    const deployments = await hre.deployments.all();
    for (const [contractName, deployment] of Object.entries(deployments)) {
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

        // Run verification
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
