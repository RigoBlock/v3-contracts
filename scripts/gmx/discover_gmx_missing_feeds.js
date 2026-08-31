const { ethers } = require("ethers");

const RPC = "https://arb1.arbitrum.io/rpc";
const DATA_STORE = "0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8";
const READER = "0x470fbC46bcC0f16532691Df360A07d8Bf5ee0789";
const PROVIDER = "0x38B8dB61b724b51e42A88Cb8eC564CD685a0f53B";

const provider = new ethers.providers.JsonRpcProvider(RPC);

const dataStoreAbi = [
  "function getAddressCount(bytes32 setKey) external view returns (uint256)",
  "function getAddressValuesAt(bytes32 setKey, uint256 start, uint256 end) external view returns (address[] memory)",
  "function getAddress(bytes32 key) external view returns (address)",
  "function getUint(bytes32 key) external view returns (uint256)",
];

const readerAbi = [
  "function getMarket(address dataStore, address market) external view returns (tuple(address marketToken, address indexToken, address longToken, address shortToken) props)",
];

const priceProviderAbi = [
  "function getOraclePrice(address token, bytes memory data) external view returns (tuple(address token, uint256 min, uint256 max, uint256 timestamp, uint256 blockNumber))",
];

const feedAbi = [
  "function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)",
  "function decimals() external view returns (uint8)",
];

const MARKET_LIST_KEY = ethers.utils.keccak256(
  ethers.utils.defaultAbiCoder.encode(["string"], ["MARKET_LIST"]),
);
const PRICE_FEED_KEY = ethers.utils.keccak256(
  ethers.utils.defaultAbiCoder.encode(["string"], ["PRICE_FEED"]),
);
const PRICE_FEED_MULTIPLIER_KEY = ethers.utils.keccak256(
  ethers.utils.defaultAbiCoder.encode(["string"], ["PRICE_FEED_MULTIPLIER"]),
);

function priceFeedKey(token) {
  return ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(
      ["bytes32", "address"],
      [PRICE_FEED_KEY, token],
    ),
  );
}

function priceFeedMultiplierKey(token) {
  return ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(
      ["bytes32", "address"],
      [PRICE_FEED_MULTIPLIER_KEY, token],
    ),
  );
}

async function main() {
  const dataStore = new ethers.Contract(DATA_STORE, dataStoreAbi, provider);
  const reader = new ethers.Contract(READER, readerAbi, provider);
  const priceProvider = new ethers.Contract(
    PROVIDER,
    priceProviderAbi,
    provider,
  );

  const count = await dataStore.getAddressCount(MARKET_LIST_KEY);
  console.log(`Total markets: ${count}`);

  const markets = await dataStore.getAddressValuesAt(MARKET_LIST_KEY, 0, count);

  const results = [];
  const missing = [];
  const seenIndexTokens = new Set();

  for (let i = 0; i < markets.length; i++) {
    const market = markets[i];
    try {
      const mkt = await reader.getMarket(DATA_STORE, market);
      const indexToken = mkt.indexToken;
      if (seenIndexTokens.has(indexToken.toLowerCase())) continue;
      seenIndexTokens.add(indexToken.toLowerCase());

      let hasPrice = false;
      let price = null;
      try {
        price = await priceProvider.getOraclePrice(indexToken, "0x");
        hasPrice = true;
      } catch (e) {
        hasPrice = false;
      }

      const feedAddress = await dataStore.getAddress(priceFeedKey(indexToken));
      const multiplier = await dataStore.getUint(
        priceFeedMultiplierKey(indexToken),
      );

      const info = {
        market,
        indexToken,
        hasPrice,
        price: price
          ? { min: price.min.toString(), max: price.max.toString() }
          : null,
        feedAddress,
        multiplier: multiplier.toString(),
      };
      results.push(info);

      if (!hasPrice) {
        missing.push(info);
      }
    } catch (e) {
      console.error(`Error processing market ${market}:`, e.message);
    }
  }

  console.log("\n=== Missing price feeds ===");
  for (const m of missing) {
    console.log(
      `IndexToken: ${m.indexToken}  Market: ${m.market}  FeedAddr: ${m.feedAddress}  Multiplier: ${m.multiplier}`,
    );
  }

  console.log(`\nTotal unique index tokens: ${results.length}`);
  console.log(`Missing: ${missing.length}`);

  require("fs").writeFileSync(
    "scripts/gmx/gmx_missing_feeds.json",
    JSON.stringify(
      {
        missing: missing.map((m) => m.indexToken),
        all: results.map((r) => ({
          token: r.indexToken,
          hasPrice: r.hasPrice,
          feed: r.feedAddress,
          multiplier: r.multiplier,
        })),
      },
      null,
      2,
    ),
  );
  console.log("Saved to scripts/gmx_missing_feeds.json");
}

main().catch(console.error);
