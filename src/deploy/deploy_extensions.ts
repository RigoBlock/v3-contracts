import { ethers } from "ethers";
import { readArtifact } from "../../rocketh/artifacts.js";
import { deployScript } from "../../rocketh/deploy.js";
import type { Environment } from "../../rocketh/config.js";
import {
  chainConfig,
  extensionsMapSalt,
  zeroExAllowanceHolder,
  zeroExDeployer,
} from "../utils/constants";
import { enableManagedNonce } from "../utils/nonce";
import { enableHyperEVMBigBlocks } from "../utils/hyperliquid";

export default deployScript(
  async (env: Environment) => {
    const deployer = env.namedAccounts.deployer;
    await enableManagedNonce(env, deployer);

    const chainId = env.network.chain.id;
    if (!chainConfig[chainId]) {
      if (chainId === 31337) {
        console.log("Skipping for Hardhat Network");
        return;
      } else {
        throw new Error(`Unsupported network: Chain ID ${chainId}`);
      }
    }

    // HyperEVM deployers must direct their transactions to big blocks, otherwise
    // large protocol contracts exceed the small-block gas limit. We attempt to set
    // the address-level usingBigBlocks flag automatically via the Hyperliquid API.
    // This requires the deployer to be an existing HyperCore user (e.g. to have
    // received USDC on HyperCore); if it is not, the API call fails and the user
    // must fund the Core account first.
    if (chainId === 999) {
      const signerProvider =
        env.addressSigners[deployer.toLowerCase() as `0x${string}`].signer;
      const signer = {
        getAddress: async () => deployer,
        signTypedData: async (
          domain: unknown,
          types: unknown,
          message: unknown,
        ) => {
          // Hardhat signs eth_signTypedData_v4 locally via micro-eth-signer,
          // which requires an explicit primaryType field.
          const primaryType = Object.keys(
            types as Record<string, unknown>,
          ).find((key) => key !== "EIP712Domain");
          return signerProvider.request({
            method: "eth_signTypedData_v4",
            params: [
              deployer as `0x${string}`,
              { domain, types, message, primaryType },
            ],
          }) as unknown as Promise<string>;
        },
      } as unknown as ethers.Signer;
      console.log("Enabling HyperEVM big blocks for the deployer...");
      await enableHyperEVMBigBlocks(signer, false);
    }

    const config = chainConfig[chainId];

    const authority = await env.deploy(
      "Authority",
      {
        account: deployer,
        artifact: await readArtifact("Authority"),
        args: [deployer],
      },
      { deterministic: true },
    );

    const registry = await env.deploy(
      "PoolRegistry",
      {
        account: deployer,
        artifact: await readArtifact("PoolRegistry"),
        args: [authority.address, deployer], // Rigoblock Dao
      },
      { deterministic: true },
    );

    const originalImplementationAddress =
      "0xeb0c08Ad44af89BcBB5Ed6dD28caD452311B8516";
    const proxyFactory = await env.deploy(
      "RigoblockPoolProxyFactory",
      {
        account: deployer,
        artifact: await readArtifact("RigoblockPoolProxyFactory"),
        args: [originalImplementationAddress, registry.address],
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

    // Notice: make sure the constants.ts file is updated with the correct address.
    const eOracle = await env.deploy(
      "EOracle",
      {
        account: deployer,
        artifact: await readArtifact("EOracle"),
        args: [config.oracle, config.weth],
      },
      { deterministic: true },
    );

    const eApps = await env.deploy(
      "EApps",
      {
        account: deployer,
        artifact: await readArtifact("EApps"),
        args: [[config.stakingProxy, config.univ4Posm]],
      },
      { deterministic: true },
    );

    const navViewParams = {
      grgStakingProxy: config.stakingProxy,
      univ4Posm: config.univ4Posm,
    };

    const eNavView = await env.deploy(
      "ENavView",
      {
        account: deployer,
        artifact: await readArtifact("ENavView"),
        args: [navViewParams],
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

    // EGmxCallback is Arbitrum-only; use address zero as a no-op placeholder elsewhere.
    const eGmxCallback =
      chainId === 42161
        ? (
            await env.deploy(
              "EGmxCallback",
              {
                account: deployer,
                artifact: await readArtifact("EGmxCallback"),
                args: [],
              },
              { deterministic: true },
            )
          ).address
        : ethers.ZeroAddress;

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
      eOracle: eOracle.address,
      eUpgrade: eUpgrade.address,
      eCrosschain: eCrosschain.address,
      eNavView: eNavView.address,
      eGmxCallback: eGmxCallback,
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
      wrappedNative: config.weth,
    };

    // Note: when upgrading extensions, must update the salt manually (will allow to deploy to the same address on all chains)
    const salt = ethers.encodeBytes32String(extensionsMapSalt);

    // Always call deployExtensionsMap: it is a no-op if ExtensionsMap is already
    // deployed at the deterministic address. The gas limit is fixed instead of
    // estimated: load-balanced RPCs (Base in particular) have returned estimates
    // for the cheap no-op path while execution needed the CREATE2 deployment
    // (~390k gas), and the unused portion is refunded anyway.
    await env.executeByName("ExtensionsMapDeployer", {
      account: deployer,
      functionName: "deployExtensionsMap",
      args: [params, salt],
      gas: 1_500_000n,
    });

    // The deployer stores the address under a hashed salt. Retrieve it so we
    // don't have to duplicate the CREATE2 computation locally.
    const hashedSalt = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "bytes32"],
        [deployer, salt],
      ),
    );
    const readMapAddress = () =>
      env.readByName("ExtensionsMapDeployer", {
        functionName: "deployedMaps",
        args: [deployer, hashedSalt],
      }) as Promise<string>;
    let extensionsMapAddress = await readMapAddress();

    // On slow-confirmation chains the receipt can be visible on one RPC node
    // while eth_call on another still lags behind; poll before giving up.
    for (
      let attempt = 0;
      extensionsMapAddress === ethers.ZeroAddress && attempt < 12;
      attempt++
    ) {
      await new Promise((resolve) => setTimeout(resolve, 5000));
      extensionsMapAddress = await readMapAddress();
    }

    if (extensionsMapAddress === ethers.ZeroAddress) {
      throw new Error(
        "ExtensionsMap deployment did not record an address; the transaction may have landed after the retries elapsed — re-run the script",
      );
    }

    // Register ExtensionsMap so it is included in verification workflows.
    const extensionsMapArtifact = await readArtifact("ExtensionsMap");
    await env.save(
      "ExtensionsMap",
      {
        address: extensionsMapAddress,
        ...extensionsMapArtifact,
        argsData: "0x",
      } as any,
      { considerItAsFreshDeployment: true },
    );

    const poolImplementation = await env.deploy(
      "SmartPool",
      {
        account: deployer,
        artifact: await readArtifact("SmartPool"),
        args: [authority.address, extensionsMapAddress, config.tokenJar],
      },
      { deterministic: true },
    );

    // On chains where the factory is still owned by the deployer (sepolia,
    // hyperliquid, fresh chains), uncomment to point the factory at the newly
    // deployed implementation. Reverts once governance owns the factory —
    // hence commented by default.
    /*const currentImplementation = (await env.readByName(
      "RigoblockPoolProxyFactory",
      {
        functionName: "implementation",
      },
    )) as string;
    if (
      currentImplementation.toLowerCase() !==
      poolImplementation.address.toLowerCase()
    ) {
      await env.executeByName("RigoblockPoolProxyFactory", {
        account: deployer,
        functionName: "setImplementation",
        args: [poolImplementation.address],
      });
    }*/

    // AMulticall is used by the pool itself and by Across destination instructions.
    await env.deploy(
      "AMulticall",
      {
        account: deployer,
        artifact: await readArtifact("AMulticall"),
        args: [],
      },
      { deterministic: true },
    );

    // Across is supported wherever a SpokePool is configured.
    if (config.acrossSpokePool !== ethers.ZeroAddress) {
      await env.deploy(
        "AIntents",
        {
          account: deployer,
          artifact: await readArtifact("AIntents"),
          args: [config.acrossSpokePool],
        },
        { deterministic: true },
      );
    }

    // HyperEVM has no Uniswap V4 / 0x deployments; only Hyperliquid + Across apply.
    if (chainId !== 999) {
      await env.deploy(
        "AUniswap",
        {
          account: deployer,
          artifact: await readArtifact("AUniswap"),
          args: [config.weth],
        },
        { deterministic: true },
      );

      await env.deploy(
        "AUniswapRouter",
        {
          account: deployer,
          artifact: await readArtifact("AUniswapRouter"),
          args: [config.universalRouter, config.univ4Posm, config.weth],
        },
        { deterministic: true },
      );

      await env.deploy(
        "A0xRouter",
        {
          account: deployer,
          artifact: await readArtifact("A0xRouter"),
          args: [zeroExAllowanceHolder, zeroExDeployer],
        },
        { deterministic: true },
      );
    }

    // AHyperliquid is HyperEVM-only.
    if (chainId === 999) {
      await env.deploy(
        "AHyperliquid",
        {
          account: deployer,
          artifact: await readArtifact("AHyperliquid"),
          args: [],
        },
        { deterministic: true },
      );
    }

    // AGmxV2 is Arbitrum-only; skip silently on all other networks.
    if (chainId === 42161) {
      await env.deploy(
        "AGmxV2",
        {
          account: deployer,
          artifact: await readArtifact("AGmxV2"),
          args: [],
        },
        { deterministic: true },
      );
    }
  },
  {
    tags: [
      "extensions",
      "implementation",
      "adapters",
      "l2-suite",
      "main-suite",
    ],
  },
);
