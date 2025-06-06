import type { HardhatUserConfig, HttpNetworkUserConfig } from "hardhat/types";
import "@nomicfoundation/hardhat-foundry";
import "@nomicfoundation/hardhat-verify";
import "@nomiclabs/hardhat-waffle";
import { getSingletonFactoryInfo } from "@safe-global/safe-singleton-factory";
import "solidity-coverage";
import "hardhat-deploy";
import dotenv from "dotenv";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";

const argv = yargs(hideBin(process.argv))
  .option("network", {
    type: "string",
    default: "hardhat",
  })
  .help(false)
  .version(false)
  .parse();

// Load environment variables.
dotenv.config();
const { NODE_URL, INFURA_KEY, MNEMONIC, ETHERSCAN_API_KEY, PK, SOLIDITY_VERSION, SOLIDITY_SETTINGS, CUSTOM_DETERMINISTIC_DEPLOYMENT } = process.env;

const DEFAULT_MNEMONIC =
  "candy maple cake sugar pudding cream honey rich smooth crumble sweet treat";

const sharedNetworkConfig: HttpNetworkUserConfig = {};
if (PK) {
  sharedNetworkConfig.accounts = [PK];
} else {
  sharedNetworkConfig.accounts = {
    mnemonic: MNEMONIC || DEFAULT_MNEMONIC,
  };
}

if (["mainnet", "rinkeby", "kovan", "sepolia", "ropsten", "mumbai", "polygon"].includes(argv.network) && INFURA_KEY === undefined) {
  throw new Error(
    `Could not find Infura key in env, unable to connect to network ${argv.network}`,
  );
}

import "./src/tasks/local_verify"
import "./src/tasks/deploy_contracts"
import "./src/tasks/show_codesize"
import { BigNumber } from "@ethersproject/bignumber";

const primarySolidityVersion = SOLIDITY_VERSION || "0.8.28"
const soliditySettings = !!SOLIDITY_SETTINGS ? {
  ...JSON.parse(SOLIDITY_SETTINGS),
  evmVersion: process.env.EVM_VERSION || "cancun"
} : undefined;

const deterministicDeployment = CUSTOM_DETERMINISTIC_DEPLOYMENT == "true" ?
  (network: string) => {
    const info = getSingletonFactoryInfo(parseInt(network))
    if (!info) return undefined
    return {
      factory: info.address,
      deployer: info.signerAddress,
      funding: BigNumber.from(info.gasLimit).mul(BigNumber.from(info.gasPrice)).toString(),
      signedTx: info.transaction
    }
  } : undefined

