import "hardhat-deploy";
import "@nomiclabs/hardhat-ethers";
import { task } from "hardhat/config";

task("deploy-contracts", "Deploys and verifies Rigoblock contracts")
    .setAction(async (_, hre) => {
        await hre.run("deploy")
        await hre.run("local-verify")
        await hre.run("sourcify")
        await hre.run("etherscan-verify", { forceLicense: true, license: 'Apache-2.0'})
    });

export { }
