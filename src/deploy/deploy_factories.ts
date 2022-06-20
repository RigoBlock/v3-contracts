import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const deploy: DeployFunction = async function (
  hre: HardhatRuntimeEnvironment,
) {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();
  const { deploy } = deployments;

  const authority = await deploy("Authority", {
    from: deployer,
    args: [deployer],
    log: true,
    deterministicDeployment: true,
  });

  const registry = await deploy("DragoRegistry", {
    from: deployer,
    args: [authority.address],
    log: true,
    deterministicDeployment: true,
  });

  await deploy("RigoblockPoolProxyFactory", {
    from: deployer,
    args: [
      registry.address,
      deployer,
      authority.address,
      deployer
    ],
    log: true,
    deterministicDeployment: true,
  });
};

deploy.tags = ['factory', 'pool-deps', 'l2-suite', 'main-suite']
export default deploy;
