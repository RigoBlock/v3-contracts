import { AbiCoder, ZeroHash, getCreate2Address, keccak256 } from "ethers";
import { getSingletonFactoryInfo } from "@safe-global/safe-singleton-factory";
import { readArtifact } from "../../rocketh/artifacts.js";
import { deployScript } from "../../rocketh/deploy.js";
import type { Environment } from "../../rocketh/config.js";
import {
  chainConfig,
  GOVERNANCE_HUB_CHAIN,
  governanceCreator,
  governanceHubWormholeChainId,
  governanceName,
  governanceProxy,
  governanceRecovery,
} from "../utils/constants";
import { enableManagedNonce } from "../utils/nonce";

function singletonFactoryAddress(): string {
  const info = getSingletonFactoryInfo(1);
  if (!info) throw new Error("Safe singleton factory info unavailable");
  return info.address;
}

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

    // The hub chain's wormhole configuration must exist: the hub strategy wraps the hub
    // wormhole core contract. The hub Wormhole chain id itself is a single top-level constant
    // (governanceHubWormholeChainId), not per-chain config.
    const hubConfig = chainConfig[GOVERNANCE_HUB_CHAIN];
    if (!hubConfig?.wormhole) {
      throw new Error(
        `chainConfig[${GOVERNANCE_HUB_CHAIN}] must have wormhole configured.`,
      );
    }

    // The cross-chain receiver capability lives inside the governance implementation itself:
    // the governance proxy is the receiver hub on each chain. The hub chain runs the
    // staking-backed sender strategy, the only one that can create local proposals and publish
    // cross-chain messages.
    const hubWormholeChainId = governanceHubWormholeChainId;

    // The governance proxy address is not discovered from a live deployment: it is fully
    // determined by the deterministic factory deployment, the creator key and the governance
    // name (RigoblockGovernanceFactory salts the proxy with keccak256(abi.encode(creator, name))).
    // Re-derive it from the current artifacts and revert unless the recorded `governanceProxy`
    // matches, so a receiver can never be wired to a proxy address the deterministic deployment
    // would not produce — no code or script change is needed when adding a receiver chain.
    const factoryArtifact = await readArtifact("RigoblockGovernanceFactory");
    const proxyArtifact = await readArtifact("RigoblockGovernanceProxy");
    const factoryAddress = getCreate2Address(
      singletonFactoryAddress(),
      ZeroHash,
      keccak256(factoryArtifact.bytecode),
    );
    const proxySalt = keccak256(
      AbiCoder.defaultAbiCoder().encode(
        ["address", "string"],
        [governanceCreator, governanceName],
      ),
    );
    const derivedProxy = getCreate2Address(
      factoryAddress,
      proxySalt,
      keccak256(proxyArtifact.bytecode),
    );
    if (derivedProxy.toLowerCase() !== governanceProxy.toLowerCase()) {
      throw new Error(
        `Recorded governanceProxy ${governanceProxy} does not match the deterministic ` +
          `derivation ${derivedProxy} (factory ${factoryAddress}, creator ${governanceCreator}, ` +
          `name "${governanceName}"). Refusing to deploy: update src/utils/constants.ts.`,
      );
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
      // address passed as an immutable constructor argument; the deterministic derivation
      // check above already proved the configured address is the one the proxy will land at,
      // and this confirms it was actually baked into the deployed bytecode
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
