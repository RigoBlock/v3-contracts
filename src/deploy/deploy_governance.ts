import "hardhat-deploy";
import "@nomiclabs/hardhat-ethers";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { chainConfig, mainnetGovernanceProxy } from "../utils/constants";
import { enableManagedNonce } from "../utils/nonce";

const deploy: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deployer } = await getNamedAccounts();
  await enableManagedNonce(hre, deployer);
  const { deploy } = deployments;

  const chainId = await getChainId();
  const chainIdNum = parseInt(chainId);
  if (!chainId || !chainConfig[chainIdNum]) {
    if (chainId === "31337") {
      console.log("Skipping for Hardhat Network");
      return;
    } else {
      throw new Error(`Unsupported network: Chain ID ${chainId}`);
    }
  }

  const config = chainConfig[chainIdNum];

  // Mainnet is the source of cross-chain governance messages: deploy the full
  // governance suite (factory, implementation, strategy) there.
  if (chainIdNum === 1) {
    await deploy("RigoblockGovernanceFactory", {
      from: deployer,
      args: [],
      log: true,
      deterministicDeployment: true,
    });

    await deploy("RigoblockGovernance", {
      from: deployer,
      args: [],
      log: true,
      deterministicDeployment: true,
    });

    await deploy("RigoblockGovernanceStrategy", {
      from: deployer,
      args: [config.stakingProxy, config.wormhole, config.wormholeChainId],
      log: true,
      deterministicDeployment: true,
    });
    return;
  }

  // Receiver chains execute governance actions coming from Ethereum mainnet.
  // This includes chains with no staking proxy (e.g. HyperEVM) and chains where
  // the local staking proxy is being deprecated for governance (e.g. Unichain).
  if (config.wormhole != "0x0000000000000000000000000000000000000000") {
    await deploy("CrosschainReceiver", {
      from: deployer,
      args: [
        config.wormhole,
        2,
        hre.ethers.utils.hexZeroPad(mainnetGovernanceProxy, 32),
      ],
      log: true,
      deterministicDeployment: true,
    });
    return;
  }

  // Fallback for legacy L2s without Wormhole config: keep deploying the full
  // governance suite until they are migrated to cross-chain governance.
  await deploy("RigoblockGovernanceFactory", {
    from: deployer,
    args: [],
    log: true,
    deterministicDeployment: true,
  });

  await deploy("RigoblockGovernance", {
    from: deployer,
    args: [],
    log: true,
    deterministicDeployment: true,
  });

  await deploy("RigoblockGovernanceStrategy", {
    from: deployer,
    args: [config.stakingProxy, config.wormhole, config.wormholeChainId],
    log: true,
    deterministicDeployment: true,
  });
};

deploy.tags = ["governance", "l2-suite", "main-suite"];
export default deploy;
