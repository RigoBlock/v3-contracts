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
  const proxyFactory = await deploy("RigoblockPoolProxyFactory", {
    from: deployer,
    args: [
      originalImplementationAddress,
      registry.address
    ],
    log: true,
    deterministicDeployment: true,
  });

  const eUpgrade = await deploy("EUpgrade", {
    from: deployer,
    args: [proxyFactory.address],
    log: true,
    deterministicDeployment: true,
  });

  // Notice: replace with deployed oracle address (uni hooks depends on PoolManager address, diff on each chains)
  const oracle = "0x813DADC6bfA14cA9f294f6341B15B530476C7ac4"
  const eOracle = await deploy("EOracle", {
    from: deployer,
    args: [oracle],
    log: true,
    deterministicDeployment: true,
  })

  // Notice: replace with deployed address (different by chain).
  const stakingProxy = "0x73f92F71544578BCC1D9F3B7dfce18859Bc20261"
  const univ3Npm = "0x1238536071E1c677A632429e3655c799b22cDA52"
  const univ4Posm = "0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4"
  const eApps = await deploy("EApps", {
    from: deployer,
    args: [stakingProxy, univ3Npm, univ4Posm],
    log: true,
    deterministicDeployment: true,
  });

  const extensions = {eApps: eApps.address, eOracle: eOracle.address, eUpgrade: eUpgrade.address}
  const extensionsMap = await deploy("ExtensionsMap", {
    from: deployer,
    args: [extensions],
    log: true,
    deterministicDeployment: true,
  });

  const weth = "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14"

  const poolImplementation = await deploy("SmartPool", {
    from: deployer,
    args: [authority.address, extensionsMap.address, weth],
    log: true,
    deterministicDeployment: true,
  });

  const proxyFactoryInstance = await hre.ethers.getContractAt(
    "RigoblockPoolProxyFactory",
    proxyFactory.address
  );
  const currentImplementation = await proxyFactoryInstance.implementation()
  if (currentImplementation !== poolImplementation.address) {
    await proxyFactoryInstance.setImplementation(poolImplementation.address)
  }

  const universalRouter = "0x3a9d48ab9751398bbfa63ad67599bb04e4bdf98b"

  await deploy("AUniswapRouter", {
    from: deployer,
    args: [universalRouter, univ4Posm, weth],
    log: true,
    deterministicDeployment: true,
  });

  await deploy("AMulticall", {
    from: deployer,
    args: [],
    log: true,
    deterministicDeployment: true,
  });
};

deploy.tags = ['extensions', 'adapters', 'l2-suite', 'main-suite']
export default deploy;
