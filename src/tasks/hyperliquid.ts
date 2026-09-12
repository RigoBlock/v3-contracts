import {task} from "hardhat/config";
import type {NewTaskDefinition} from "hardhat/types/tasks";
import {enableHyperEVMBigBlocks} from "../utils/hyperliquid";
import {loadEnvironmentFromHardhat} from "../../rocketh/environment.js";

export const hyperliquidBigBlocksTask: NewTaskDefinition = task(
  "hyperliquid:enable-big-blocks",
  "Enable HyperEVM big blocks for the deployer address via a HyperCore action",
)
  .addFlag({name: "testnet", description: "Use the Hyperliquid testnet API"})
  .setInlineAction(async (args: {testnet: boolean}, hre) => {
    const env = await loadEnvironmentFromHardhat({
      hre,
      connection: await hre.network.getOrCreate(),
    });
    const {ethers} = await hre.network.getOrCreate();
    const signer = await ethers.getSigner(env.namedAccounts.deployer);
    await enableHyperEVMBigBlocks(signer, args.testnet);
  })
  .build();
