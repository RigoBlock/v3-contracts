import {ethers} from "ethers";
import {readArtifact} from "../../rocketh/artifacts.js";
import {deployScript} from "../../rocketh/deploy.js";
import {isLocalEnvironment, type Environment} from "../../rocketh/config.js";
import {chainConfig, extensionsMapSalt} from "../utils/constants";

export default deployScript(
  async (env: Environment) => {
    if (!isLocalEnvironment(env)) {
      console.log(`Skipping pool deployment on ${env.name}`);
      return;
    }

    const deployer = env.namedAccounts.deployer;

    const chainId = env.network.chain.id;
    if (!chainConfig[chainId]) {
      if (chainId === 31337) {
        console.log("Skipping for Hardhat Network");
        return;
      } else {
        throw new Error(`Unsupported network: Chain ID ${chainId}`);
      }
    }

    const config = chainConfig[chainId];

    const authority = await env.deploy("Authority", {
      account: deployer,
      artifact: await readArtifact("Authority"),
      args: [deployer]
      }, {deterministic: true});

    const registry = await env.deploy("PoolRegistry", {
      account: deployer,
      artifact: await readArtifact("PoolRegistry"),
      args: [authority.address, deployer], // Rigoblock Dao
      }, {deterministic: true});

    const originalImplementationAddress =
      "0xeb0c08Ad44af89BcBB5Ed6dD28caD452311B8516";
    const proxyFactory = await env.deploy("RigoblockPoolProxyFactory", {
      account: deployer,
      artifact: await readArtifact("RigoblockPoolProxyFactory"),
      args: [originalImplementationAddress, registry.address]
      }, {deterministic: true});

    const eUpgrade = await env.deploy("EUpgrade", {
      account: deployer,
      artifact: await readArtifact("EUpgrade"),
      args: [proxyFactory.address]
      }, {deterministic: true});

    // Notice: make sure the constants.ts file is updated with the correct address.
    const wethAddress = "0xeb0c08Ad44af89BcBB5Ed6dD28caD452311B8516";
    const eOracle = await env.deploy("EOracle", {
      account: deployer,
      artifact: await readArtifact("EOracle"),
      args: [config.oracle, wethAddress]
      }, {deterministic: true});

    const grgStakingProxy = "0xeb0c08Ad44af89BcBB5Ed6dD28caD452311B8516";
    const univ4Posm = "0xeb0c08Ad44af89BcBB5Ed6dD28caD452311B8516";
    const eApps = await env.deploy("EApps", {
      account: deployer,
      artifact: await readArtifact("EApps"),
      args: [[grgStakingProxy, univ4Posm]]
      }, {deterministic: true});

    const eCrosschain = await env.deploy("ECrosschain", {
      account: deployer,
      artifact: await readArtifact("ECrosschain"),
      args: []
      }, {deterministic: true});

    const extensions = {
      eApps: eApps.address,
      eOracle: eOracle.address,
      eUpgrade: eUpgrade.address,
      eCrosschain: eCrosschain.address,
    };

    await env.deploy("ExtensionsMapDeployer", {
      account: deployer,
      artifact: await readArtifact("ExtensionsMapDeployer"),
      args: []
      }, {deterministic: true});

    const params = {
      extensions: extensions,
      wrappedNative: wethAddress,
    };

    // Note: when upgrading extensions, must update the salt manually (will allow to deploy to the same address on all chains)
    const salt = ethers.encodeBytes32String(extensionsMapSalt);
    const extensionsMapAddress = (await env.readByName(
      "ExtensionsMapDeployer",
      {
        functionName: "deployExtensionsMap",
        args: [params, salt],
      },
    )) as unknown as string;

    // Check if extensionsMapAddress has code (is a deployed contract)
    const code = (await env.network.provider.request({
      method: "eth_getCode",
      params: [extensionsMapAddress as `0x${string}`, "latest"],
    })) as string;

    if (code === "0x") {
      // No code at address, proceed with deployment
      await env.executeByName("ExtensionsMapDeployer", {
        account: deployer,
        functionName: "deployExtensionsMap",
        args: [params, salt],
      });
    } else {
      // skip onchain call if the contract is already deployed (would just return the address, so we can skip it)
      console.log(`Contract already deployed at ${extensionsMapAddress}`);
    }

    await env.deploy("SmartPool", {
      account: deployer,
      artifact: await readArtifact("SmartPool"),
      args: [authority.address, extensionsMapAddress, config.tokenJar]
      }, {deterministic: true});
  },
  {tags: ["pool", "main-suite"]},
);
