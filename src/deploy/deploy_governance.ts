import {readArtifact} from "../../rocketh/artifacts.js";
import {deployScript} from "../../rocketh/deploy.js";
import type {Environment} from "../../rocketh/config.js";
import {chainConfig} from "../utils/constants";
import {enableManagedNonce} from "../utils/nonce";

export default deployScript(
  async (env: Environment) => {
    const deployer = env.namedAccounts.deployer;
    await enableManagedNonce(env, deployer);

    const chainId = env.network.chain.id;
    if (!chainConfig[chainId]) {
      if (chainId === 31337) {
        console.log("Skipping for Hardhat Network");
        return;
      } else {
        throw new Error(`Unsupported network: Chain ID ${chainId}`);
      }
    }

    const config = chainConfig[chainId];

    await env.deploy("RigoblockGovernanceFactory", {
      account: deployer,
      artifact: await readArtifact("RigoblockGovernanceFactory"),
      args: []
      }, {deterministic: true});

    await env.deploy("RigoblockGovernance", {
      account: deployer,
      artifact: await readArtifact("RigoblockGovernance"),
      args: []
      }, {deterministic: true});

    await env.deploy("RigoblockGovernanceStrategy", {
      account: deployer,
      artifact: await readArtifact("RigoblockGovernanceStrategy"),
      args: [config.stakingProxy]
      }, {deterministic: true});
  },
  {tags: ["governance", "l2-suite", "main-suite"]},
);
