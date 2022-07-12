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

  await deploy("RigoblockV3Pool", {
    from: deployer,
    args: [
        authority.address,
        deployer  // TODO: substitute with governance if input kept
    ],
    log: true,
    deterministicDeployment: true,
  });
};

deploy.tags = ['pool', 'main-suite']
export default deploy;
