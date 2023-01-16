import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const deploy: DeployFunction = async function (
  hre: HardhatRuntimeEnvironment,
) {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();
  const { deploy } = deployments;

  const grgTransferProxy = await deploy("ERC20Proxy", {
    from: deployer,
    args: [deployer],  // Authorizable(_owner)
    log: true,
    deterministicDeployment: true,
  });

  // TODO: on each network add the correct rigoToken address
  const rigoToken = {address: "0x0"};

  const grgVault = await deploy("GrgVault", {
    from: deployer,
    args: [
        grgTransferProxy.address,
        rigoToken.address,
        deployer  // Authorizable(_owner)
    ],
    log: true,
    deterministicDeployment: true,
  });

  const authority = {address: "0xe35129A1E0BdB913CF6Fd8332E9d3533b5F41472"};

  const registry = {address: "0x06767e8090bA5c4Eca89ED00C3A719909D503ED6"};

  const staking = await deploy("Staking", {
    from: deployer,
    args: [
        grgVault.address,
        registry.address,
        rigoToken.address,
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
        rigoToken.address,
        grgTransferProxy.address
    ],
    log: true,
    deterministicDeployment: true,
  });

  const inflation = await deploy("InflationL2", {
    from: deployer,
    args: [deployer],
    log: true,
    deterministicDeployment: true,
  });

  await deploy("ProofOfPerformance", {
    from: deployer,
    args: [stakingProxy.address],
    log: true,
    deterministicDeployment: true,
  });
};

deploy.tags = ['stakingl2', 'l2-suite', 'main-suite']
export default deploy;
