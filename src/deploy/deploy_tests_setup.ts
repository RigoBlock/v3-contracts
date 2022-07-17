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

  const authorityExtensions = await deploy("AuthorityExtensions", {
    from: deployer,
    args: [deployer], // address _owner
    log: true,
    deterministicDeployment: true
  });

  const authorityExtensionsInstance = await hre.ethers.getContractAt(
    "AuthorityExtensions",
    authorityExtensions.address
  );

  // TODO: file renaming for hardhat issue creates confusion with method names
  await authorityInstance.setExtensionsAuthority(authorityExtensions.address);
  await authorityExtensionsInstance.setWhitelister(deployer, true);

  const registry = await deploy("PoolRegistry", {
    from: deployer,
    args: [
      authority.address,
      deployer  // Rigoblock Dao
    ],
    log: true,
    deterministicDeployment: true,
  });

  // TODO: we should probably remove V3 tag from naming, as with future releases
  //  proxy should call to different interface, which might change address in
  //  deterministic deployment.
  const poolImplementation = await deploy("RigoblockV3Pool", {
    from: deployer,
    args: [authority.address],
    log: true,
    deterministicDeployment: true,
  });

  const proxyFactory = await deploy("RigoblockPoolProxyFactory", {
    from: deployer,
    args: [
      poolImplementation.address,
      registry.address
    ],
    log: true,
    deterministicDeployment: true,
  });

  await authorityInstance.whitelistFactory(proxyFactory.address, true)

  const rigoToken = await deploy("RigoToken", {
    from: deployer,
    args: [
      deployer, // address _setMinter
      deployer  // address _setRigoblock
    ],
    log: true,
    deterministicDeployment: true,
  });

  const rigoTokenInstance = await hre.ethers.getContractAt(
    "RigoToken",
    rigoToken.address
  );

  const navVerifier = await deploy("NavVerifier", {
    from: deployer,
    args: [],
    log: true,
    deterministicDeployment: true,
  });

  await authorityInstance.setNavVerifier(navVerifier.address)

  // TODO: deploy Tokentransferproxy

  await deploy("GrgVault", {
    from: deployer,
    args: [
      deployer, // mock grg transfer proxy address
      rigoToken.address
    ],
    log: true,
    deterministicDeployment: true,
  });

  const staking = await deploy("Staking", {
    from: deployer,
    args: [],
    log: true,
    deterministicDeployment: true,
  });

  const stakingProxy = await deploy("StakingProxy", {
    from: deployer,
    args: [staking.address],
    log: true,
    deterministicDeployment: true,
  });

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
  await rigoTokenInstance.changeRigoblockAddress(AddressZero)

  await deploy("ProofOfPerformance", {
    from: deployer,
    args: [stakingProxy.address],
    log: true,
    deterministicDeployment: true,
  });
};

deploy.tags = ['tests-setup', 'l2-suite', 'main-suite']
export default deploy;
