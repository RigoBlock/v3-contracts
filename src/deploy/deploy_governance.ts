import "hardhat-deploy";
import "@nomiclabs/hardhat-ethers";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { chainConfig } from "../utils/constants";

const deploy: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deployer } = await getNamedAccounts();
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
    args: [config.stakingProxy],
    log: true,
    deterministicDeployment: true,
  });
};

deploy.tags = ["governance", "l2-suite", "main-suite"];
export default deploy;
