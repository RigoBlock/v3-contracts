import { readArtifact } from "../../rocketh/artifacts.js";
import { deployScript } from "../../rocketh/deploy.js";
import type { Environment } from "../../rocketh/config.js";
import {
  chainConfig,
  GOVERNANCE_HUB_CHAIN,
  governanceProxy,
} from "../utils/constants";
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

    // The script is authoritative for the chain-to-mode mapping: the hub chain (Ethereum
    // mainnet) is the only sender governance, every other chain is a receiver.
    const isSender = chainId === GOVERNANCE_HUB_CHAIN;
    if (config.governanceMode !== (isSender ? "sender" : "receiver")) {
      throw new Error(
        `Governance mode for chain ${chainId} must be "${isSender ? "sender" : "receiver"}", got "${config.governanceMode}".`,
      );
    }

    // Receiver chains carry a recovery address, validated here so a chain can never
    // ship with an unset or unintended configuration.
    if (!isSender && !config.governanceRecovery) {
      throw new Error(
        `governanceRecovery must be set for receiver chain ${chainId}. ` +
          "Set it to the recovery multisig in src/utils/constants.ts.",
      );
    }
    if (isSender && config.governanceRecovery) {
      throw new Error(
        `governanceRecovery must not be set for sender chain ${chainId}.`,
      );
    }

    // The cross-chain receiver capability lives inside the governance implementation itself:
    // the governance proxy is the receiver hub on each chain, and its deterministic address is
    // known in advance on every chain. The hub chain runs the staking-backed sender strategy,
    // which is the only one that can create local proposals and publish cross-chain messages.
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

    if (isSender) {
      await env.deploy(
        "RigoblockGovernanceStrategy",
        {
          account: deployer,
          artifact: await readArtifact("RigoblockGovernanceStrategy"),
          args: [config.stakingProxy, config.wormhole, config.wormholeChainId],
        },
        { deterministic: true },
      );
    } else {
      const receiverStrategy = await env.deploy(
        "WormholeReceiverStrategy",
        {
          account: deployer,
          artifact: await readArtifact("WormholeReceiverStrategy"),
          args: [
            config.wormhole,
            config.wormholeChainId,
            config.governanceRecovery as string,
          ],
        },
        { deterministic: true },
      );

      // the receiver strategy authenticates recovery vetoes against the chain-independent
      // governance proxy address baked into its runtime; a mismatch would leave the veto
      // unreachable
      const onchainCode = (await env.network.provider.request({
        method: "eth_getCode",
        params: [receiverStrategy.address as `0x${string}`, "latest"],
      })) as string;

      if (
        !onchainCode
          .toLowerCase()
          .includes(governanceProxy.slice(2).toLowerCase())
      ) {
        throw new Error(
          `Deployed WormholeReceiverStrategy at ${receiverStrategy.address} does not reference governance ` +
            `proxy ${governanceProxy}; rejectRecover would be unreachable.`,
        );
      }
    }
  },
  { tags: ["governance", "l2-suite", "main-suite"] },
);
