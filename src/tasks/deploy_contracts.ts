import "hardhat-deploy";
import "@nomiclabs/hardhat-ethers";
import { task } from "hardhat/config";

task("deploy-contracts", "Deploys and verifies Rigoblock contracts")
    .setAction(async (_, hre) => {
        console.log("Deploying contracts...");
        await hre.run("deploy")

        console.log("Running local verification...");
        await hre.run("local-verify")

        // Check if Sourcify is enabled (Unichain, for example, not supported by Sourcify yet)
        console.log("Running Sourcify verification...");
        try {
            await hre.run("sourcify", { writeFailingMetadata: true });
            console.log("Sourcify verification completed.");
        } catch (error) {
            console.error("Sourcify verification failed:", error.message);
        }
        await hre.run("sourcify")

        console.log("Verifying contracts on chain explorer...");
        const deployments = await hre.deployments.all();
        for (const [contractName, deployment] of Object.entries(deployments)) {
            const { address, args , metadata } = deployment;
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
                        console.warn(`Failed to parse metadata for ${contractName}:`, parseError.message);
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
                console.error(`Failed to verify ${contractName} at ${address}:`, error.message);
            }
        }
    });

export {}
