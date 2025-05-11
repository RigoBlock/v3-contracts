import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { chainConfig } from "../utils/constants";

const deploy: DeployFunction = async function (
  hre: HardhatRuntimeEnvironment,
) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deployer } = await getNamedAccounts();
  const { deploy } = deployments;

  const chainId = await getChainId();
  if (!chainId || !chainConfig[chainId]) {
    if (chainId === "31337") {
      console.log("Skipping for Hardhat Network");
      return;
    } else {
      throw new Error(`Unsupported network: Chain ID ${chainId}`);
    }
  }

  const config = chainConfig[chainId];

  const grgTransferProxy = await deploy("ERC20Proxy", {
    from: deployer,
    args: [deployer],  // Authorizable(_owner)
    log: true,
    deterministicDeployment: true,
  });

  const grgVault = await deploy("GrgVault", {
    from: deployer,
    args: [
        grgTransferProxy.address,
        config.rigoToken,
        deployer  // Authorizable(_owner)
    ],
    log: true,
    deterministicDeployment: true,
  });

  const authority = await deploy("Authority", {
    from: deployer,
    args: [deployer],
    log: true,
    deterministicDeployment: true,
  });

  // registry uses IRigoblockV3Pool, which inherits ISmartPool and results in a different deployed address.
  // Prevent re-deploy by passing deployed registry address. Deploy with V3 package if want to have
  // same registery address on newly supported chains.
  const registry = await deploy("PoolRegistry", {
    from: deployer,
    args: [
      authority.address,
      deployer  // Rigoblock Dao
    ],
    log: true,
    deterministicDeployment: true,
  });

  const staking = await deploy("Staking", {
    from: deployer,
    args: [
        grgVault.address,
        registry.address,
        config.rigoToken,
    ],
    log: true,
    deterministicDeployment: true,
  });

  const stakingProxy = await deploy("StakingProxy", {
    from: deployer,
    args: [
        staking.address,
        deployer  // Authorizable(_owner)
    ],
    log: true,
    deterministicDeployment: true,
  });

  await deploy("AStaking", {
    from: deployer,
    args: [
        stakingProxy.address,
        config.rigoToken,
        grgTransferProxy.address
    ],
    log: true,
    deterministicDeployment: true,
  });

  await deploy("Inflation", {
    from: deployer,
    args: [
      config.rigoToken,
      stakingProxy.address
    ],
    log: true,
    deterministicDeployment: true,
  });

  await deploy("ProofOfPerformance", {
    from: deployer,
    args: [stakingProxy.address],
    log: true,
    deterministicDeployment: true,
  });*/
};

deploy.tags = ['staking', 'l2-suite', 'main-suite']
export default deploy;
