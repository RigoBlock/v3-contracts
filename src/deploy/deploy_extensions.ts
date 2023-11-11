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

  const registry = await deploy("PoolRegistry", {
    from: deployer,
    args: [
      authority.address,
      deployer  // Rigoblock Dao
    ],
    log: true,
    deterministicDeployment: true,
  });

  const originalImplementationAddress = "0xeb0c08Ad44af89BcBB5Ed6dD28caD452311B8516"
  const poolImplementation = await deploy("RigoblockV3Pool", {
    from: deployer,
    args: [authority.address],
    log: true,
    deterministicDeployment: true,
  });

  const proxyFactory = await deploy("RigoblockPoolProxyFactory", {
    from: deployer,
    args: [
      originalImplementationAddress,
      registry.address
    ],
    log: true,
    deterministicDeployment: true,
  });

  const proxyFactoryInstance = await hre.ethers.getContractAt(
    "RigoblockPoolProxyFactory",
    proxyFactory.address
  );
  const currentImplementation = await proxyFactoryInstance.implementation()
  //if (currentImplementation !== poolImplementation.address) {
  //  await proxyFactoryInstance.setImplementation(poolImplementation.address)
  //}

  await deploy("EWhitelist", {
    from: deployer,
    args: [authority.address],
    log: true,
    deterministicDeployment: true,
  });

  await deploy("EUpgrade", {
    from: deployer,
    args: [proxyFactory.address],
    log: true,
    deterministicDeployment: true,
  });

  const uniswapRouter2 = "0x2626664c2603336E57B271c5C0b26F421741e481";

  await deploy("AUniswap", {
    from: deployer,
    args: [uniswapRouter2],
    log: true,
    deterministicDeployment: true,
  });

  await deploy("AMulticall", {
    from: deployer,
    args: [],
    log: true,
    deterministicDeployment: true,
  });

  const governanceProxy = { address: "0x5F8607739c2D2d0b57a4292868C368AB1809767a" };

  await deploy("AGovernance", {
    from: deployer,
    args: [governanceProxy.address],
    log: true,
    deterministicDeployment: true,
  });
};

deploy.tags = ['extensions', 'adapters', 'l2-suite', 'main-suite']
export default deploy;
