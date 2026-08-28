import { ethers } from "ethers";

const MAINNET_API_URL = "https://api.hyperliquid.xyz/exchange";
const TESTNET_API_URL = "https://api.hyperliquid-testnet.xyz/exchange";

const HYPERLIQUID_DOMAIN = {
  name: "Exchange",
  version: "1",
  chainId: 1337,
  verifyingContract: ethers.constants.AddressZero,
};

const AGENT_TYPES = {
  Agent: [
    { name: "source", type: "string" },
    { name: "connectionId", type: "bytes32" },
  ],
};

/**
 * Deterministic msgpack encoding of the HyperCore action
 * `{ type: "evmUserModify", usingBigBlocks: true }`.
 *
 * Hyperliquid L1 actions are hashed as
 *   keccak256(msgpack(action) || uint64be(nonce) || 0x00)
 * so the encoding must be byte-for-byte stable. The encoded action is:
 *   0x82                         fixmap, 2 items
 *   0xa4 0x74 0x79 0x70 0x65     fixstr "type"
 *   0xad ...                     fixstr "evmUserModify"
 *   0xae ...                     fixstr "usingBigBlocks"
 *   0xc3 / 0xc2                  bool true / false
 */
function encodeEvmUserModifyAction(usingBigBlocks: boolean): Uint8Array {
  const text = new TextEncoder();
  const typeKey = text.encode("type");
  const typeValue = text.encode("evmUserModify");
  const flagKey = text.encode("usingBigBlocks");

  // fixmap with 2 items
  const header = new Uint8Array([0x82]);
  // fixstr "type" -> fixstr "evmUserModify"
  const typeEntry = new Uint8Array([0xa4, ...typeKey, 0xad, ...typeValue]);
  // fixstr "usingBigBlocks" -> bool true/false
  const flagEntry = new Uint8Array([0xae, ...flagKey, usingBigBlocks ? 0xc3 : 0xc2]);

  const out = new Uint8Array(header.length + typeEntry.length + flagEntry.length);
  out.set(header, 0);
  out.set(typeEntry, header.length);
  out.set(flagEntry, header.length + typeEntry.length);
  return out;
}

function l1ConnectionId(actionBytes: Uint8Array, nonce: number): string {
  const nonceBuf = Buffer.allocUnsafe(8);
  nonceBuf.writeBigUInt64BE(BigInt(nonce), 0);
  const modeByte = Buffer.from([0x00]);
  return ethers.utils.keccak256(
    Buffer.concat([Buffer.from(actionBytes), nonceBuf, modeByte]),
  );
}

/**
 * Submit a HyperCore `evmUserModify` action to direct the deployer's
 * EVM transactions to big blocks. Throws if the API rejects the action.
 *
 * @param signer Ethers signer whose address should be enabled for big blocks.
 * @param isTestnet Whether to target the Hyperliquid testnet API.
 */
export async function enableHyperEVMBigBlocks(
  signer: ethers.Signer,
  isTestnet: boolean,
): Promise<void> {
  const address = await signer.getAddress();
  const action = { type: "evmUserModify" as const, usingBigBlocks: true };
  const nonce = Date.now();
  const actionBytes = encodeEvmUserModifyAction(true);
  const connectionId = l1ConnectionId(actionBytes, nonce);

  const message = {
    source: isTestnet ? "b" : "a",
    connectionId,
  };

  // Ethers v5 signers expose _signTypedData for EIP-712 signing.
  const signerWithTypedData = signer as ethers.Signer & {
    _signTypedData: (
      domain: typeof HYPERLIQUID_DOMAIN,
      types: typeof AGENT_TYPES,
      message: typeof message,
    ) => Promise<string>;
  };

  const signatureHex = await signerWithTypedData._signTypedData(
    HYPERLIQUID_DOMAIN,
    AGENT_TYPES,
    message,
  );
  const sig = ethers.utils.splitSignature(signatureHex);

  const url = isTestnet ? TESTNET_API_URL : MAINNET_API_URL;
  const body = {
    action,
    signature: { r: sig.r, s: sig.s, v: sig.v },
    nonce,
  };

  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    throw new Error(
      `Hyperliquid API HTTP error ${response.status}: ${await response.text()}`,
    );
  }

  const result = await response.json();
  if (
    result.status === "err" ||
    (typeof result.response === "string" && result.response.toLowerCase().includes("error"))
  ) {
    throw new Error(
      `Hyperliquid evmUserModify action failed: ${JSON.stringify(result)}. ` +
        `Make sure the deployer address ${address} is an existing HyperCore user ` +
        `(e.g. has received USDC on HyperCore).`,
    );
  }

  console.log(`HyperEVM big blocks enabled for deployer ${address}`);
}
