import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const deploy: DeployFunction = async function (
  hre: HardhatRuntimeEnvironment,
) {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();
  const { deploy } = deployments;

  await deploy("ERC20Proxy", {
    from: deployer,
    args: [deployer],  // Authorizable(_owner)
    log: true,
    deterministicDeployment: true,
  });

  // TODO: define grg address, initialize staking
  const grgVault = await deploy("GrgVault", {
    from: deployer,
    args: [
        deployer, // mock grg transfer proxy address
        deployer, // mock grg token address
        deployer  // Authorizable(_owner)
    ],
    log: true,
    deterministicDeployment: true,
  });

  const staking = await deploy("Staking", {
    from: deployer,
    args: [
        deployer,  // Authorizable(_owner)
        grgVault.address,
        deployer,  // MixinDeploymentConstants(_poolRegistry)
        deployer,  // MixinDeploymentConstants(_rigoToken)
    ],
    log: true,
    deterministicDeployment: true,
  });

  await deploy("StakingProxy", {
    from: deployer,
    args: [
        staking.address,
        deployer  // Authorizable(_owner)
    ],
    log: true,
    deterministicDeployment: true,
  });
};

deploy.tags = ['staking', 'l2-suite', 'main-suite']
export default deploy;
