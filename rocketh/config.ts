import * as deployExtension from "@rocketh/deploy";
import * as readExecuteExtension from "@rocketh/read-execute";
import { privateKey } from "@rocketh/signer";
import { getSingletonFactoryInfo } from "@safe-global/safe-singleton-factory";
import type { Signer } from "@rocketh/core/types";
import type {
  ChainUserConfig,
  EnhancedEnvironment,
  SignerProtocolFunction,
  UnknownDeployments,
  UserConfig,
} from "rocketh/types";
import { wrapManagedSigner } from "../src/utils/nonce";

// Wrap the privateKey protocol so signed transactions pick up the managed
// nonce counter and the network's EIP-1559 fee caps (see src/utils/nonce.ts).
const managedPrivateKey: SignerProtocolFunction = async (
  protocolString,
): Promise<Signer> => {
  const base = await privateKey(protocolString);
  return { ...base, signer: wrapManagedSigner(base.signer) } as Signer;
};

// All production chains (mainnet, L2s, hyperliquid, sepolia) were deployed through
// Safe's singleton factory — this is what produces the shared cross-chain addresses
// (e.g. Authority at 0xe35129A1E0BdB913CF6Fd8332E9d3533b5F41472 on every chain,
// formerly gated behind CUSTOM_DETERMINISTIC_DEPLOYMENT="true"). Local/dev chains
// stay on rocketh's built-in default factory.
export const PRODUCTION_CHAIN_IDS = [
  1, 10, 56, 137, 8453, 42161, 130, 999, 11155111, 19529,
];

function safeSingletonFactoryDeployment(chainId: number): ChainUserConfig {
  // The factory's signed deployment transaction is chain-independent (the same raw tx is
  // replayed on every chain), so for chains the catalog does not know yet (LighterEVM devnet)
  // we reuse the mainnet entry; LighterEVM also preinstalls the factory at the same address.
  const info = getSingletonFactoryInfo(chainId) ?? getSingletonFactoryInfo(1);
  if (!info)
    throw new Error(`No Safe singleton factory info for chain ${chainId}`);
  return {
    deterministicDeployment: {
      factory: info.address as `0x${string}`,
      deployer: info.signerAddress as `0x${string}`,
      funding: (BigInt(info.gasLimit) * BigInt(info.gasPrice)).toString(),
      signedTx: info.transaction as `0x${string}`,
    },
  };
}

const chains = Object.fromEntries(
  PRODUCTION_CHAIN_IDS.map((id) => [id, safeSingletonFactoryDeployment(id)]),
) as Record<number, ChainUserConfig>;

// Rocketh (hardhat-deploy v2) configuration. Deploy scripts live in src/deploy
// (configured via `scripts`) and are executed by both `hardhat deploy` and the
// test fixtures through rocketh/environment.ts.
export const config = {
  scripts: ["src/deploy"],
  accounts: {
    deployer: {
      default: 0,
    },
  },
  data: {},
  chains,
  signerProtocols: {
    privateKey: managedPrivateKey,
  },
} as const satisfies UserConfig;

const extensions = {
  ...deployExtension,
  ...readExecuteExtension,
};
export { extensions };

export type Extensions = typeof extensions;
export type Accounts = typeof config.accounts;
export type Data = typeof config.data;
export type Environment = EnhancedEnvironment<
  Accounts,
  Data,
  UnknownDeployments,
  Extensions
>;

// The rocketh environment name for Hardhat 3's in-memory network resolves to
// "default" (not "hardhat"), so local detection must consider the chain id too.
export function isLocalEnvironment(env: {
  name: string;
  network: { chain: { id: number } };
}): boolean {
  return (
    ["hardhat", "localhost", "default"].includes(env.name) ||
    env.network.chain.id === 31337
  );
}
