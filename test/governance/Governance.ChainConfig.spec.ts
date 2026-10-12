import { expect } from "chai";
import { chainConfig, governanceRecovery } from "../../src/utils/constants";

// Mirrors the authoritative mapping enforced at deploy time in src/deploy/deploy_governance.ts:
// the hub chain (Ethereum mainnet) is the only sender governance, every other configured
// chain is a receiver.
const GOVERNANCE_HUB_CHAIN = 1;

describe("Governance chain config", async () => {
  it("every configured chain declares a governance mode", async () => {
    for (const [chainId, config] of Object.entries(chainConfig)) {
      expect(config.governanceMode, `chain ${chainId}`).to.be.oneOf([
        "sender",
        "receiver",
      ]);
    }
  });

  it("chain-to-mode mapping matches the deploy script's enforced mapping", async () => {
    for (const [chainId, config] of Object.entries(chainConfig)) {
      const expected =
        Number(chainId) === GOVERNANCE_HUB_CHAIN ? "sender" : "receiver";
      expect(config.governanceMode, `chain ${chainId}`).to.eq(expected);
    }
  });

  it("sender mode is exclusive to Ethereum mainnet", async () => {
    const senderChains = Object.entries(chainConfig)
      .filter(([, config]) => config.governanceMode === "sender")
      .map(([chainId]) => Number(chainId));
    expect(senderChains).to.deep.eq([1]);
  });

  // Mirrors the deploy script validation in src/deploy/deploy_governance.ts: a recovery
  // address is required on receiver chains (enforced, i.e. revert, at deploy time) and must
  // be a real address.
  it("governanceRecovery is configured for the receiver chains", async () => {
    expect(governanceRecovery).to.match(/^0x[0-9a-fA-F]{40}$/);
    expect(BigInt(governanceRecovery)).to.not.eq(0n);
  });
});
