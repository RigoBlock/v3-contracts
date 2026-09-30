import { Contract } from "ethers";
import { network } from "hardhat";
import { VoteType } from "./utils";

const GOVERNANCE_ABI = [
  "function nonces(address owner) view returns (uint256)",
];

export interface SigOpts {
  governance?: string;
  proposalId?: number;
  voteType?: VoteType;
}

export async function signEip712Message(opts: SigOpts) {
  const { ethers } = await network.getOrCreate();
  const signer = (await ethers.getSigners())[0];
  const voter = await signer.getAddress();
  const governance = new Contract(
    opts.governance,
    GOVERNANCE_ABI,
    ethers.provider,
  );
  const nonce = await governance.nonces(voter);
  const domain = {
    name: "Rigoblock Governance",
    version: "1.3.0",
    chainId: 31337,
    verifyingContract: opts.governance,
  };
  // OpenZeppelin Governor Ballot typehash (see MixinVoting.BALLOT_TYPEHASH)
  const types = {
    Ballot: [
      { name: "proposalId", type: "uint256" },
      { name: "support", type: "uint8" },
      { name: "voter", type: "address" },
      { name: "nonce", type: "uint256" },
    ],
  };
  const value = {
    proposalId: opts.proposalId,
    support: opts.voteType,
    voter: voter,
    nonce: nonce,
  };
  const signature = await signer.signTypedData(domain, types, value);
  return {
    signature: signature,
    domain: domain,
    types: types,
    value: value,
  };
}
