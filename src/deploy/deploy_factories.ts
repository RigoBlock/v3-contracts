import {readArtifact} from "../../rocketh/artifacts.js";
import {deployScript} from "../../rocketh/deploy.js";
import type {Environment} from "../../rocketh/config.js";
import {enableManagedNonce} from "../utils/nonce";

export default deployScript(
  async (env: Environment) => {
    const deployer = env.namedAccounts.deployer;
    await enableManagedNonce(env, deployer);

    const authority = await env.deploy("Authority", {
      account: deployer,
      artifact: await readArtifact("Authority"),
      args: [deployer]
      }, {deterministic: true});

    const registry = await env.deploy("PoolRegistry", {
      account: deployer,
      artifact: await readArtifact("PoolRegistry"),
      args: [authority.address, deployer], // Rigoblock Dao
      }, {deterministic: true});

    const originalImplementationAddress =
      "0xeb0c08Ad44af89BcBB5Ed6dD28caD452311B8516";
    await env.deploy("RigoblockPoolProxyFactory", {
      account: deployer,
      artifact: await readArtifact("RigoblockPoolProxyFactory"),
      args: [originalImplementationAddress, registry.address]
      }, {deterministic: true});

    // Notice: pool implementation requires deployed extensionsMap address (same on all chains)
  },
  {tags: ["factory", "pool-deps", "l2-suite", "main-suite"]},
);
