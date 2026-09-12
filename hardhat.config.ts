import type { HardhatUserConfig } from "hardhat/config";

import HardhatMocha from "@nomicfoundation/hardhat-mocha";
import HardhatEthers from "@nomicfoundation/hardhat-ethers";
import HardhatEthersChaiMatchers from "@nomicfoundation/hardhat-ethers-chai-matchers";
import HardhatNetworkHelpers from "@nomicfoundation/hardhat-network-helpers";
import HardhatVerify from "@nomicfoundation/hardhat-verify";
import HardhatFoundry from "@nomicfoundation/hardhat-foundry";
import HardhatDeploy from "hardhat-deploy";
import HardhatMarkup from "@solarity/hardhat-markup";
import dotenv from "dotenv";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";

import { localVerifyTask } from "./src/tasks/local_verify.js";
import { deployContractsTask } from "./src/tasks/deploy_contracts.js";
import { codesizeTask, yulcodeTask } from "./src/tasks/show_codesize.js";
import { hyperliquidBigBlocksTask } from "./src/tasks/hyperliquid.js";
import { buildInfoFixTask } from "./src/tasks/build_info_fix.js";

const argv = yargs(hideBin(process.argv))
  .option("network", {
    type: "string",
    default: "hardhat",
  })
  .help(false)
  .version(false)
  .parseSync();

// Load environment variables.
dotenv.config();
const {
  NODE_URL,
  INFURA_KEY,
  MNEMONIC,
  ETHERSCAN_API_KEY,
  PK,
  SOLIDITY_VERSION,
  SOLIDITY_SETTINGS,
} = process.env;

const DEFAULT_MNEMONIC =
  "candy maple cake sugar pudding cream honey rich smooth crumble sweet treat";

const LOCAL_NETWORKS = ["hardhat", "localhost"];
const isLiveNetwork = !LOCAL_NETWORKS.includes(argv.network);

// EIP-1559 fee caps per live network live in src/utils/networkFees.ts and are
// applied to every transaction by the managed-nonce helper (src/utils/nonce.ts)
// at signing time. Hardhat 3's network config has no fields for EIP-1559 caps
// (only gasPrice), so they cannot be declared here.

const sharedNetworkConfig = {} as {
  accounts?: string[] | { mnemonic: string };
};
if (PK) {
  sharedNetworkConfig.accounts = [PK];
} else if (MNEMONIC && MNEMONIC.trim() !== "") {
  sharedNetworkConfig.accounts = {
    mnemonic: MNEMONIC,
  };
} else if (isLiveNetwork) {
  throw new Error(
    `No private key or mnemonic configured. Set PK or MNEMONIC in your .env file before deploying to ${argv.network}.`,
  );
} else {
  // hardhat/localhost only – safe to use well-known test mnemonic
  sharedNetworkConfig.accounts = {
    mnemonic: DEFAULT_MNEMONIC,
  };
}

if (
  [
    "mainnet",
    "sepolia",
    "polygon",
    "base",
    "optimism",
    "arbitrum",
    "bsc",
    "unichain",
  ].includes(argv.network) &&
  INFURA_KEY === undefined
) {
  throw new Error(
    `Could not find Infura key in env, unable to connect to network ${argv.network}`,
  );
}

const primarySolidityVersion = SOLIDITY_VERSION || "0.8.28";
const soliditySettings = !!SOLIDITY_SETTINGS
  ? {
      ...JSON.parse(SOLIDITY_SETTINGS),
      evmVersion: process.env.EVM_VERSION || "cancun",
    }
  : undefined;

const defaultProfile = {
  compilers: [
    { version: primarySolidityVersion, settings: soliditySettings },
    {
      version: "0.8.28",
      settings: { ...soliditySettings, evmVersion: "cancun" },
    },
    {
      version: "0.8.26",
      settings: { ...soliditySettings, evmVersion: "berlin" },
    },
    {
      version: "0.8.17",
      settings: { ...soliditySettings, evmVersion: "london" },
    },
  ].map((compiler) => ({
    ...compiler,
    settings: {
      ...compiler.settings,
      evmVersion: compiler.settings?.evmVersion || soliditySettings?.evmVersion,
    },
  })),
  overrides: {
    "contracts/protocol/proxies/RigoblockPoolProxy.sol": {
      version: "0.8.17",
      settings: { ...soliditySettings, evmVersion: "london" },
    },
    "contracts/mocks/MockAcrossSpokePool.sol": {
      version: "0.8.28",
      settings: {
        ...soliditySettings,
        viaIR: true,
        evmVersion: "cancun",
      },
    },
  },
};

const edrSimulatedConfig = {
  type: "edr-simulated" as const,
  // SmartPool's deployed bytecode is 24585 bytes, 9 bytes over the EIP-170 cap;
  // tests and local deploys must tolerate it.
  allowUnlimitedContractSize: true,
  blockGasLimit: 100_000_000,
  gas: 16_000_000,
};

