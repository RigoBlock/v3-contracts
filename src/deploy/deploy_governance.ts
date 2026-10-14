import { readArtifact } from "../../rocketh/artifacts.js";
import { deployScript } from "../../rocketh/deploy.js";
import type { Environment } from "../../rocketh/config.js";
import {
  chainConfig,
  GOVERNANCE_HUB_CHAIN,
  governanceProxy,
  governanceRecovery,
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
    const isHub = chainId === GOVERNANCE_HUB_CHAIN;

    // the hub chain's wormhole configuration must exist: the implementation constructor takes
    // the hub wormhole chain id, and the hub strategy wraps the hub wormhole core contract
    const hubConfig = chainConfig[GOVERNANCE_HUB_CHAIN];
    if (!hubConfig?.wormhole || !hubConfig.wormholeChainId) {
      throw new Error(
        `chainConfig[${GOVERNANCE_HUB_CHAIN}] must have wormhole and wormholeChainId configured.`,
      );
    }

    // The cross-chain receiver capability lives inside the governance implementation itself:
    // the governance proxy is the receiver hub on each chain, and its deterministic address is
    // known in advance on every chain. The hub chain runs the staking-backed sender strategy,
    // which is the only one that can create local proposals and publish cross-chain messages.
    // The Wormhole SDK only provides compile-time per-chain constants (no EVM-chainid to
    // wormhole-chainid conversion), so the id is read from the hub chain's deploy config.
    const hubWormholeChainId = hubConfig.wormholeChainId;

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
        // identical on every chain, so the deterministic implementation address is unchanged
        args: [hubWormholeChainId],
      },
      { deterministic: true },
    );

    if (isHub) {
      await env.deploy(
        "RigoblockGovernanceStrategy",
        {
          account: deployer,
          artifact: await readArtifact("RigoblockGovernanceStrategy"),
          args: [config.stakingProxy, config.wormhole],
        },
        { deterministic: true },
      );
    } else {
      const receiverStrategy = await env.deploy(
        "WormholeReceiverStrategy",
        {
          account: deployer,
          artifact: await readArtifact("WormholeReceiverStrategy"),
          args: [config.wormhole, governanceProxy, governanceRecovery],
        },
        { deterministic: true },
      );

      // the receiver strategy authenticates recovery vetoes against the governance proxy
      // address passed as an immutable constructor argument; a mismatch would leave the
      // veto unreachable
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
