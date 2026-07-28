import dotenv from "dotenv";
dotenv.config();
import { ethers } from "ethers";

async function main() {
  const provider = new ethers.providers.JsonRpcProvider(process.env.POLYGON_MAINNET_RPC_URL);
  const txHash = "0xfda2298f5de53ec75fd3e04fe8bab98f519523ae0ea043bdfaedc13bfe888d9c";
  const tx = await provider.getTransaction(txHash);
  const factory = tx.to!.toLowerCase();
  const salt = tx.data.slice(0, 66);
  const initCode = "0x" + tx.data.slice(66);
  console.log("factory:", factory);
  console.log("salt:", salt);
  console.log("initCode length:", initCode.length);
  const addr = ethers.utils.getCreate2Address(factory, salt, ethers.utils.keccak256(initCode));
  console.log("computed address:", addr);
}
main().catch(e => { console.error(e); process.exit(1); });
