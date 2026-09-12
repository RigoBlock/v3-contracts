import { readArtifact } from "../../rocketh/artifacts.js";
import { deployScript } from "../../rocketh/deploy.js";
import type { Environment } from "../../rocketh/config.js";
import { enableManagedNonce } from "../utils/nonce";

export default deployScript(
  async (env: Environment) => {
    const deployer = env.namedAccounts.deployer;
    await enableManagedNonce(env, deployer);

    const authority = await env.deploy(
      "Authority",
      {
        account: deployer,
        artifact: await readArtifact("Authority"),
        args: [deployer],
      },
      { deterministic: true },
    );

    const registry = await env.deploy(
      "PoolRegistry",
      {
        account: deployer,
        artifact: await readArtifact("PoolRegistry"),
        args: [authority.address, deployer], // Rigoblock Dao
      },
      { deterministic: true },
    );

    const originalImplementationAddress =
      "0xeb0c08Ad44af89BcBB5Ed6dD28caD452311B8516";
    await env.deploy(
      "RigoblockPoolProxyFactory",
      {
        account: deployer,
        artifact: await readArtifact("RigoblockPoolProxyFactory"),
        args: [originalImplementationAddress, registry.address],
      },
      { deterministic: true },
    );

    // Notice: pool implementation requires deployed extensionsMap address (same on all chains)
    // On chains where the factory is still owned by the deployer (sepolia, hyperliquid,
    // fresh chains), uncomment to deploy the pool implementation and point the factory at it.
    // setImplementation reverts once governance owns the factory — hence commented by default.
    /*const extensionsMapAddress = "0x0000000000000000000000000000000000000000"; // deployed extensionsMap
    const tokenJar = "0x0000000000000000000000000000000000000000"; // chainConfig[chainId].tokenJar
    const poolImplementation = await env.deploy("SmartPool", {
      account: deployer,
      artifact: await readArtifact("SmartPool"),
      args: [authority.address, extensionsMapAddress, tokenJar]
      }, {deterministic: true});
    const currentImplementation = (await env.readByName("RigoblockPoolProxyFactory", {
      functionName: "implementation",
    })) as string;
    if (currentImplementation.toLowerCase() !== poolImplementation.address.toLowerCase()) {
      await env.executeByName("RigoblockPoolProxyFactory", {
        account: deployer,
        functionName: "setImplementation",
        args: [poolImplementation.address],
      });
    }*/
  },
  { tags: ["factory", "pool-deps", "l2-suite", "main-suite"] },
);
