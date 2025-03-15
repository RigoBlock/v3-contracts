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

  // TODO: replace with deployed oracle address (same on all chains)
  const oracle = "0x8A753747A1Fa494EC906cE90E9f37563A8AF630e"
  const wethAddress = "0xeb0c08Ad44af89BcBB5Ed6dD28caD452311B8516"
  const eOracle = await deploy("EOracle", {
    from: deployer,
    args: [oracle, wethAddress],
    log: true,
    deterministicDeployment: true,
  })

  // Notice: replace with deployed address (different by chain).
  const stakingProxy = "0xeb0c08Ad44af89BcBB5Ed6dD28caD452311B8516"
  const univ3Npm = "0xeb0c08Ad44af89BcBB5Ed6dD28caD452311B8516"
  const univ4Posm = "0xeb0c08Ad44af89BcBB5Ed6dD28caD452311B8516"
  // TODO: this constructor will try to query WETH9 from univ4Posm, but we could hardcode in implementation and remove from constructor to save gas and simplify deployment
  const eApps = await deploy("EApps", {
    from: deployer,
    args: [stakingProxy, univ3Npm, univ4Posm],
    log: true,
    deterministicDeployment: true,
  });

  const extensions = {eApps: eApps.address, eOracle: eOracle.address, eUpgrade: eUpgrade.address}

  const extensionsMapDeployer = await deploy("ExtensionsMapDeployer", {
    from: deployer,
    args: [],
    log: true,
    deterministicDeployment: true,
  });

  const extensionsMapDeployerInstance = await hre.ethers.getContractAt(
    "ExtensionsMapDeployer",
    extensionsMapDeployer.address
  );

  const params = {
    extensions: extensions,
    wrappedNative: wethAddress
  }
  const extensionsMapAddress = await extensionsMapDeployerInstance.callStatic.deployExtensionsMap(params);
  const tx = await extensionsMapDeployerInstance.deployExtensionsMap(params);
  await tx.wait();

  const poolImplementation = await deploy("SmartPool", {
    from: deployer,
    args: [authority.address, extensionsMapAddress],
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

  /*const uniswapRouter2 = "0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45"

  await deploy("AUniswap", {
    from: deployer,
    args: [uniswapRouter2],
    log: true,
    deterministicDeployment: true,
  });*/

  await deploy("AMulticall", {
    from: deployer,
    args: [],
    log: true,
    deterministicDeployment: true,
  });
};

deploy.tags = ['extensions', 'adapters', 'l2-suite', 'main-suite']
export default deploy;
