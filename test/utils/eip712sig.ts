import ethSigUtil from "@metamask/eth-sig-util"
import hre, {network, waffle, ethers} from "hardhat"
import { VoteType } from "./utils"

export interface SigOpts {
    governance?: string;
    proposalId?: number;
    voteType?: VoteType;
}

const EIP712Domain = [
    { name: 'name', type: 'string' },
    { name: 'version', type: 'string' },
    { name: 'chainId', type: 'uint256' },
    { name: 'verifyingContract', type: 'address' }
]

enum SignTypedDataVersion {
    V1 = 'V1',
    V3 = 'V3',
    V4 = 'V4'
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
    let mnemonic = process.env.MNEMONIC
    if (mnemonic == undefined) {
        mnemonic = "candy maple cake sugar pudding cream honey rich smooth crumble sweet treat"
    }
    const wallet = hre.ethers.Wallet.fromMnemonic(mnemonic)
    const privateKey = Buffer.from(wallet.privateKey)
    const signature = await signer._signTypedData(domain, types, value)
    /*const altSig = await ethSigUtil.signTypedData({
        privateKey: privateKey,
        data: {
            types: {
                EIP712Domain,
                Vote: [
                    { name: 'proposalId', type: 'uint256' },
                    { name: 'voteType', type: 'uint8' }
                ],
            },
            domain: domain,
            primaryType: 'Vote',
            message: value
        },
        version: SignTypedDataVersion.V4
    })
    console.log(signature, altSig)*/
    return {
      "signature": signature,
      "domain": domain,
      "types": types,
      "value": value
    }
}
