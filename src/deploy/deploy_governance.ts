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
    const zeroAddress = "0x0000000000000000000000000000000000000000";

    // Receiver chains execute governance actions coming from Ethereum mainnet.
    // This includes chains with no staking proxy (e.g. HyperEVM) and chains where
    // the local staking proxy is being deprecated for governance (e.g. Unichain).
    // Mainnet (chainId 1) is the source of cross-chain governance messages, so it
    // always gets the full suite below, as do legacy L2s without Wormhole config
    // until they are migrated to cross-chain governance.
    if (chainId !== 1 && config.wormhole != zeroAddress) {
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
