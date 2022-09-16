import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { AddressZero } from "@ethersproject/constants"

const deploy: DeployFunction = async function (
  hre: HardhatRuntimeEnvironment,
) {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();
  const { deploy } = deployments;

  const authority = await deploy("AuthorityCore", {
    from: deployer,
    args: [deployer], // owner
    log: true,
    deterministicDeployment: true,
  });

  const authorityInstance = await hre.ethers.getContractAt(
    "AuthorityCore",
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

  // as long as authority address is same on all chains, pool implementation will have same address
  const poolImplementation = await deploy("RigoblockV3Pool", {
    from: deployer,
    args: [authority.address],
    log: true,
    deterministicDeployment: true,
  });

  // same as above
  const proxyFactory = await deploy("RigoblockPoolProxyFactory", {
    from: deployer,
    args: [
      poolImplementation.address,
      registry.address
    ],
    log: true,
    deterministicDeployment: true,
  });

  await authorityInstance.setFactory(proxyFactory.address, true)

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
        deployer,  // Authorizable(_owner)
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

  // same on altchains but different from one deployed on Ethereum
  await deploy("ProofOfPerformance", {
    from: deployer,
    args: [stakingProxy.address],
    log: true,
    deterministicDeployment: true,
  });

  // TODO: check if we can move adapters deploy inside the tests
  await deploy("ASelfCustody", {
    from: deployer,
    args: [
        grgVault.address,
        stakingProxy.address
    ],
    log: true,
    deterministicDeployment: true,
  })

  const mockUniswapRouter = await deploy("MockUniswapRouter", {
    from: deployer,
    args: [],
    log: true,
    deterministicDeployment: true,
  })

  await deploy("AUniswap", {
    from: deployer,
    args: [mockUniswapRouter.address],
    log: true,
    deterministicDeployment: true,
  })

  await deploy("AMulticall", {
    from: deployer,
    args: [],
    log: true,
    deterministicDeployment: true,
  })
};

deploy.tags = ['tests-setup', 'l2-suite', 'main-suite']
export default deploy;