const userConfig: HardhatUserConfig = {
  plugins: [
    HardhatMocha,
    HardhatEthers,
    HardhatEthersChaiMatchers,
    HardhatNetworkHelpers,
    HardhatVerify,
    HardhatFoundry,
    HardhatDeploy,
    HardhatMarkup,
  ],
  tasks: [
    buildInfoFixTask,
    localVerifyTask,
    deployContractsTask,
    codesizeTask,
    yulcodeTask,
    hyperliquidBigBlocksTask,
  ],
  markup: {
    outdir: "docs/api-raw",
    skipFiles: ["contracts/mocks", "contracts/test"],
  },
  // Keep the Hardhat coverage scope aligned with the Foundry report
  // (scripts/foundry-coverage.sh excludes mocks/test/tokens/utils and never
  // reports third-party lib/ code); without this the merged Codecov total
  // inflates and the percentage dilutes.
  coverage: {
    skipFiles: [
      "lib/**",
      "contracts/mocks/**",
      "contracts/test/**",
      "contracts/tokens/**",
      "contracts/utils/**",
    ],
  },
  paths: {
    artifacts: "build/artifacts",
    cache: "build/cache",
    sources: "contracts",
    // Solidity tests are run by Foundry (`forge test`), not Hardhat. Point
    // HH3's built-in solidity-test runner at a nonexistent dir so `hardhat test`
    // only runs the mocha specs under `test/`.
    tests: { mocha: "test", solidity: "test-solidity-none" },
  },
  solidity: {
    profiles: {
      // NOTE: hardhat-deploy v2's `deploy` task compiles with the `production`
      // build profile. Hardhat 3 auto-generates that profile from `default` but
      // STRIPS compiler `settings` (including `viaIR`), so it must be declared
      // explicitly here with the same settings or compilation fails
      // (MockAcrossSpokePool needs viaIR).
      default: defaultProfile,
      production: defaultProfile,
    },
  },
  networks: {
    // Hardhat 3's implicit in-memory network is named `default` (used by
    // `hardhat test` and `network.getOrCreate()`); `node` is the network served
    // by `hardhat node`. `hardhat` is kept for explicit `--network hardhat` use.
    // All three share the same edr-simulated settings.
    default: edrSimulatedConfig,
    node: edrSimulatedConfig,
    hardhat: edrSimulatedConfig,
    mainnet: {
      type: "http",
      ...sharedNetworkConfig,
      url: `https://mainnet.infura.io/v3/${INFURA_KEY}`,
    },
    xdai: {
      type: "http",
      ...sharedNetworkConfig,
      url: "https://xdai.poanetwork.dev",
    },
    ewc: {
      type: "http",
      ...sharedNetworkConfig,
      url: `https://rpc.energyweb.org`,
    },
    sepolia: {
      type: "http",
      ...sharedNetworkConfig,
      url: `https://sepolia.infura.io/v3/${INFURA_KEY}`,
    },
    polygon: {
      type: "http",
      ...sharedNetworkConfig,
      url: `https://polygon-mainnet.infura.io/v3/${INFURA_KEY}`,
    },
    volta: {
      type: "http",
      ...sharedNetworkConfig,
      url: `https://volta-rpc.energyweb.org`,
    },
    bsc: {
      type: "http",
      ...sharedNetworkConfig,
      url: `https://bsc-dataseed.binance.org/`,
    },
    arbitrum: {
      type: "http",
      ...sharedNetworkConfig,
      url: `https://arb1.arbitrum.io/rpc`,
    },
    optimism: {
      type: "http",
      ...sharedNetworkConfig,
      url: `https://mainnet.optimism.io`,
    },
    fantomTestnet: {
      type: "http",
      ...sharedNetworkConfig,
      url: `https://rpc.testnet.fantom.network/`,
    },
    avalanche: {
      type: "http",
      ...sharedNetworkConfig,
      url: `https://api.avax.network/ext/bc/C/rpc`,
    },
    base: {
      type: "http",
      ...sharedNetworkConfig,
      url: `https://mainnet.base.org`,
    },
    unichain: {
      type: "http",
      ...sharedNetworkConfig,
      url: `https://unichain-mainnet.infura.io/v3/${INFURA_KEY}`,
    },
    hyperliquid: {
      type: "http",
      ...sharedNetworkConfig,
      url: process.env.HYPERLIQUID_RPC_URL || "http://localhost:8545",
      // HyperEVM has 1s small blocks (3M gas) and 60s big blocks (30M gas).
      // Large protocol contracts must be deployed in big blocks; the deployer account must first
      // set the Core user flag `usingBigBlocks: true` via a HyperCore action (see
      // `hardhat hyperliquid:enable-big-blocks`). Fee caps for this network
      // live in src/utils/networkFees.ts and are applied by the managed-nonce helper.
    },
  },
  test: {
    mocha: {
      timeout: 2000000,
    },
  },
  // Hardhat 3's verify plugin has no customChains: it resolves explorers from
  // the chain registry and Etherscan's chainlist, and the v2 API takes a
  // `chainid` parameter, so a single API key covers every supported network.
  verify: {
    etherscan: {
      apiKey: ETHERSCAN_API_KEY ?? "",
    },
  },
};
if (NODE_URL) {
  userConfig.networks!!.custom = {
    type: "http",
    ...sharedNetworkConfig,
    url: NODE_URL,
  };
}
export default userConfig;
