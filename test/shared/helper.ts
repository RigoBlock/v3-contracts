import {ethers} from "hardhat";
import {BigNumber} from "ethers";
import {SignerWithAddress} from "@nomiclabs/hardhat-ethers/signers";
import { FIXED_GAS_LIMIT } from "./constants";

export const getFixedGasSigners = async function (): Promise<SignerWithAddress[]> {
  const signers: SignerWithAddress[] = await ethers.getSigners();
  signers.forEach(signer => {
    let orig = signer.sendTransaction;
    signer.sendTransaction = function (transaction) {
      transaction.gasLimit = BigNumber.from(FIXED_GAS_LIMIT.toString());
      return orig.apply(signer, [transaction]);
    }
  });
  return signers;
};