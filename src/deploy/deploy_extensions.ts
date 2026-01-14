import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { chainConfig, extensionsMapSalt } from "../utils/constants";

const deploy: DeployFunction = async function (
  hre: HardhatRuntimeEnvironment,
) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deployer } = await getNamedAccounts();
  const { deploy } = deployments;

  const chainIdString = await getChainId();
  const chainId = parseInt(chainIdString);
  if (!chainIdString || !chainConfig[chainId]) {
    if (chainIdString === "31337") {
      console.log("Skipping for Hardhat Network");
      return;
    } else {
      throw new Error(`Unsupported network: Chain ID ${chainIdString}`);
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
  const eOracle = await deploy("EOracle", {
    from: deployer,
    args: [config.oracle, config.weth],
    log: true,
    deterministicDeployment: true,
  })
  
  const eApps = await deploy("EApps", {
    from: deployer,
    args: [config.stakingProxy, config.univ4Posm],
    log: true,
    deterministicDeployment: true,
  });

  const acrossSpokePool = config.acrossSpokePool || "0x0000000000000000000000000000000000000000";

  const eCrosschain = await deploy("ECrosschain", {
    from: deployer,
    args: [acrossSpokePool],
    log: true,
    deterministicDeployment: true,
  });

  const extensions = {
    eApps: eApps.address,
    eOracle: eOracle.address,
    eUpgrade: eUpgrade.address,
    eCrosschain: eCrosschain.address
  }

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
    wrappedNative: config.weth,
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

  const poolImplementation = await deploy("SmartPool", {
    from: deployer,
    args: [authority.address, extensionsMapAddress, config.tokenJar],
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

  await deploy("AUniswap", {
    from: deployer,
    args: [config.weth],
    log: true,
    deterministicDeployment: true,
  });

  await deploy("AUniswapRouter", {
    from: deployer,
    args: [config.universalRouter, config.univ4Posm, config.weth],
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
