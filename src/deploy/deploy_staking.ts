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

    const grgTransferProxy = await env.deploy("ERC20Proxy", {
      account: deployer,
      artifact: await readArtifact("ERC20Proxy"),
      args: [deployer], // Authorizable(_owner)
      }, {deterministic: true});

    const grgVault = await env.deploy("GrgVault", {
      account: deployer,
      artifact: await readArtifact("GrgVault"),
      args: [grgTransferProxy.address, config.rigoToken, deployer], // Authorizable(_owner)
      }, {deterministic: true});

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

    const staking = await env.deploy("Staking", {
      account: deployer,
      artifact: await readArtifact("Staking"),
      args: [grgVault.address, registry.address, config.rigoToken]
      }, {deterministic: true});

    const stakingProxy = await env.deploy("StakingProxy", {
      account: deployer,
      artifact: await readArtifact("StakingProxy"),
      args: [staking.address, deployer], // Authorizable(_owner)
      }, {deterministic: true});

    await env.deploy("AStaking", {
      account: deployer,
      artifact: await readArtifact("AStaking"),
      args: [stakingProxy.address, config.rigoToken, grgTransferProxy.address]
      }, {deterministic: true});

    await env.deploy("InflationL2", {
      account: deployer,
      artifact: await readArtifact("InflationL2"),
      args: [deployer]
      }, {deterministic: true});

    await env.deploy("ProofOfPerformance", {
      account: deployer,
      artifact: await readArtifact("ProofOfPerformance"),
      args: [stakingProxy.address]
      }, {deterministic: true});
  },
  {tags: ["staking", "l2-suite", "main-suite"]},
);