const userConfig: HardhatUserConfig = {
  paths: {
    artifacts: "build/artifacts",
    cache: "build/cache",
    deploy: "src/deploy",
    sources: "contracts"
  },
  solidity: {
    compilers: [
      { version: primarySolidityVersion, settings: soliditySettings },
      { version: "0.8.28", settings: { ...soliditySettings, evmVersion: "cancun" } },
      { version: "0.8.26", settings: { ...soliditySettings, evmVersion: "berlin" } },
      { version: "0.8.24", settings: { ...soliditySettings, evmVersion: "berlin" } },
      { version: "0.8.17", settings: { ...soliditySettings, evmVersion: "london" } },
      { version: "0.8.14", settings: { ...soliditySettings, evmVersion: "london" } },
      { version: "0.8.4", settings: { ...soliditySettings, evmVersion: "istanbul" } },
      { version: "0.7.4", settings: { ...soliditySettings, evmVersion: "istanbul" } },
      { version: "0.7.0", settings: { ...soliditySettings, evmVersion: "istanbul" } },
    ].map(compiler => ({
      ...compiler,
      settings: {
        ...compiler.settings,
        evmVersion: compiler.settings?.evmVersion || soliditySettings?.evmVersion
      }
    })),
    overrides: {
      "contracts/protocol/proxies/RigoblockPoolProxy.sol": {
        version: "0.8.17",
        settings: { ...soliditySettings, evmVersion: "london" }
      },
    }
  },
  networks: {
    hardhat: {
      allowUnlimitedContractSize: true,
      blockGasLimit: 100000000,
      gas: 100000000
    },
    mainnet: {
      ...sharedNetworkConfig,
      url: `https://mainnet.infura.io/v3/${INFURA_KEY}`,
      gasPrice: 3000000000,
    },
    xdai: {
      ...sharedNetworkConfig,
      url: "https://xdai.poanetwork.dev",
    },
    ewc: {
      ...sharedNetworkConfig,
      url: `https://rpc.energyweb.org`,
    },
    rinkeby: {
      ...sharedNetworkConfig,
      url: `https://rinkeby.infura.io/v3/${INFURA_KEY}`,
    },
    sepolia: {
      ...sharedNetworkConfig,
      url: `https://sepolia.infura.io/v3/${INFURA_KEY}`,
      gasPrice: 7000000000,
    },
    ropsten: {
      ...sharedNetworkConfig,
      url: `https://ropsten.infura.io/v3/${INFURA_KEY}`,
    },
    kovan: {
      ...sharedNetworkConfig,
      url: `https://kovan.infura.io/v3/${INFURA_KEY}`,
    },
    mumbai: {
      ...sharedNetworkConfig,
      url: `https://polygon-mumbai.infura.io/v3/${INFURA_KEY}`,
    },
    polygon: {
      ...sharedNetworkConfig,
      url: `https://polygon-rpc.com/`,
      gasPrice: 120000000000,
    },
    volta: {
      ...sharedNetworkConfig,
      url: `https://volta-rpc.energyweb.org`,
    },
    bsc: {
      ...sharedNetworkConfig,
      url: `https://bsc-dataseed.binance.org/`,
    },
    arbitrum: {
      ...sharedNetworkConfig,
      url: `https://arb1.arbitrum.io/rpc`,
    },
    optimism: {
      ...sharedNetworkConfig,
      url: `https://mainnet.optimism.io`,
    },
    fantomTestnet: {
      ...sharedNetworkConfig,
      url: `https://rpc.testnet.fantom.network/`,
    },
    avalanche: {
      ...sharedNetworkConfig,
      url: `https://api.avax.network/ext/bc/C/rpc`,
    },
    base: {
      ...sharedNetworkConfig,
      url: `https://mainnet.base.org`,
    },
    unichain: {
      ...sharedNetworkConfig,
      url: `https://unichain.infura.io/v3/${INFURA_KEY}`,
    },
  },
  deterministicDeployment,
  namedAccounts: {
    deployer: 0,
  },
  mocha: {
    timeout: 2000000,
  },
  etherscan: {
    apiKey: {
      mainnet: ETHERSCAN_API_KEY ?? '',
      sepolia: ETHERSCAN_API_KEY ?? '',
      optimisticEthereum: process.env.OPTIMISTIC_SCAN_API_KEY ?? '',
      arbitrumOne: process.env.ARBISCAN_API_KEY ?? '',
      bsc: process.env.BSCSCAN_API_KEY ?? '',
      polygon: process.env.POLYGONSCAN_API_KEY ?? '',
      base: process.env.BASE_API_KEY ?? '',
      unichain: process.env.UNICHAIN_API_KEY ?? '',
    },
    customChains: [
      {
        network: "base",
        chainId: 8453,
        urls: {
          apiURL: "https://api.basescan.org/api",
          browserURL: "https://basescan.org"
        }
      },
      {
        network: "unichain",
        chainId: 130,
        urls: {
          apiURL: "https://api.uniscan.xyz/api",
          browserURL: "https://uniscan.xyz"
        }
      }
    ]
  },
};
if (NODE_URL) {
  userConfig.networks!!.custom = {
    ...sharedNetworkConfig,
    url: NODE_URL,
  }
}
export default userConfig
