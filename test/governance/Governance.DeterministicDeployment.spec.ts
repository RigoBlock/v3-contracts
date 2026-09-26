import { expect } from "chai";
import { AbiCoder, ZeroHash, getCreate2Address, keccak256 } from "ethers";
import { getSingletonFactoryInfo } from "@safe-global/safe-singleton-factory";
import { readArtifact } from "../../rocketh/artifacts";

// Live addresses, identical on every deployed chain
// (https://docs.rigoblock.com/deployments/deployed-contracts-gov)
const GOVERNANCE_FACTORY = "0xc1AdDa7605d2DC47Dd91A930c978Cd6a18D2D760";
const GOVERNANCE_PROXY = "0x5F8607739c2D2d0b57a4292868C368AB1809767a";

// Wallet that created the mainnet governance through RigoblockGovernanceFactory.createGovernance
const MAINNET_GOVERNANCE_CREATOR = "0x080f08076e8EAdC66006C3CbFEd28a34918A1fA6";
const GOVERNANCE_NAME = "Rigoblock Governance";

// Skipped under coverage: solidity-coverage recompiles with instrumented bytecode, so the
// artifact init code (and therefore the CREATE2 hash) no longer matches the deployed one.
const describeDeterministic = process.env.COVERAGE ? describe.skip : describe;

describeDeterministic("Governance deterministic deployment", async () => {
  it("governance factory reproduces its deployed address on a fresh chain", async () => {
    const { bytecode } = await readArtifact("RigoblockGovernanceFactory");
    // src/deploy/deploy_governance.ts deploys the factory with deterministic: true and no args:
    // create2(Safe singleton factory, salt 0, initCode)
    const { address: singletonFactory } = getSingletonFactoryInfo(1);
    expect(
      getCreate2Address(singletonFactory, ZeroHash, keccak256(bytecode)),
    ).to.eq(GOVERNANCE_FACTORY);
  });

  it("governance proxy reproduces its deployed address on a fresh chain", async () => {
    const { bytecode } = await readArtifact("RigoblockGovernanceProxy");
    // RigoblockGovernanceFactory creates proxies as
    // new RigoblockGovernanceProxy{salt: keccak256(abi.encode(msg.sender, name))}()
    const salt = keccak256(
      AbiCoder.defaultAbiCoder().encode(
        ["address", "string"],
        [MAINNET_GOVERNANCE_CREATOR, GOVERNANCE_NAME],
      ),
    );
    expect(
      getCreate2Address(GOVERNANCE_FACTORY, salt, keccak256(bytecode)),
    ).to.eq(GOVERNANCE_PROXY);
  });
});
