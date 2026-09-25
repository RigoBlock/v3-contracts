import { ethers } from "ethers";
import { readArtifact } from "../../rocketh/artifacts.js";
import { deployScript } from "../../rocketh/deploy.js";
import type { Environment } from "../../rocketh/config.js";
import { chainConfig, mainnetGovernanceProxy } from "../utils/constants";
import { enableManagedNonce } from "../utils/nonce";

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

    // Mainnet is the source of cross-chain governance messages: deploy the full
    // governance suite (factory, implementation, strategy) there.
    if (chainId === 1) {
      await env.deploy(
        "RigoblockGovernanceFactory",
        {
          account: deployer,
          artifact: await readArtifact("RigoblockGovernanceFactory"),
          args: [],
        },
        { deterministic: true },
      );

      await env.deploy(
        "RigoblockGovernance",
        {
          account: deployer,
          artifact: await readArtifact("RigoblockGovernance"),
          args: [],
        },
        { deterministic: true },
      );

      await env.deploy(
        "RigoblockGovernanceStrategy",
        {
          account: deployer,
          artifact: await readArtifact("RigoblockGovernanceStrategy"),
          args: [config.stakingProxy, config.wormhole, config.wormholeChainId],
        },
        { deterministic: true },
      );
      return;
    }

    // Receiver chains execute governance actions coming from Ethereum mainnet.
    // This includes chains with no staking proxy (e.g. HyperEVM) and chains where
    // the local staking proxy is being deprecated for governance (e.g. Unichain).
    if (config.wormhole != "0x0000000000000000000000000000000000000000") {
      await env.deploy(
        "CrosschainReceiver",
        {
          account: deployer,
          artifact: await readArtifact("CrosschainReceiver"),
          args: [
            config.wormhole,
            2,
            ethers.zeroPadValue(mainnetGovernanceProxy, 32),
          ],
        },
        { deterministic: true },
      );
      return;
    }

    // Fallback for legacy L2s without Wormhole config: keep deploying the full
    // governance suite until they are migrated to cross-chain governance.
    await env.deploy(
      "RigoblockGovernanceFactory",
      {
        account: deployer,
        artifact: await readArtifact("RigoblockGovernanceFactory"),
        args: [],
      },
      { deterministic: true },
    );

    await env.deploy(
      "RigoblockGovernance",
      {
        account: deployer,
        artifact: await readArtifact("RigoblockGovernance"),
        args: [],
      },
      { deterministic: true },
    );

    await env.deploy(
      "RigoblockGovernanceStrategy",
      {
        account: deployer,
        artifact: await readArtifact("RigoblockGovernanceStrategy"),
        args: [config.stakingProxy, config.wormhole, config.wormholeChainId],
      },
      { deterministic: true },
    );
  },
  { tags: ["governance", "l2-suite", "main-suite"] },
);
