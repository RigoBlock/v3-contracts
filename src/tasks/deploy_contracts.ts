import "hardhat-deploy";
import "@nomiclabs/hardhat-ethers";
import { task, types } from "hardhat/config";
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
} from "../utils/verification";

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
  .addFlag(
    "forceVerify",
    "Re-check and re-verify all known deployments, ignoring cached status",
  )
  .addFlag("skipLocalVerify", "Skip hardhat-deploy local verification")
  .addFlag("skipEtherscan", "Skip Etherscan verification")
  .addFlag("skipSourcify", "Skip Sourcify verification")
  .setAction(async (taskArgs, hre) => {
    const deployOptions = taskArgs.tags ? { tags: taskArgs.tags } : {};

    console.log("Deploying contracts...");
    const deploymentsBefore = await hre.deployments.all();
    await hre.run("deploy", deployOptions);
    const deployments = await hre.deployments.all();
    const deploymentNames = Object.keys(deployments);

    if (deploymentNames.length === 0) {
      console.log("No deployments found; nothing to verify.");
      return;
    }

    const changedContracts = deploymentNames.filter((name) => {
      const before = deploymentsBefore[name];
      const after = deployments[name];
      return !before || before.address.toLowerCase() !== after.address.toLowerCase();
    });

    const status = loadVerificationStatus(hre);
    resetStatusForChangedContracts(status, deployments);

    const contractsToVerify = taskArgs.forceVerify
      ? deploymentNames
      : deploymentNames.filter((name) => {
          const deployment = deployments[name];
          const isChanged = changedContracts.includes(name);
          const needsSourcify =
            !taskArgs.skipSourcify &&
            !isVendorVerified(
              status,
              name,
              "sourcify",
              deployment.address,
            );
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
        await hre.run("local-verify");
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
          !isVendorVerified(status, contractName, "sourcify", deployment.address))
      ) {
        needsSourcify.push(contractName);
      }

      if (
        !taskArgs.skipEtherscan &&
        (taskArgs.forceVerify ||
          !isVendorVerified(status, contractName, "etherscan", deployment.address))
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
        hre,
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
            hre,
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
            console.log(
              `Sourcify verification completed for ${contractName}.`,
            );
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
        hre,
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
              const compilationTarget = parsedMetadata?.settings?.compilationTarget;
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

          await hre.run("verify:verify", {
            address: deployment.address,
            constructorArguments: deployment.args || [],
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

    saveVerificationStatus(hre, status);
    console.log("Verification status saved.");
  });

export {};
