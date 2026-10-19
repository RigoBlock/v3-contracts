import { expect } from "chai";
import {
  chainConfig,
  GOVERNANCE_HUB_CHAIN,
  governanceHubWormholeChainId,
  governanceRecovery,
} from "../../src/utils/constants";

// Mirrors the authoritative mapping enforced at deploy time in src/deploy/deploy_governance.ts:
// the hub chain (Ethereum mainnet) is the only sender governance, every other configured chain
// is a receiver.

describe("Governance chain config", async () => {
  // Mirrors the deploy script validation in src/deploy/deploy_governance.ts: the hub chain's
  // wormhole configuration must exist, since the hub strategy wraps the hub wormhole core
  // contract. The hub Wormhole chain id is a single top-level constant used as the governance
  // implementation's immutable.
  it("hub chain has wormhole configured and a hub wormhole chain id exists", async () => {
    const hubConfig = chainConfig[GOVERNANCE_HUB_CHAIN];
    expect(hubConfig, `chain ${GOVERNANCE_HUB_CHAIN}`).to.not.eq(undefined);
    expect(hubConfig.wormhole).to.match(/^0x[0-9a-fA-F]{40}$/);
    expect(BigInt(hubConfig.wormhole)).to.not.eq(0n);
    expect(governanceHubWormholeChainId).to.be.a("number");
    expect(governanceHubWormholeChainId).to.be.greaterThan(0);
  });

  // Mirrors the deploy script validation in src/deploy/deploy_governance.ts: a recovery
  // address is required on receiver chains (enforced, i.e. revert, at deploy time) and must
  // be a real address.
  it("governanceRecovery is configured for the receiver chains", async () => {
    expect(governanceRecovery).to.match(/^0x[0-9a-fA-F]{40}$/);
    expect(BigInt(governanceRecovery)).to.not.eq(0n);
  });
});
