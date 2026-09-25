import {setupDeployScripts} from "rocketh";
import type {Accounts, Data, Extensions} from "./config.js";
import {extensions, PRODUCTION_CHAIN_IDS} from "./config.js";

const {deployScript: baseDeployScript} = setupDeployScripts<Extensions, Accounts, Data>(extensions);

const DEV_CHAIN_IDS = [1337, 31337];

// Fail closed on live chains that have no entry in PRODUCTION_CHAIN_IDS: without
// one, rocketh silently falls back to its default CREATE2 factory and contracts
// would land at addresses inconsistent with the other production chains.
const deployScript: typeof baseDeployScript = (callback, options) => {
  const script = baseDeployScript(callback, options);
  const guarded = Object.assign(
    async (env: unknown, args: unknown) => {
      const chainId = (env as {network?: {chain?: {id?: number}}}).network?.chain?.id;
      if (
        chainId !== undefined &&
        !DEV_CHAIN_IDS.includes(chainId) &&
        !PRODUCTION_CHAIN_IDS.includes(chainId)
      ) {
        throw new Error(
          `Chain ${chainId} has no deterministic-deployment entry in rocketh/config.ts ` +
            `(PRODUCTION_CHAIN_IDS). Refusing to deploy with the default CREATE2 factory, ` +
            `which would produce addresses inconsistent with the other production chains. ` +
            `Add the chain id (with its Safe singleton factory entry) first.`,
        );
      }
      return script(env as never, args as never);
    },
    {
      tags: script.tags,
      dependencies: script.dependencies,
      id: script.id,
      runAtTheEnd: script.runAtTheEnd,
    },
  );
  return guarded;
};

export {deployScript};
