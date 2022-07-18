import {network, ethers} from 'hardhat';

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
