import * as deployExtension from "@rocketh/deploy";
import * as readExecuteExtension from "@rocketh/read-execute";
import {privateKey} from "@rocketh/signer";
import type {Signer} from "@rocketh/core/types";
import type {EnhancedEnvironment, SignerProtocolFunction, UnknownDeployments, UserConfig} from "rocketh/types";
import {wrapManagedSigner} from "../src/utils/nonce";

// Wrap the privateKey protocol so signed transactions pick up the managed
// nonce counter and the network's EIP-1559 fee caps (see src/utils/nonce.ts).
const managedPrivateKey: SignerProtocolFunction = async (
  protocolString,
): Promise<Signer> => {
  const base = await privateKey(protocolString);
  return {...base, signer: wrapManagedSigner(base.signer)} as Signer;
};

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
  signerProtocols: {
    privateKey: managedPrivateKey,
  },
} as const satisfies UserConfig;

const extensions = {
  ...deployExtension,
  ...readExecuteExtension,
};
export {extensions};

export type Extensions = typeof extensions;
export type Accounts = typeof config.accounts;
export type Data = typeof config.data;
export type Environment = EnhancedEnvironment<Accounts, Data, UnknownDeployments, Extensions>;

// The rocketh environment name for Hardhat 3's in-memory network resolves to
// "default" (not "hardhat"), so local detection must consider the chain id too.
export function isLocalEnvironment(env: {
  name: string;
  network: {chain: {id: number}};
}): boolean {
  return (
    ["hardhat", "localhost", "default"].includes(env.name) ||
    env.network.chain.id === 31337
  );
}
