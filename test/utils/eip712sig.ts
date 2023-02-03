import hre, {network, waffle, ethers} from "hardhat"
import { VoteType } from "./utils"

export interface SigOpts {
    strategy?: string|any;
    governance?: string;
    proposalId?: number;
    voteType?: VoteType;
}

export async function signTypedData(opts: SigOpts) {
    const salt = hre.ethers.utils.keccak256(opts.strategy)
    const domain = {
        name: 'Rigoblock Governance',
        version: '1.0.0',
        chainId: 31337,
        verifyingContract: opts.governance,
        salt: salt
    }
    const types = {
        VoteEmitted: [
            { name: 'proposalId', type: 'uint256' },
            { name: 'voteType', type: 'uint8' }
        ]
    }
    const value = {
        proposalId: opts.proposalId,
        voteType: opts.voteType
    }
    const signer = waffle.provider.getSigner()
    const sig = await signer._signTypedData(domain, types, value)
    const r = '0x' + sig.substring(2).substring(0, 64)
    const s = '0x' + sig.substring(2).substring(64, 128)
    const v = parseInt(sig.substring(2).substring(128,130), 16)
    return {
        "v": v,
        "r": r,
        "s": s
    }
}
