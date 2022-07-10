import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const deploy: DeployFunction = async function (
  hre: HardhatRuntimeEnvironment,
) {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();
  const { deploy } = deployments;

  const authority = await deploy("AuthorityCore", {
    from: deployer,
    args: [deployer],
    log: true,
    deterministicDeployment: true,
  });

  const registry = await deploy("PoolRegistry", {
    from: deployer,
    args: [
      authority.address,
      deployer  // Rigoblock Dao
    ],
    log: true,
    deterministicDeployment: true,
  });

  const poolImplementation = await deploy("RigoblockV3Pool", {
    from: deployer,
    args: [],
    log: true,
    deterministicDeployment: true,
  });

  await deploy("RigoblockPoolProxyFactory", {
    from: deployer,
    args: [
      poolImplementation.address,
      registry.address
    ],
    log: true,
    deterministicDeployment: true,
  });
};

deploy.tags = ['factory', 'pool-deps', 'l2-suite', 'main-suite']
export default deploy;
