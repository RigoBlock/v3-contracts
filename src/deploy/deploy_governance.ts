import { ethers } from "ethers";
import { readArtifact } from "../../rocketh/artifacts.js";
import { deployScript } from "../../rocketh/deploy.js";
import type { Environment } from "../../rocketh/config.js";
import { chainConfig, governanceProxy } from "../utils/constants";
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

    // Must be set explicitly per chain; the deploy reverts when the mode is missing or unknown.
    if (!config.governanceMode) {
      throw new Error(
        `Governance mode not configured for chain ${chainId}. Set governanceMode in src/utils/constants.ts ` +
          '("sender" for Ethereum mainnet, "dual" or "receiver" for other chains).',
      );
    }
    // The script is authoritative for the chain-to-mode mapping: mainnet is the only sender
    // governance, HyperEVM and BSC are receiver-only, and every other chain must be dual.
    const expectedModeByChain: Record<number, string> = {
      1: "sender",
      999: "receiver",
      56: "receiver",
    };
    const expectedMode = expectedModeByChain[chainId] ?? "dual";
    if (config.governanceMode !== expectedMode) {
      throw new Error(
        `Governance mode for chain ${chainId} must be "${expectedMode}", got "${config.governanceMode}".`,
      );
    }
    const governanceModeByConfig: Record<string, number> = {
      sender: 0, // GovernanceMode.Sender
      dual: 1, // GovernanceMode.Dual
      receiver: 2, // GovernanceMode.Receiver
    };
    const governanceMode = governanceModeByConfig[config.governanceMode];
    if (governanceMode === undefined) {
      throw new Error(
        `Unknown governance mode "${config.governanceMode}" for chain ${chainId}`,
      );
    }

    // Receiver chains carry a recovery address, validated here so a chain can never
    // ship with an unset or unintended configuration.
    const isReceiver = config.governanceMode === "receiver";
    if (isReceiver && !config.governanceRecovery) {
      throw new Error(
        `governanceRecovery must be set for receiver chain ${chainId}. ` +
          "Set it to the recovery multisig in src/utils/constants.ts.",
      );
    }
    if (!isReceiver && config.governanceRecovery) {
      throw new Error(
        `governanceRecovery must not be set for non-receiver chain ${chainId} (${config.governanceMode}).`,
      );
    }
    const recoveryAddress = isReceiver
      ? (config.governanceRecovery as string)
      : "0x0000000000000000000000000000000000000000";

    // The cross-chain receiver capability lives inside the governance implementation itself:
    // the governance proxy is the receiver hub on each chain, and its deterministic address is
    // known in advance on every chain. A chain opts in as a receiver by deploying its governance
    // strategy with a Wormhole address (config.wormhole); chains with a zero Wormhole address are
    // senders-only. Only the sender mode (mainnet) can create cross-chain proposals.
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

    const strategy = await env.deploy(
      "RigoblockGovernanceStrategy",
      {
        account: deployer,
        artifact: await readArtifact("RigoblockGovernanceStrategy"),
        args: [
          // the constructor zeroes the staking proxy on receiver chains; pass zero here too so
          // the deterministic address never depends on a staking entry a receiver chain ignores
          isReceiver ? ethers.ZeroAddress : config.stakingProxy,
          config.wormhole,
          config.wormholeChainId,
          governanceMode,
          recoveryAddress,
        ],
      },
      { deterministic: true },
    );

    // the strategy authenticates recovery vetoes against the chain-independent governance
    // proxy address baked into its runtime; a mismatch would leave the veto unreachable
    const onchainCode = (await env.network.provider.request({
      method: "eth_getCode",
      params: [strategy.address as `0x${string}`, "latest"],
    })) as string;

    if (
      !onchainCode
        .toLowerCase()
        .includes(governanceProxy.slice(2).toLowerCase())
    ) {
      throw new Error(
        `Deployed RigoblockGovernanceStrategy at ${strategy.address} does not reference governance ` +
          `proxy ${governanceProxy}; rejectRecover would be unreachable.`,
      );
    }
  },
  { tags: ["governance", "l2-suite", "main-suite"] },
);
