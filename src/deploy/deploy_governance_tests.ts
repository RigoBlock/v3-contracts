import {readArtifact} from "../../rocketh/artifacts.js";
import { deployScript } from "../../rocketh/deploy.js";
import { isLocalEnvironment, type Environment } from "../../rocketh/config.js";

export default deployScript(
  async (env: Environment) => {
    if (!isLocalEnvironment(env)) {
      console.log(`Skipping governance tests setup on ${env.name}`);
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

    await env.deploy(
      "PoolRegistry",
      {
        account: deployer,
        artifact: await readArtifact("PoolRegistry"),
        args: [env.get("Authority").address, deployer], // Rigoblock Dao
      },
      { deterministic: true },
    );

    // same on altchains but different from one deployed on Ethereum
    await env.deploy(
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
        args: [
          grgTransferProxy.address,
          env.get("RigoToken").address,
          deployer,
        ], // Authorizable(_owner)
      },
      { deterministic: true },
    );

    // the vault must be able to move GRG via the transfer proxy; the check makes
    // the script idempotent when another tag set (tests-setup) already authorized it
    const erc20ProxyAuthorized = (await env.readByName("ERC20Proxy", {
      functionName: "getAuthorizedAddresses",
      args: [],
    })) as string[];
    if (!erc20ProxyAuthorized.includes(grgVault.address)) {
      await env.executeByName("ERC20Proxy", {
        account: deployer,
        functionName: "addAuthorizedAddress",
        args: [grgVault.address],
      });
    }

    // same on altchains but different from one deployed on Ethereum
    const staking = await env.deploy(
      "Staking",
      {
        account: deployer,
        artifact: await readArtifact("Staking"),
        args: [
          grgVault.address,
          env.get("PoolRegistry").address,
          env.get("RigoToken").address,
        ],
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

    // staking proxy must be authorized on the vault, otherwise stake() reverts
    const currentStakingProxy = (await env.readByName("GrgVault", {
      functionName: "stakingProxy",
      args: [],
    })) as string;
    if (currentStakingProxy !== stakingProxy.address) {
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
    }

    // staking's endEpoch calls mintInflation() on the GRG minter; it must be a contract
    const inflation = await env.deploy(
      "Inflation",
      {
        account: deployer,
        artifact: await readArtifact("Inflation"),
        args: [env.get("RigoToken").address, stakingProxy.address],
      },
      { deterministic: true },
    );

    const currentMinter = (await env.readByName("RigoToken", {
      functionName: "minter",
      args: [],
    })) as string;
    if (currentMinter !== inflation.address) {
      await env.executeByName("RigoToken", {
        account: deployer,
        functionName: "changeMintingAddress",
        args: [inflation.address],
      });
    }

    await env.deploy(
      "RigoblockGovernanceFactory",
      {
        account: deployer,
        artifact: await readArtifact(
          "RigoblockGovernanceFactory",
        ),
        args: [],
      },
      { deterministic: true },
    );

    await env.deploy(
      "RigoblockGovernance",
      {
        account: deployer,
        artifact: await readArtifact("RigoblockGovernance"),
        args: [],
      },
      { deterministic: true },
    );

    await env.deploy(
      "RigoblockGovernanceStrategy",
      {
        account: deployer,
        artifact: await readArtifact(
          "RigoblockGovernanceStrategy",
        ),
        args: [stakingProxy.address],
      },
      { deterministic: true },
    );
  },
  { tags: ["governance-tests", "l2-suite", "main-suite"] },
);
