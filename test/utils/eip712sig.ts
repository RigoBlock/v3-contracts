import {waffle} from "hardhat"
import { VoteType } from "./utils"

export interface SigOpts {
    governance?: string;
    proposalId?: number;
    voteType?: VoteType;
}

export async function signEip712Message(opts: SigOpts) {
    const domain = {
        name: 'Rigoblock Governance',
        version: '1.0.0',
        chainId: 31337,
        verifyingContract: opts.governance
    }
    const types = {
        Vote: [
            { name: 'proposalId', type: 'uint256' },
            { name: 'voteType', type: 'uint8' }
        ]
    }
    const value = {
        proposalId: opts.proposalId,
        voteType: opts.voteType
    }
    const signer = waffle.provider.getSigner()
    const signature = await signer._signTypedData(domain, types, value)
    return {
      "signature": signature,
      "domain": domain,
      "types": types,
      "value": value
    }
}
