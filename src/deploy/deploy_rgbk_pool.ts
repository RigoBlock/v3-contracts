import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { chainConfig, extensionsMapSalt } from "../utils/constants";

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

  // Note: when upgrading extensions, must update the salt manually (will allow to deploy to the same address on all chains)
  const salt = hre.ethers.utils.formatBytes32String(extensionsMapSalt);
  const extensionsMapAddress = await extensionsMapDeployerInstance.callStatic.deployExtensionsMap(params, salt);

  // Check if extensionsMapAddress has code (is a deployed contract)
  const code = await hre.ethers.provider.getCode(extensionsMapAddress);

  if (code === '0x') {
    // No code at address, proceed with deployment
    const tx = await extensionsMapDeployerInstance.deployExtensionsMap(params, salt);
    await tx.wait();
  } else {
    // skip onchain call if the contract is already deployed (would just return the address, so we can skip it)
    console.log(`Contract already deployed at ${extensionsMapAddress}`);
  }

  await deploy("SmartPool", {
    from: deployer,
    args: [authority.address, extensionsMapAddress, config.tokenJar],
    log: true,
    deterministicDeployment: true,
  });
};

deploy.tags = ['pool', 'main-suite']
export default deploy;
