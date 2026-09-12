import { ethers } from "ethers";
import { readArtifact } from "../../rocketh/artifacts.js";
import { deployScript } from "../../rocketh/deploy.js";
import { isLocalEnvironment, type Environment } from "../../rocketh/config.js";
import { extensionsMapSalt } from "../utils/constants";

export default deployScript(
  async (env: Environment) => {
    if (!isLocalEnvironment(env)) {
      console.log(`Skipping tests setup on ${env.name}`);
      return;
    }

    const deployer = env.namedAccounts.deployer;

    await env.deploy(
      "Authority",
      {
        account: deployer,
        artifact: await readArtifact("Authority"),
        args: [deployer], // owner
      },
      { deterministic: true },
    );

    await env.executeByName("Authority", {
      account: deployer,
      functionName: "setWhitelister",
      args: [deployer, true],
    });

    const registry = await env.deploy(
      "PoolRegistry",
      {
        account: deployer,
        artifact: await readArtifact("PoolRegistry"),
        args: [env.get("Authority").address, deployer], // Rigoblock Dao
      },
      { deterministic: true },
    );

    const originalImplementationAddress =
      "0xeb0c08Ad44af89BcBB5Ed6dD28caD452311B8516";
    // same factory address on all chains guarantees same multichain proxy addresses
    const proxyFactory = await env.deploy(
      "RigoblockPoolProxyFactory",
      {
        account: deployer,
        artifact: await readArtifact("RigoblockPoolProxyFactory"),
        args: [originalImplementationAddress, registry.address],
      },
      { deterministic: true },
    );

    // same on altchains but different from one deployed on Ethereum
    const rigoToken = await env.deploy(
      "RigoToken",
      {
        account: deployer,
        artifact: await readArtifact("RigoToken"),
        args: [
          deployer, // address _setMinter
          deployer, // address _setRigoblock
          deployer, // address _grgHolder
        ],
      },
      { deterministic: true },
    );

    const grgTransferProxy = await env.deploy(
      "ERC20Proxy",
      {
        account: deployer,
        artifact: await readArtifact("ERC20Proxy"),
        args: [deployer], // Authorizable(_owner)
      },
      { deterministic: true },
    );

    // same on altchains but different from one deployed on Ethereum
    const grgVault = await env.deploy(
      "GrgVault",
      {
        account: deployer,
        artifact: await readArtifact("GrgVault"),
        args: [grgTransferProxy.address, rigoToken.address, deployer], // Authorizable(_owner)
      },
      { deterministic: true },
    );

    // TODO: test if following condition necessary
    await env.executeByName("ERC20Proxy", {
      account: deployer,
      functionName: "addAuthorizedAddress",
      args: [grgVault.address],
    });

    // same on altchains but different from one deployed on Ethereum
    const staking = await env.deploy(
      "Staking",
      {
        account: deployer,
        artifact: await readArtifact("Staking"),
        args: [grgVault.address, registry.address, rigoToken.address],
      },
      { deterministic: true },
    );

    // same on altchains but different from one deployed on Ethereum
    const stakingProxy = await env.deploy(
      "StakingProxy",
      {
        account: deployer,
        artifact: await readArtifact("StakingProxy"),
        args: [staking.address, deployer], // Authorizable(_owner)
      },
      { deterministic: true },
    );

    const eUpgrade = await env.deploy(
      "EUpgrade",
      {
        account: deployer,
        artifact: await readArtifact("EUpgrade"),
        args: [proxyFactory.address],
      },
      { deterministic: true },
    );

    const oracle = await env.deploy(
      "MockOracle",
      {
        account: deployer,
        artifact: await readArtifact("MockOracle"),
        args: [],
      },
      { deterministic: true },
    );

    const weth = await env.deploy(
      "WETH9",
      {
        account: deployer,
        artifact: await readArtifact("WETH9"),
        args: [],
      },
      { deterministic: true },
    );

    await env.deploy(
      "MockUniswapNpm",
      {
        account: deployer,
        artifact: await readArtifact("MockUniswapNpm"),
        args: [weth.address],
      },
      { deterministic: true },
    );

    const eOracle = await env.deploy(
      "EOracle",
      {
        account: deployer,
        artifact: await readArtifact("EOracle"),
        args: [oracle.address, weth.address],
      },
      { deterministic: true },
    );

    const permit2 = await env.deploy(
      "MockPermit2",
      {
        account: deployer,
        artifact: await readArtifact("MockPermit2"),
        args: [],
      },
      { deterministic: true },
    );

    const univ4Posm = await env.deploy(
      "MockUniswapPosm",
      {
        account: deployer,
        artifact: await readArtifact("MockUniswapPosm"),
        args: [permit2.address],
      },
      { deterministic: true },
    );

    const eApps = await env.deploy(
      "EApps",
      {
        account: deployer,
        artifact: await readArtifact("EApps"),
        args: [[stakingProxy.address, univ4Posm.address]],
      },
      { deterministic: true },
    );

    const eNavView = await env.deploy(
      "ENavView",
      {
        account: deployer,
        artifact: await readArtifact("ENavView"),
        args: [[stakingProxy.address, univ4Posm.address]],
      },
      { deterministic: true },
    );

    const acrossSpokePool = await env.deploy(
      "MockAcrossSpokePool",
      {
        account: deployer,
        artifact: await readArtifact("MockAcrossSpokePool"),
        args: [weth.address],
      },
      { deterministic: true },
    );

    await env.deploy(
      "MockAcrossMulticallHandler",
      {
        account: deployer,
        artifact: await readArtifact("MockAcrossMulticallHandler"),
        args: [],
      },
      { deterministic: true },
    );

    const eCrosschain = await env.deploy(
      "ECrosschain",
      {
        account: deployer,
        artifact: await readArtifact("ECrosschain"),
        args: [],
      },
      { deterministic: true },
    );

    const eErc20 = await env.deploy(
      "EERC20",
      {
        account: deployer,
        artifact: await readArtifact("EERC20"),
        args: [],
      },
      { deterministic: true },
    );

    const extensions = {
      eApps: eApps.address,
      eNavView: eNavView.address,
      eOracle: eOracle.address,
      eUpgrade: eUpgrade.address,
      eCrosschain: eCrosschain.address,
      eGmxCallback: ethers.ZeroAddress,
      eErc20: eErc20.address,
    };

    await env.deploy(
      "ExtensionsMapDeployer",
      {
        account: deployer,
        artifact: await readArtifact("ExtensionsMapDeployer"),
        args: [],
      },
      { deterministic: true },
    );

    const params = {
      extensions: extensions,
      wrappedNative: weth.address,
    };

    // Note: when upgrading extensions, must update the salt manually (will allow to deploy to the same address on all chains)
    const salt = ethers.encodeBytes32String(extensionsMapSalt);
    await env.readByName("ExtensionsMapDeployer", {
      functionName: "deployExtensionsMap",
      args: [params, salt],
    });
    await env.executeByName("ExtensionsMapDeployer", {
      account: deployer,
      functionName: "deployExtensionsMap",
      args: [params, salt],
    });
    const extensionsMapAddress = (await env.readByName(
      "ExtensionsMapDeployer",
      {
        functionName: "deployExtensionsMap",
        args: [params, salt],
      },
    )) as string;

    const mockTokenJar = await env.deploy(
      "MockTokenJar",
      {
        account: deployer,
        artifact: await readArtifact("MockTokenJar"),
        args: [],
      },
      { deterministic: true },
    );

    // TODO: make sure the token jar is deployed at same address across all chains. Otherwise, we must store its address
    // Notice: when updating extensions, make sure the ExtensionsMap setup is correct, when updating storage slot definitions, make sure they are correct.
    // implementation will have same address on all chains as long as args are the same
    const poolImplementation = await env.deploy(
      "SmartPool",
      {
        account: deployer,
        artifact: await readArtifact("SmartPool"),
        args: [
          env.get("Authority").address,
          extensionsMapAddress,
          mockTokenJar.address,
        ],
      },
      { deterministic: true },
    );

    const currentImplementation = (await env.readByName(
      "RigoblockPoolProxyFactory",
      { functionName: "implementation" },
    )) as string;
    if (currentImplementation !== poolImplementation.address) {
      await env.executeByName("RigoblockPoolProxyFactory", {
        account: deployer,
        functionName: "setImplementation",
        args: [poolImplementation.address],
      });
    }

    await env.executeByName("Authority", {
      account: deployer,
      functionName: "setFactory",
      args: [proxyFactory.address, true],
    });

    const aStaking = await env.deploy(
      "AStaking",
      {
        account: deployer,
        artifact: await readArtifact("AStaking"),
        args: [
          stakingProxy.address,
          rigoToken.address,
          grgTransferProxy.address,
        ],
      },
      { deterministic: true },
    );

    await env.executeByName("Authority", {
      account: deployer,
      functionName: "setAdapter",
      args: [aStaking.address, true],
    });

    await env.executeByName("GrgVault", {
      account: deployer,
      functionName: "addAuthorizedAddress",
      args: [deployer],
    });
    await env.executeByName("GrgVault", {
      account: deployer,
      functionName: "setStakingProxy",
      args: [stakingProxy.address],
    });
    await env.executeByName("GrgVault", {
      account: deployer,
      functionName: "removeAuthorizedAddress",
      args: [deployer],
    });

    // same on altchains but different from one deployed on Ethereum
    const inflation = await env.deploy(
      "Inflation",
      {
        account: deployer,
        artifact: await readArtifact("Inflation"),
        args: [rigoToken.address, stakingProxy.address],
      },
      { deterministic: true },
    );

    await env.executeByName("RigoToken", {
      account: deployer,
      functionName: "changeMintingAddress",
      args: [inflation.address],
    });

    await env.deploy(
      "InflationL2",
      {
        account: deployer,
        artifact: await readArtifact("InflationL2"),
        args: [deployer],
      },
      { deterministic: true },
    );

    // same on altchains but different from one deployed on Ethereum
    await env.deploy(
      "ProofOfPerformance",
      {
        account: deployer,
        artifact: await readArtifact("ProofOfPerformance"),
        args: [stakingProxy.address],
      },
      { deterministic: true },
    );

    await env.deploy(
      "AUniswap",
      {
        account: deployer,
        artifact: await readArtifact("AUniswap"),
        args: [weth.address],
      },
      { deterministic: true },
    );

    await env.deploy(
      "AMulticall",
      {
        account: deployer,
        artifact: await readArtifact("AMulticall"),
        args: [],
      },
      { deterministic: true },
    );

    const aIntents = await env.deploy(
      "AIntents",
      {
        account: deployer,
        artifact: await readArtifact("AIntents"),
        args: [acrossSpokePool.address],
      },
      { deterministic: true },
    );

    await env.executeByName("Authority", {
      account: deployer,
      functionName: "setAdapter",
      args: [aIntents.address, true],
    });
  },
  { tags: ["tests-setup", "l2-suite", "main-suite"] },
);
