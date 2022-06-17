import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const deploy: DeployFunction = async function (
  hre: HardhatRuntimeEnvironment,
) {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();
  const { deploy } = deployments;

/*  await deploy("ExchangesAuthority", {
    from: deployer,
    args: [],
    log: true,
    deterministicDeployment: true,
  });
*/
  await deploy("NavVerifier", {
    from: deployer,
    args: [],
    log: true,
    deterministicDeployment: true,
  });

  await deploy("SigVerifier", {
    from: deployer,
    args: [deployer], // mock address
    log: true,
    deterministicDeployment: true,
  });
};

deploy.tags = ['factory', 'pool-deps', 'l2-suite', 'main-suite']
export default deploy;
