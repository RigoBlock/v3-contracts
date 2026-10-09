import { expect } from "chai";
import { chainConfig } from "../../src/utils/constants";

// Mirrors the authoritative mapping enforced at deploy time in src/deploy/deploy_governance.ts:
// mainnet is the only sender governance, HyperEVM and BSC are receiver-only, and every
// other configured chain must be dual.
const expectedModeByChain: Record<number, string> = {
  1: "sender",
  999: "receiver",
  56: "receiver",
};

describe("Governance chain config", async () => {
  it("every configured chain declares a governance mode", async () => {
    for (const [chainId, config] of Object.entries(chainConfig)) {
      expect(config.governanceMode, `chain ${chainId}`).to.be.oneOf([
        "sender",
        "dual",
        "receiver",
      ]);
    }
  });

  it("chain-to-mode mapping matches the deploy script's enforced mapping", async () => {
    for (const [chainId, config] of Object.entries(chainConfig)) {
      const expected = expectedModeByChain[Number(chainId)] ?? "dual";
      expect(config.governanceMode, `chain ${chainId}`).to.eq(expected);
    }
  });

  it("sender mode is exclusive to Ethereum mainnet", async () => {
    const senderChains = Object.entries(chainConfig)
      .filter(([, config]) => config.governanceMode === "sender")
      .map(([chainId]) => Number(chainId));
    expect(senderChains).to.deep.eq([1]);
  });

  // Mirrors the deploy script validation in src/deploy/deploy_governance.ts: the recovery
  // address is only meaningful on receiver chains and forbidden elsewhere.
  it("governanceRecovery is only set on receiver chains", async () => {
    for (const [chainId, config] of Object.entries(chainConfig)) {
      if (config.governanceMode === "receiver") {
        continue; // required on receiver chains; enforced (revert) at deploy time
      }
      expect(config.governanceRecovery, `chain ${chainId}`).to.eq(undefined);
    }
  });
});
