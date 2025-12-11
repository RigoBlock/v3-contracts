import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import "hardhat-deploy/dist/src/type-extensions";
import { extensionsMapSalt } from "../utils/constants";

const deploy: DeployFunction = async function (
  hre: HardhatRuntimeEnvironment,
) {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();
  const { deploy } = deployments;

  const authority = await deploy("Authority", {
    from: deployer,
    args: [deployer], // owner
    log: true,
    deterministicDeployment: true,
  });

  const authorityInstance = await hre.ethers.getContractAt(
    "Authority",
    authority.address
  );

  await authorityInstance.setWhitelister(deployer, true);

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
  // same factory address on all chains guarantees same multichain proxy addresses
  const proxyFactory = await deploy("RigoblockPoolProxyFactory", {
    from: deployer,
    args: [
      originalImplementationAddress,
      registry.address
    ],
    log: true,
    deterministicDeployment: true,
  });

  // same on altchains but different from one deployed on Ethereum
  const rigoToken = await deploy("RigoToken", {
    from: deployer,
    args: [
      deployer, // address _setMinter
      deployer, // address _setRigoblock
      deployer // address _grgHolder
    ],
    log: true,
    deterministicDeployment: true,
  });

  const rigoTokenInstance = await hre.ethers.getContractAt(
    "RigoToken",
    rigoToken.address
  );

  const grgTransferProxy = await deploy("ERC20Proxy", {
    from: deployer,
    args: [deployer],  // Authorizable(_owner)
    log: true,
    deterministicDeployment: true,
  });

  const grgTransferProxyInstance = await hre.ethers.getContractAt(
    "ERC20Proxy",
    grgTransferProxy.address
  );

  // same on altchains but different from one deployed on Ethereum
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

  // TODO: test if following condition necessary
  await grgTransferProxyInstance.addAuthorizedAddress(grgVault.address)

  const grgVaultInstance = await hre.ethers.getContractAt(
    "GrgVault",
    grgVault.address
  );

  // same on altchains but different from one deployed on Ethereum
  const staking = await deploy("Staking", {
    from: deployer,
    args: [
        grgVault.address,
        registry.address,
        rigoToken.address
    ],
    log: true,
    deterministicDeployment: true,
  });

  // same on altchains but different from one deployed on Ethereum
  const stakingProxy = await deploy("StakingProxy", {
    from: deployer,
    args: [
        staking.address,
        deployer  // Authorizable(_owner)
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

  const oracle = await deploy("MockOracle", {
    from: deployer,
    args: [],
    log: true,
    deterministicDeployment: true,
  })

  const weth = await deploy("WETH9", {
    from: deployer,
    args: [],
    log: true,
    deterministicDeployment: true,
  })

  await deploy("MockUniswapNpm", {
    from: deployer,
    args: [weth.address],
    log: true,
    deterministicDeployment: true,
  })

  const eOracle = await deploy("EOracle", {
    from: deployer,
    args: [oracle.address, weth.address],
    log: true,
    deterministicDeployment: true,
  })

  const permit2 = await deploy("MockPermit2", {
    from: deployer,
    args: [],
    log: true,
    deterministicDeployment: true,
  })

  const univ4Posm = await deploy("MockUniswapPosm", {
    from: deployer,
    args: [permit2.address],
    log: true,
    deterministicDeployment: true,
  })

  const eApps = await deploy("EApps", {
    from: deployer,
    args: [stakingProxy.address, univ4Posm.address],
    log: true,
    deterministicDeployment: true,
  });

  // Deploy MockSpokePool for testing
  const mockSpokePool = await deploy("MockSpokePool", {
    from: deployer,
    args: [weth.address],
    log: true,
    deterministicDeployment: true,
  });

  const eAcrossHandler = await deploy("EAcrossHandler", {
    from: deployer,
    args: [mockSpokePool.address],
    log: true,
    deterministicDeployment: true,
  });

  const extensions = {
    eApps: eApps.address,
    eOracle: eOracle.address,
    eUpgrade: eUpgrade.address,
    eAcrossHandler: eAcrossHandler.address
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
    wrappedNative: weth.address
  }

  // Note: when upgrading extensions, must update the salt manually (will allow to deploy to the same address on all chains)
  const salt = hre.ethers.utils.formatBytes32String(extensionsMapSalt);
  const extensionsMapAddress = await extensionsMapDeployerInstance.callStatic.deployExtensionsMap(params, salt);
  const tx = await extensionsMapDeployerInstance.deployExtensionsMap(params, salt);
  await tx.wait();

  const mockTokenJar = await deploy("MockTokenJar", {
    from: deployer,
    args: [],
    log: true,
    deterministicDeployment: true,
  });

  // implementation address is different on each chain as extensionsMap is different, but proxies will have the same address
  const poolImplementation = await deploy("SmartPool", {
    from: deployer,
    args: [authority.address, extensionsMapAddress, mockTokenJar.address],
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

  await authorityInstance.setFactory(proxyFactory.address, true)

  const aStaking = await deploy("AStaking", {
    from: deployer,
    args: [
        stakingProxy.address,
        rigoToken.address,
        grgTransferProxy.address
    ],
    log: true,
    deterministicDeployment: true,
  });

  await authorityInstance.setAdapter(aStaking.address, true)

  await grgVaultInstance.addAuthorizedAddress(deployer)
  await grgVaultInstance.setStakingProxy(stakingProxy.address)
  await grgVaultInstance.removeAuthorizedAddress(deployer)

  // same on altchains but different from one deployed on Ethereum
  const inflation = await deploy("Inflation", {
    from: deployer,
    args: [
      rigoToken.address,
      stakingProxy.address
    ],
    log: true,
    deterministicDeployment: true,
  });

  await rigoTokenInstance.changeMintingAddress(inflation.address)

  await deploy("InflationL2", {
    from: deployer,
    args: [deployer],
    log: true,
    deterministicDeployment: true,
  });

  // same on altchains but different from one deployed on Ethereum
  await deploy("ProofOfPerformance", {
    from: deployer,
    args: [stakingProxy.address],
    log: true,
    deterministicDeployment: true,
  });

  await deploy("AUniswap", {
    from: deployer,
    args: [weth.address],
    log: true,
    deterministicDeployment: true,
  })

  await deploy("AMulticall", {
    from: deployer,
    args: [],
    log: true,
    deterministicDeployment: true,
  })

  const aIntents = await deploy("AIntents", {
    from: deployer,
    args: [mockSpokePool.address],
    log: true,
    deterministicDeployment: true,
  })

  await authorityInstance.setAdapter(aIntents.address, true)
};

deploy.tags = ['tests-setup', 'l2-suite', 'main-suite']
export default deploy;
