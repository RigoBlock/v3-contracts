import { network } from "hardhat";
import { VoteType } from "./utils";

export interface SigOpts {
  governance?: string;
  proposalId?: number;
  voteType?: VoteType;
}

export async function signEip712Message(opts: SigOpts) {
  const domain = {
    name: "Rigoblock Governance",
    version: "1.2.0",
    chainId: 31337,
    verifyingContract: opts.governance,
  };
  // OpenZeppelin Governor Vote typehash (see MixinConstants.VOTE_TYPEHASH)
  const types = {
    Vote: [
      { name: "proposalId", type: "uint256" },
      { name: "support", type: "uint8" },
    ],
  };
  const value = {
    proposalId: opts.proposalId,
    support: opts.voteType,
  };
  const { ethers } = await network.getOrCreate();
  const signer = (await ethers.getSigners())[0];
  const signature = await signer.signTypedData(domain, types, value);
  return {
    signature: signature,
    domain: domain,
    types: types,
    value: value,
  };
}
