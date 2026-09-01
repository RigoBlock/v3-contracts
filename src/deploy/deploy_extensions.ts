import "hardhat-deploy";
import "@nomiclabs/hardhat-ethers";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import {
  chainConfig,
  extensionsMapSalt,
  zeroExAllowanceHolder,
  zeroExDeployer,
} from "../utils/constants";
import { enableManagedNonce } from "../utils/nonce";
import { enableHyperEVMBigBlocks } from "../utils/hyperliquid";

const deploy: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deployer } = await getNamedAccounts();
  await enableManagedNonce(hre, deployer);
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

  // HyperEVM deployers must direct their transactions to big blocks, otherwise
  // large protocol contracts exceed the small-block gas limit. We attempt to set
  // the address-level usingBigBlocks flag automatically via the Hyperliquid API.
  // This requires the deployer to be an existing HyperCore user (e.g. to have
  // received USDC on HyperCore); if it is not, the API call fails and the user
  // must fund the Core account first.
  if (chainId === 999) {
    const signer = await hre.ethers.getSigner(deployer);
    console.log("Enabling HyperEVM big blocks for the deployer...");
    await enableHyperEVMBigBlocks(signer, false);
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
      deployer, // Rigoblock Dao
    ],
    log: true,
    deterministicDeployment: true,
  });

  const originalImplementationAddress =
    "0xeb0c08Ad44af89BcBB5Ed6dD28caD452311B8516";
  const proxyFactory = await deploy("RigoblockPoolProxyFactory", {
    from: deployer,
    args: [originalImplementationAddress, registry.address],
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
  });

  const eApps = await deploy("EApps", {
    from: deployer,
    args: [[config.stakingProxy, config.univ4Posm]],
    log: true,
    deterministicDeployment: true,
  });

  const navViewParams = {
    grgStakingProxy: config.stakingProxy,
    univ4Posm: config.univ4Posm,
  };

  const eNavView = await deploy("ENavView", {
    from: deployer,
    args: [navViewParams],
    log: true,
    deterministicDeployment: true,
  });

  const eCrosschain = await deploy("ECrosschain", {
    from: deployer,
    args: [],
    log: true,
    deterministicDeployment: true,
  });

  // EGmxCallback is Arbitrum-only; use address zero as a no-op placeholder elsewhere.
  const eGmxCallback =
    chainId === 42161
      ? (
          await deploy("EGmxCallback", {
            from: deployer,
            args: [],
            log: true,
            deterministicDeployment: true,
          })
        ).address
      : "0x0000000000000000000000000000000000000000";

  const extensions = {
    eApps: eApps.address,
    eOracle: eOracle.address,
    eUpgrade: eUpgrade.address,
    eCrosschain: eCrosschain.address,
    eNavView: eNavView.address,
    eGmxCallback: eGmxCallback,
  };

  const extensionsMapDeployer = await deploy("ExtensionsMapDeployer", {
    from: deployer,
    args: [],
    log: true,
    deterministicDeployment: true,
  });

  const extensionsMapDeployerInstance = await hre.ethers.getContractAt(
    "ExtensionsMapDeployer",
    extensionsMapDeployer.address,
  );

  const params = {
    extensions: extensions,
    wrappedNative: config.weth,
  };

  // Note: when upgrading extensions, must update the salt manually (will allow to deploy to the same address on all chains)
  const salt = hre.ethers.utils.formatBytes32String(extensionsMapSalt);

  // Always call deployExtensionsMap: it is a no-op if ExtensionsMap is already
  // deployed at the deterministic address. We avoid callStatic because
  // deployExtensionsMap creates a contract and may revert in static contexts.
  // Use deployments.execute so hardhat-deploy tracks the nonce consistently.
  await hre.deployments.execute(
    "ExtensionsMapDeployer",
    { from: deployer, log: true },
    "deployExtensionsMap",
    params,
    salt,
  );

  // The deployer stores the address under a hashed salt. Retrieve it so we
  // don't have to duplicate the CREATE2 computation locally.
  const hashedSalt = hre.ethers.utils.keccak256(
    hre.ethers.utils.defaultAbiCoder.encode(
      ["address", "bytes32"],
      [deployer, salt],
    ),
  );
  const extensionsMapAddress = await extensionsMapDeployerInstance.deployedMaps(
    deployer,
    hashedSalt,
  );

  if (extensionsMapAddress === hre.ethers.constants.AddressZero) {
    throw new Error("ExtensionsMap deployment did not record an address");
  }

  // Register ExtensionsMap with hardhat-deploy so it is included in
  // verification workflows.
  const extensionsMapArtifact =
    await hre.deployments.getExtendedArtifact("ExtensionsMap");
  await hre.deployments.save("ExtensionsMap", {
    address: extensionsMapAddress,
    ...extensionsMapArtifact,
  });

  const poolImplementation = await deploy("SmartPool", {
    from: deployer,
    args: [authority.address, extensionsMapAddress, config.tokenJar],
    log: true,
    deterministicDeployment: true,
  });

  /*const proxyFactoryInstance = await hre.ethers.getContractAt(
    "RigoblockPoolProxyFactory",
    proxyFactory.address,
  );
  const currentImplementation = await proxyFactoryInstance.implementation();
  if (currentImplementation !== poolImplementation.address) {
    await proxyFactoryInstance.setImplementation(poolImplementation.address);
  }*/

  // AMulticall is used by the pool itself and by Across destination instructions.
  await deploy("AMulticall", {
    from: deployer,
    args: [],
    log: true,
    deterministicDeployment: true,
  });

  // Across is supported wherever a SpokePool is configured.
  if (config.acrossSpokePool !== hre.ethers.constants.AddressZero) {
    await deploy("AIntents", {
      from: deployer,
      args: [config.acrossSpokePool],
      log: true,
      deterministicDeployment: true,
    });
  }

  // HyperEVM has no Uniswap V4 / 0x deployments; only Hyperliquid + Across apply.
  if (chainId !== 999) {
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

    await deploy("A0xRouter", {
      from: deployer,
      args: [zeroExAllowanceHolder, zeroExDeployer],
      log: true,
      deterministicDeployment: true,
    });
  }

  // AHyperliquid is HyperEVM-only.
  if (chainId === 999) {
    await deploy("AHyperliquid", {
      from: deployer,
      args: [],
      log: true,
      deterministicDeployment: true,
    });
  }

  // AGmxV2 is Arbitrum-only; skip silently on all other networks.
  if (chainId === 42161) {
    await deploy("AGmxV2", {
      from: deployer,
      args: [],
      log: true,
      deterministicDeployment: true,
    });
  }
};

deploy.tags = [
  "extensions",
  "implementation",
  "adapters",
  "l2-suite",
  "main-suite",
];
export default deploy;
