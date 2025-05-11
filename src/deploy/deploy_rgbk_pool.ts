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

  // Notice: make sure the constants.ts file is updated with the correct address.
  const wethAddress = "0xeb0c08Ad44af89BcBB5Ed6dD28caD452311B8516"
  const eOracle = await deploy("EOracle", {
    from: deployer,
    args: [config.oracleAddress, wethAddress],
    log: true,
    deterministicDeployment: true,
  });

  const grgStakingProxy = "0xeb0c08Ad44af89BcBB5Ed6dD28caD452311B8516"
  const univ4Posm = "0xeb0c08Ad44af89BcBB5Ed6dD28caD452311B8516"
  const eApps = await deploy("EApps", {
    from: deployer,
    args: [grgStakingProxy, univ4Posm],
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

  await deploy("SmartPool", {
    from: deployer,
    args: [authority.address, extensionsMapAddress],
    log: true,
    deterministicDeployment: true,
  });
};

deploy.tags = ['pool', 'main-suite']
export default deploy;
