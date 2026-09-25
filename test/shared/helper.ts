import {network} from "hardhat";
import type {BaseContract, ContractRunner, TransactionRequest} from "ethers";
import type {HardhatEthersSigner} from "@nomicfoundation/hardhat-ethers/types";
import {FIXED_GAS_LIMIT} from "./constants";

export const getFixedGasSigners = async function (): Promise<HardhatEthersSigner[]> {
  const {ethers} = await network.getOrCreate();
  const signers: HardhatEthersSigner[] = await ethers.getSigners();
  signers.forEach((signer) => {
    const orig = signer.sendTransaction;
    signer.sendTransaction = function (transaction: TransactionRequest) {
      transaction.gasLimit = BigInt(FIXED_GAS_LIMIT);
      return orig.apply(signer, [transaction]);
    };
  });
  return signers;
};

/**
 * ethers v6's `contract.connect()` returns `BaseContract` and drops the typed
 * ABI. Use this to reconnect a contract to a runner without losing its type.
 */
export function connect<T extends BaseContract>(contract: T, runner: ContractRunner): T {
  return contract.connect(runner) as T;
}
