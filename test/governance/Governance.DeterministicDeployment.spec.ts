import { expect } from "chai";
import { AbiCoder, ZeroHash, getCreate2Address, keccak256 } from "ethers";
import { getSingletonFactoryInfo } from "@safe-global/safe-singleton-factory";
import { readArtifact } from "../../rocketh/artifacts";
import {
  governanceCreator,
  governanceName,
  governanceProxy,
} from "../../src/utils/constants";

// Live addresses, identical on every deployed chain
// (https://docs.rigoblock.com/deployments/deployed-contracts-gov)
const GOVERNANCE_FACTORY = "0xc1AdDa7605d2DC47Dd91A930c978Cd6a18D2D760";

function singletonFactoryAddress(): string {
  const info = getSingletonFactoryInfo(1);
  if (!info) throw new Error("Safe singleton factory info unavailable");
  return info.address;
}

// Skipped under coverage: solidity-coverage recompiles with instrumented bytecode, so the
// artifact init code (and therefore the CREATE2 hash) no longer matches the deployed one.
const describeDeterministic = process.env.COVERAGE ? describe.skip : describe;

describeDeterministic("Governance deterministic deployment", async () => {
  it("governance factory reproduces its deployed address on a fresh chain", async () => {
    const { bytecode } = await readArtifact("RigoblockGovernanceFactory");
    // src/deploy/deploy_governance.ts deploys the factory with deterministic: true and no args:
    // create2(Safe singleton factory, salt 0, initCode)
    expect(
      getCreate2Address(
        singletonFactoryAddress(),
        ZeroHash,
        keccak256(bytecode),
      ),
    ).to.eq(GOVERNANCE_FACTORY);
  });

  it("governance proxy reproduces its deployed address on a fresh chain", async () => {
    const { bytecode } = await readArtifact("RigoblockGovernanceProxy");
    // RigoblockGovernanceFactory creates proxies as
    // new RigoblockGovernanceProxy{salt: keccak256(abi.encode(msg.sender, name))}()
    const salt = keccak256(
      AbiCoder.defaultAbiCoder().encode(
        ["address", "string"],
        [governanceCreator, governanceName],
      ),
    );
    expect(
      getCreate2Address(GOVERNANCE_FACTORY, salt, keccak256(bytecode)),
    ).to.eq(governanceProxy);
  });

  // Mirrors the deploy-script gate in src/deploy/deploy_governance.ts: the recorded
  // governanceProxy constant must equal the full deterministic derivation, so a receiver
  // deployment can never be wired to an address the deployment would not reproduce.
  it("recorded governanceProxy matches the full deterministic derivation", async () => {
    const factory = await readArtifact("RigoblockGovernanceFactory");
    const proxy = await readArtifact("RigoblockGovernanceProxy");
    const factoryAddress = getCreate2Address(
      singletonFactoryAddress(),
      ZeroHash,
      keccak256(factory.bytecode),
    );
    expect(factoryAddress).to.eq(GOVERNANCE_FACTORY);
    const salt = keccak256(
      AbiCoder.defaultAbiCoder().encode(
        ["address", "string"],
        [governanceCreator, governanceName],
      ),
    );
    expect(
      getCreate2Address(factoryAddress, salt, keccak256(proxy.bytecode)),
    ).to.eq(governanceProxy);
  });
});
