import {network} from "hardhat";
import type {EthereumProvider} from "hardhat/types/providers";
import {loadAndExecuteDeploymentsFromFiles} from "../../rocketh/environment.js";
import type {Environment} from "../../rocketh/config.js";

interface SnapshotLike {
  restore(): Promise<void>;
}

let providerRef: EthereumProvider;

// Post-deploy-scripts snapshots, one per tag set. Mirrors hardhat-deploy v1's
// per-tag fixtures: the deploy scripts run once per tag set; later calls revert
// to the post-scripts state instead of re-running anything.
const baseFixtures = new Map<string, {snapshot: SnapshotLike; env: Environment}>();

let fixtureCounter = 0;

/**
 * Runs the deploy scripts tagged with `tags` once per tag set and snapshots the
 * in-memory network right after. Subsequent calls with the same tags restore
 * that snapshot (deploy scripts do NOT re-run), like hardhat-deploy v1's
 * `deployments.fixture(tag)`.
 */
export async function deploymentsFixture(tags: string[]): Promise<Environment> {
  const {provider, networkHelpers} = await network.getOrCreate();
  providerRef = provider;
  const key = tags.join(",");
  const existing = baseFixtures.get(key);
  if (existing) {
    await existing.snapshot.restore();
    baseFixtures.set(key, {
      snapshot: await networkHelpers.takeSnapshot(),
      env: existing.env,
    });
    return existing.env;
  }
  const env = await loadAndExecuteDeploymentsFromFiles({provider: providerRef, tags});
  baseFixtures.set(key, {snapshot: await networkHelpers.takeSnapshot(), env});
  return env;
}

/**
 * Compatibility wrapper mirroring hardhat-deploy v1's
 * `deployments.createFixture(fn)`:
 * - on first call, the deploy scripts for `tags` are ensured (restoring the
 *   shared post-scripts snapshot first), then the callback runs and the network
 *   is snapshotted AFTER it completes;
 * - on later calls the post-callback snapshot is restored and the cached result
 *   returned, so every call observes the callback's state.
 * `get(name)` resolves deployment records ({address, abi, ...}).
 */
export function createFixture<T>(
  tags: string[],
  fn: (deployments: {get: (name: string) => Promise<any>}) => Promise<T>,
): () => Promise<T> {
  void ++fixtureCounter; // unique id per createFixture call, as in v1
  let saved: {snapshot: SnapshotLike; data: T} | undefined;
  return async () => {
    const {networkHelpers} = await network.getOrCreate();
    if (saved) {
      await saved.snapshot.restore();
      saved = {snapshot: await networkHelpers.takeSnapshot(), data: saved.data};
      return saved.data;
    }
    const env = await deploymentsFixture(tags);
    const data = await fn({
      get: async (name: string) => {
        const deployment = env.get(name);
        return {...deployment};
      },
    });
    saved = {snapshot: await networkHelpers.takeSnapshot(), data};
    return data;
  };
}
