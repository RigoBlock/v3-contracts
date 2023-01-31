import hre, {network, ethers} from "hardhat"
import { Wallet, Contract } from "ethers"
import solc from "solc"

export interface TimeTravelOpts {
    days?: number;
    hours?: number;
    minutes?: number;
    seconds?: number;
    mine?: boolean;
    fromBlock?: string|number;
}

export async function timeTravel(opts: TimeTravelOpts) {
    let {
        fromBlock = 'latest'
    } = opts;
    let seconds = opts.seconds ?? 0;
    if (opts.minutes) {
        seconds += opts.minutes * 60;
    }
    if (opts.hours) {
        seconds += opts.hours * 60 * 60;
    }
    if (opts.days) {
        seconds += opts.days * 24 * 60 * 60;
    }

    // evm_increaseTime is flaky since time passed in tests affects it.
    const referenceBlock = await ethers.provider.getBlock(fromBlock);
    await network.provider.send("evm_setNextBlockTimestamp", [referenceBlock.timestamp + seconds]);

    if (opts.mine) {
        await network.provider.send("evm_mine");
    }
}

export const compile = async (source: string) => {
    const input = JSON.stringify({
        'language': 'Solidity',
        'settings': {
            'outputSelection': {
            '*': {
                '*': [ 'abi', 'evm.bytecode' ]
            }
            }
        },
        'sources': {
            'tmp.sol': {
                'content': source
            }
        }
    });
    const solcData = await solc.compile(input)
    const output = JSON.parse(solcData);
    if (!output['contracts']) {
        console.log(output)
        throw Error("Could not compile contract")
    }
    const fileOutput = output['contracts']['tmp.sol']
    const contractOutput = fileOutput[Object.keys(fileOutput)[0]]
    const abi = contractOutput['abi']
    const data = '0x' + contractOutput['evm']['bytecode']['object']
    return {
        "data": data,
        "interface": abi
    }
}

export const deployContract = async (deployer: Wallet, source: string): Promise<Contract> => {
    const output = await compile(source)
    const transaction = await deployer.sendTransaction({ data: output.data, gasLimit: 6000000 })
    const receipt = await transaction.wait()
    return new Contract(receipt.contractAddress, output.interface, deployer)
}

export enum TimeType {
    Blocknumber,
    Timestamp
}

export class ProposedAction {
    constructor(public target: any, public data: String, public value: Number) {}
}

export enum StakeStatus {
    Undelegated,
    Delegated,
}

export class StakeInfo {
    constructor(public status: StakeStatus, public poolId: any) {}
}
