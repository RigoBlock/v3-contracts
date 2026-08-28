import { task } from "hardhat/config";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { enableHyperEVMBigBlocks } from "../utils/hyperliquid";

task(
  "hyperliquid:enable-big-blocks",
  "Enable HyperEVM big blocks for the deployer address via a HyperCore action",
)
  .addFlag("testnet", "Use the Hyperliquid testnet API")
  .setAction(async (args: { testnet: boolean }, hre: HardhatRuntimeEnvironment) => {
    const { deployer } = await hre.getNamedAccounts();
    const signer = await hre.ethers.getSigner(deployer);
    await enableHyperEVMBigBlocks(signer, args.testnet);
  });
