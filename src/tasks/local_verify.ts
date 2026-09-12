import {ethers} from "ethers";
import {task} from "hardhat/config";
import type {NewTaskDefinition} from "hardhat/types/tasks";
import {loadSolc} from "../utils/solc";
import {loadEnvironmentFromHardhat} from "../../rocketh/environment.js";

export const localVerifyTask: NewTaskDefinition = task(
  "local-verify",
  "Verifies that the local deployment files correspond to the on chain code",
).setInlineAction(async (_, hre) => {
  const env = await loadEnvironmentFromHardhat({
    hre,
    connection: await hre.network.getOrCreate(),
  });
  const allowedSourceKey = ["keccak256", "content"];
  const deployedContracts = env.deployments;
  for (const contract of Object.keys(deployedContracts)) {
    const deployment = env.get(contract);
    const meta = JSON.parse(deployment.metadata);
    const solcjs = await loadSolc(meta.compiler.version);
    delete meta.compiler;
    delete meta.output;
    delete meta.version;
    const sources = Object.values<any>(meta.sources);
    for (const source of sources) {
      for (const key of Object.keys(source)) {
        if (allowedSourceKey.indexOf(key) < 0) delete source[key];
      }
    }
    meta.settings.outputSelection = {};
    const targets = Object.entries(meta.settings.compilationTarget);
    for (const [key, value] of targets) {
      meta.settings.outputSelection[key] = {};
      meta.settings.outputSelection[key][value as string] = [
        "evm.bytecode",
        "evm.deployedBytecode",
        "metadata",
      ];
    }
    delete meta.settings.compilationTarget;
    const compiled = solcjs.compile(JSON.stringify(meta));
    const output = JSON.parse(compiled);
    for (const [key, value] of targets) {
      const compiledContract = output.contracts[key][value as string];
      const onChainCode = (await env.network.provider.request({
        method: "eth_getCode",
        params: [deployment.address, "latest"],
      })) as string;
      const onchainBytecodeHash = ethers.keccak256(onChainCode);
      const localBytecodeHash = ethers.keccak256(
        `0x${compiledContract.evm.deployedBytecode.object}`,
      );
      const verifySuccess =
        onchainBytecodeHash === localBytecodeHash ? "SUCCESS" : "FAILURE";
      console.log(`Verification status for ${value}: ${verifySuccess}`);
    }
  }
}).build();
